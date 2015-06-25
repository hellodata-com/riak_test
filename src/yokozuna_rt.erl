%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
-module(yokozuna_rt).

-include_lib("eunit/include/eunit.hrl").
-include("yokozuna_rt.hrl").

-export([expire_trees/1,
         rolling_upgrade/2,
         rolling_upgrade/3,
         verify_num_found_query/3,
         wait_for_aae/1,
         wait_for_index/2,
         wait_for_full_exchange_round/2,
         write_data/5]).

%% @doc Write `Keys' via the PB inteface to a `Bucket' and have them
%%      searchable in an `Index'.
-spec write_data([node()], pid(), index_name(), bucket(), [binary()]) -> ok.
write_data(Cluster, Pid, Index, Bucket, Keys) ->
    riakc_pb_socket:set_options(Pid, [queue_if_disconnected]),

    %% Create a search index and associate with a bucket
    riakc_pb_socket:create_search_index(Pid, Index),

    %% For possible legacy upgrade reasons, wrap create index in a wait
    wait_for_index(Cluster, Index),

    ok = riakc_pb_socket:set_search_index(Pid, Bucket, Index),
    timer:sleep(1000),

    %% Write keys
    lager:info("Writing ~p keys", [length(Keys)]),
    [ok = rt:pbc_write(Pid, Bucket, Key, Key, "text/plain") || Key <- Keys],
    ok.

%% @doc Peform a rolling upgrade of the `Cluster' to a different `Version' based
%%      on current | previous | legacy.
-spec rolling_upgrade([node()], current | previous | legacy) -> ok.
rolling_upgrade(Cluster, Vsn) ->
    rolling_upgrade(Cluster, Vsn, []).

-spec rolling_upgrade([node()], current | previous | legacy, proplists:proplist()) -> ok.
rolling_upgrade(Cluster, Vsn, YZCfgChanges) ->
    lager:info("Perform rolling upgrade on cluster ~p", [Cluster]),
    SolrPorts = lists:seq(11000, 11000 + length(Cluster) - 1),
    Cluster2 = lists:zip(SolrPorts, Cluster),
    [begin
         Cfg = [{riak_kv, [{anti_entropy, {on, [debug]}},
                           {anti_entropy_concurrency, 8},
                           {anti_entropy_build_limit, {100, 1000}}
                          ]},
                {yokozuna, [{anti_entropy, {on, [debug]}},
                            {anti_entropy_concurrency, 8},
                            {anti_entropy_build_limit, {100, 1000}},
                            {anti_entropy_tick, 1000},
                            {enabled, true},
                            {solr_port, SolrPort}]}],
         MergeC = config_merge(Cfg, YZCfgChanges),
         rt:upgrade(Node, Vsn, MergeC),
         rt:wait_for_service(Node, riak_kv),
         rt:wait_for_service(Node, yokozuna)
     end || {SolrPort, Node} <- Cluster2],
    ok.

-spec config_merge(proplists:proplist(), proplists:proplist()) ->
                          orddict:orddict() | proplists:proplist().
config_merge(DefaultCfg, NewCfg) when NewCfg /= [] ->
    orddict:update(yokozuna,
                   fun(V) ->
                           orddict:merge(fun(_, _X, Y) -> Y end,
                                         orddict:from_list(V),
                                         orddict:from_list(
                                           orddict:fetch(
                                             yokozuna, NewCfg)))
                   end,
                   DefaultCfg);
config_merge(DefaultCfg, _NewCfg) ->
    DefaultCfg.

%% @doc Use AAE status to verify that exchange has occurred for all
%%      partitions since the time this function was invoked.
-spec wait_for_aae([node()]) -> ok.
wait_for_aae(Cluster) ->
    lager:info("Wait for AAE to migrate/repair indexes"),
    wait_for_all_trees(Cluster),
    wait_for_full_exchange_round(Cluster, erlang:now()),
    ok.

%% @doc Wait for all AAE trees to be built.
-spec wait_for_all_trees([node()]) -> ok.
wait_for_all_trees(Cluster) ->
    F = fun(Node) ->
                lager:info("Check if all trees built for node ~p", [Node]),
                Info = rpc:call(Node, yz_kv, compute_tree_info, []),
                NotBuilt = [X || {_,undefined}=X <- Info],
                NotBuilt == []
        end,
    rt:wait_until(Cluster, F),
    ok.

%% @doc Wait for a full exchange round since `Timestamp'.  This means
%%      that all `{Idx,N}' for all partitions must have exchanged after
%%      `Timestamp'.
-spec wait_for_full_exchange_round([node()], os:now()) -> ok.
wait_for_full_exchange_round(Cluster, Timestamp) ->
    lager:info("wait for full AAE exchange round on cluster ~p", [Cluster]),
    MoreRecent =
        fun({_Idx, _, undefined, _RepairStats}) ->
                false;
           ({_Idx, _, AllExchangedTime, _RepairStats}) ->
                AllExchangedTime > Timestamp
        end,
    AllExchanged =
        fun(Node) ->
                Exchanges = rpc:call(Node, yz_kv, compute_exchange_info, []),
                {_Recent, WaitingFor1} = lists:partition(MoreRecent, Exchanges),
                WaitingFor2 = [element(1,X) || X <- WaitingFor1],
                lager:info("Still waiting for AAE of ~p ~p", [Node, WaitingFor2]),
                [] == WaitingFor2
        end,
    rt:wait_until(Cluster, AllExchanged),
    ok.

%% @doc Wait for index creation. This is to handle *legacy* versions of yokozuna
%%      in upgrade tests
-spec wait_for_index(list(), index_name()) -> ok.
wait_for_index(Cluster, Index) ->
    IsIndexUp =
        fun(Node) ->
                lager:info("Waiting for index ~s to be avaiable on node ~p",
                           [Index, Node]),
                rpc:call(Node, yz_solr, ping, [Index])
        end,
    [?assertEqual(ok, rt:wait_until(Node, IsIndexUp)) || Node <- Cluster],
    ok.

%% @doc Expire YZ trees
-spec expire_trees([node()]) -> ok.
expire_trees(Cluster) ->
    lager:info("Expire all trees"),
    _ = [ok = rpc:call(Node, yz_entropy_mgr, expire_trees, [])
         || Node <- Cluster],

    %% The expire is async so just give it a moment
    timer:sleep(100),
    ok.

verify_num_found_query(Cluster, Index, ExpectedCount) ->
    F = fun(Node) ->
                Pid = rt:pbc(Node),
                {ok, {_, _, _, NumFound}} = riakc_pb_socket:search(Pid, Index, <<"*:*">>),
                lager:info("Check Count, Expected: ~p | Actual: ~p~n",
                           [ExpectedCount, NumFound]),
                ExpectedCount =:= NumFound
        end,
    rt:wait_until(Cluster, F),
    ok.