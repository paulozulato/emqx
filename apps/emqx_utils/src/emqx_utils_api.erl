%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_utils_api).

-export([
    with_node/2,
    with_node_or_cluster/2
]).

-include("emqx_utils_api.hrl").

-define(NODE_NOT_FOUND(NODE), ?NOT_FOUND(<<"Node not found: ", NODE/binary>>)).

%%--------------------------------------------------------------------
%% exported API
%%--------------------------------------------------------------------
-spec with_node(binary() | atom(), fun((atom()) -> {ok, term()} | {error, term()})) ->
    ?OK(term()) | ?NOT_FOUND(binary()) | ?BAD_REQUEST(term()).
with_node(Node0, Fun) ->
    case lookup_node(Node0) of
        {ok, Node} ->
            handle_result(Fun(Node));
        not_found ->
            ?NODE_NOT_FOUND(Node0)
    end.

-spec with_node_or_cluster(binary() | atom(), fun((atom()) -> {ok, term()} | {error, term()})) ->
    ?OK(term()) | ?NOT_FOUND(iolist()) | ?BAD_REQUEST(term()).
with_node_or_cluster(<<"all">>, Fun) ->
    handle_result(Fun(all));
with_node_or_cluster(Node, Fun) ->
    with_node(Node, Fun).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec lookup_node(atom() | binary()) -> {ok, atom()} | not_found.
lookup_node(BinNode) when is_binary(BinNode) ->
    case emqx_utils:safe_to_existing_atom(BinNode, utf8) of
        {ok, Node} ->
            is_running_node(Node);
        _Error ->
            not_found
    end;
lookup_node(Node) when is_atom(Node) ->
    is_running_node(Node).

-spec is_running_node(atom()) -> {ok, atom()} | not_found.
is_running_node(Node) ->
    case lists:member(Node, mria:running_nodes()) of
        true ->
            {ok, Node};
        false ->
            not_found
    end.

handle_result({ok, Result}) ->
    ?OK(Result);
handle_result({error, Reason}) ->
    ?BAD_REQUEST(Reason).
