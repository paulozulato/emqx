%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_connector_oracle).

-behaviour(emqx_resource).

-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx_ee_connector/include/emqx_ee_connector.hrl").

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%%====================================================================
%% Exports
%%====================================================================

%% Hocon config schema exports
-export([
    roots/0,
    fields/1
]).

%% callbacks for behaviour emqx_resource
-export([
    callback_mode/0,
    is_buffer_supported/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_query_async/4,
    on_batch_query_async/4,
    on_get_status/2
]).

%% callbacks for ecpool
-export([connect/1]).

%% Internal exports used to execute code with ecpool worker
-export([
    query/3,
    execute_batch/3,
    do_async_reply/2,
    do_get_status/1
]).

-import(emqx_plugin_libs_rule, [str/1]).
-import(hoconsc, [mk/2, enum/1, ref/2]).

-define(ACTION_SEND_MESSAGE, send_message).

-define(SYNC_QUERY_MODE, no_handover).
-define(ASYNC_QUERY_MODE(REPLY), {handover_async, {?MODULE, do_async_reply, [REPLY]}}).

-define(ORACLE_HOST_OPTIONS, #{
    default_port => ?ORACLE_DEFAULT_PORT
}).

-define(MAX_CURSORS, 10).
-define(DEFAULT_POOL_SIZE, 8).
-define(OPT_TIMEOUT, 30000).

-type prepares() :: #{atom() => binary()}.
-type params_tokens() :: #{atom() => list()}.

-type state() ::
    #{
        poolname := atom(),
        prepare_sql := prepares(),
        params_tokens := params_tokens(),
        batch_params_tokens := params_tokens()
    }.

%%=====================================================================
%% Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    [{server, server()}, {sid, fun sid/1}] ++
        emqx_connector_schema_lib:relational_db_fields() ++
        emqx_connector_schema_lib:ssl_fields() ++
        emqx_connector_schema_lib:prepare_statement_fields().

server() ->
    Meta = #{desc => ?DESC("server")},
    emqx_schema:servers_sc(Meta, ?ORACLE_HOST_OPTIONS).

sid(type) -> binary();
sid(desc) -> ?DESC("sid");
sid(required) -> false;
sid(_) -> undefined.

%% ===================================================================
callback_mode() -> async_if_possible.

is_buffer_supported() -> false.

-spec on_start(binary(), hoconsc:config()) -> {ok, state()} | {error, _}.
on_start(
    InstId,
    #{
        server := Server,
        database := DB,
        sid := Sid,
        username := User,
        ssl := SSL
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_oracle_connector",
        connector => InstId,
        config => emqx_misc:redact(Config)
    }),
    {ok, _} = application:ensure_all_started(ecpool),
    {ok, _} = application:ensure_all_started(jamdb_oracle),
    jamdb_oracle_conn:set_max_cursors_number(?MAX_CURSORS),

    {Host, Port} = emqx_schema:parse_server(Server, ?ORACLE_HOST_OPTIONS),
    ServiceName =
        case maps:get(<<"service_name">>, Config, Sid) of
            <<>> -> Sid;
            Name -> Name
        end,
    SslOpts =
        case maps:get(enable, SSL) of
            true ->
                [{ssl, emqx_tls_lib:to_client_opts(SSL)}];
            false ->
                [{ssl, false}]
        end,
    Options = [
        {host, Host},
        {port, Port},
        {user, emqx_plugin_libs_rule:str(User)},
        {password, maps:get(password, Config, "")},
        {sid, emqx_plugin_libs_rule:str(Sid)},
        {service_name, emqx_plugin_libs_rule:str(ServiceName)},
        {database, DB},
        {auto_reconnect,
            case maps:get(<<"auto_reconnect">>, Config, true) of
                true -> ?AUTO_RECONNECT_INTERVAL;
                false -> false
            end},
        {pool_size, maps:get(<<"pool_size">>, Config, ?DEFAULT_POOL_SIZE)}
    ],
    PoolName = emqx_plugin_libs_pool:pool_name(InstId),
    Prepares = parse_prepare_sql(Config),
    InitState = #{poolname => PoolName, prepare_statement => #{}},
    State = maps:merge(InitState, Prepares),

    case emqx_plugin_libs_pool:start_pool(PoolName, ?MODULE, Options ++ SslOpts) of
        ok ->
            {ok, init_prepare(State)};
        {error, Reason} ->
            ?tp(
                oracle_connector_start_failed,
                #{error => Reason}
            ),
            {error, Reason}
    end.

on_stop(InstId, #{poolname := PoolName}) ->
    ?SLOG(info, #{
        msg => "stopping_oracle_connector",
        connector => InstId
    }),
    emqx_plugin_libs_pool:stop_pool(PoolName).

on_query(InstId, {TypeOrKey, NameOrSQL}, #{poolname := _PoolName} = State) ->
    on_query(InstId, {TypeOrKey, NameOrSQL, []}, State);
on_query(
    InstId,
    {TypeOrKey, NameOrSQL, Params},
    #{poolname := PoolName} = State
) ->
    ?SLOG(debug, #{
        msg => "oracle database connector received sql query",
        connector => InstId,
        type => TypeOrKey,
        sql => NameOrSQL,
        state => State
    }),
    Type = query_type(TypeOrKey),
    {NameOrSQL2, Data} = proc_sql_params(TypeOrKey, NameOrSQL, Params, State),
    Res = on_sql_query(InstId, PoolName, Type, ?SYNC_QUERY_MODE, NameOrSQL2, Data),
    handle_result(Res).

on_query_async(
    InstId, {TypeOrKey, NameOrSQL} = Query, Reply, #{poolname := PoolName} = State
) ->
    ?SLOG(debug, #{
        msg => "oracle database connector received async sql query",
        connector => InstId,
        query => Query,
        reply => Reply,
        state => State
    }),
    ApplyMode = ?ASYNC_QUERY_MODE(Reply),
    Type = query_type(TypeOrKey),
    {NameOrSQL2, Data} = proc_sql_params(TypeOrKey, NameOrSQL, [], State),
    Res = on_sql_query(InstId, PoolName, Type, ApplyMode, NameOrSQL2, Data),
    handle_result(Res).

query_type(sql) ->
    query;
query_type(query) ->
    query;
%% Data that goes to bridges use the prepared template
query_type(?ACTION_SEND_MESSAGE) ->
    query.

on_batch_query(
    InstId,
    BatchReq,
    #{poolname := PoolName, params_tokens := Tokens, prepare_statement := Sts} = State
) ->
    case BatchReq of
        [{Key, _} = Request | _] ->
            BinKey = to_bin(Key),
            case maps:get(BinKey, Tokens, undefined) of
                undefined ->
                    Log = #{
                        connector => InstId,
                        first_request => Request,
                        state => State,
                        msg => "batch prepare not implemented"
                    },
                    ?SLOG(error, Log),
                    {error, {unrecoverable_error, batch_prepare_not_implemented}};
                TokenList ->
                    {_, Datas} = lists:unzip(BatchReq),
                    Datas2 = [emqx_plugin_libs_rule:proc_sql(TokenList, Data) || Data <- Datas],
                    St = maps:get(BinKey, Sts),
                    case
                        on_sql_query(InstId, PoolName, execute_batch, ?SYNC_QUERY_MODE, St, Datas2)
                    of
                        {error, _Type, _Error} = Result ->
                            handle_result(Result);
                        {ok, Results} ->
                            handle_batch_result(Results, 0)
                    end
            end;
        _ ->
            Log = #{
                connector => InstId,
                request => BatchReq,
                state => State,
                msg => "invalid request"
            },
            ?SLOG(error, Log),
            {error, {unrecoverable_error, invalid_request}}
    end.

on_batch_query_async(
    InstId,
    BatchReq,
    Reply,
    #{poolname := PoolName, params_tokens := Tokens, prepare_statement := Sts} = State
) ->
    case BatchReq of
        [{Key, _} = Request | _] ->
            BinKey = to_bin(Key),
            case maps:get(BinKey, Tokens, undefined) of
                undefined ->
                    Log = #{
                        connector => InstId,
                        first_request => Request,
                        state => State,
                        msg => "batch prepare not implemented"
                    },
                    ?SLOG(error, Log),
                    {error, {unrecoverable_error, batch_prepare_not_implemented}};
                TokenList ->
                    {_, Datas} = lists:unzip(BatchReq),
                    Datas2 = [emqx_plugin_libs_rule:proc_sql(TokenList, Data) || Data <- Datas],
                    St = maps:get(BinKey, Sts),
                    case
                        on_sql_query(
                            InstId, PoolName, execute_batch, ?ASYNC_QUERY_MODE(Reply), St, Datas2
                        )
                    of
                        ok = Result ->
                            handle_result(Result);
                        {error, _Type, _Error} = Result ->
                            handle_result(Result);
                        {ok, Results} ->
                            handle_batch_result(Results, 0)
                    end
            end;
        _ ->
            Log = #{
                connector => InstId,
                request => BatchReq,
                state => State,
                msg => "invalid request"
            },
            ?SLOG(error, Log),
            {error, {unrecoverable_error, invalid_request}}
    end.

proc_sql_params(query, SQLOrKey, Params, _State) ->
    {SQLOrKey, Params};
proc_sql_params(TypeOrKey, SQLOrData, Params, #{
    params_tokens := ParamsTokens, prepare_sql := PrepareSql
}) ->
    Key = to_bin(TypeOrKey),
    case maps:get(Key, ParamsTokens, undefined) of
        undefined ->
            {SQLOrData, Params};
        Tokens ->
            case maps:get(Key, PrepareSql, undefined) of
                undefined ->
                    {SQLOrData, Params};
                Sql ->
                    {Sql, emqx_plugin_libs_rule:proc_sql(Tokens, SQLOrData)}
            end
    end.

on_sql_query(InstId, PoolName, Type, ApplyMode, NameOrSQL, Data) ->
    try ecpool:pick_and_do(PoolName, {?MODULE, Type, [NameOrSQL, Data]}, ApplyMode) of
        {error, Reason} = Result ->
            ?tp(
                oracle_connector_query_return,
                #{error => Reason}
            ),
            ?SLOG(error, #{
                msg => "oracle database connector do sql query failed",
                connector => InstId,
                type => Type,
                sql => NameOrSQL,
                reason => Reason
            }),
            Result;
        Result ->
            ?tp(
                oracle_connector_query_return,
                #{result => Result}
            ),
            Result
    catch
        error:function_clause:Stacktrace ->
            ?SLOG(error, #{
                msg => "oracle database connector do sql query failed",
                connector => InstId,
                type => Type,
                sql => NameOrSQL,
                reason => function_clause,
                stacktrace => Stacktrace
            }),
            {error, {unrecoverable_error, invalid_request}}
    end.

on_get_status(_InstId, #{poolname := Pool} = State) ->
    case emqx_plugin_libs_pool:health_check_ecpool_workers(Pool, fun ?MODULE:do_get_status/1) of
        true ->
            case do_check_prepares(State) of
                ok ->
                    connected;
                {ok, NState} ->
                    %% return new state with prepared statements
                    {connected, NState};
                false ->
                    %% do not log error, it is logged in prepare_sql_to_conn
                    connecting
            end;
        false ->
            connecting
    end.

do_get_status(Conn) ->
    ok == element(1, jamdb_oracle:sql_query(Conn, "select 1 from dual")).

do_check_prepares(#{prepare_sql := Prepares}) when is_map(Prepares) ->
    ok;
do_check_prepares(State = #{poolname := PoolName, prepare_sql := {error, Prepares}}) ->
    %% retry to prepare
    case prepare_sql(Prepares, PoolName) of
        {ok, Sts} ->
            %% remove the error
            {ok, State#{prepare_sql => Prepares, prepare_statement := Sts}};
        _Error ->
            false
    end.

%% ===================================================================

connect(Opts) ->
    ConnectOpts = [
        lists:keyfind(host, 1, Opts),
        lists:keyfind(port, 1, Opts),
        lists:keyfind(database, 1, Opts),
        lists:keyfind(user, 1, Opts),
        lists:keyfind(password, 1, Opts),
        lists:keyfind(service_name, 1, Opts),
        {timeout, ?OPT_TIMEOUT},
        {app_name, "EMQX Data To Oracle Database Action"}
    ],
    jamdb_oracle:start_link(ConnectOpts).

sql_query_to_str(SqlQuery) ->
    emqx_plugin_libs_rule:str(SqlQuery).

sql_params_to_str(Params) when is_list(Params) ->
    lists:map(
        fun
            (false) -> "0";
            (true) -> "1";
            (Value) -> emqx_plugin_libs_rule:str(Value)
        end,
        Params
    ).

query(Conn, SQL, Params) ->
    jamdb_oracle:sql_query(Conn, {sql_query_to_str(SQL), sql_params_to_str(Params)}).

execute_batch(Conn, Statement, ParamsList) ->
    ParamsListStr = lists:map(fun sql_params_to_str/1, ParamsList),
    jamdb_oracle:sql_query(Conn, {batch, sql_query_to_str(Statement), ParamsListStr}).

% conn_opts(Opts) ->
%     conn_opts(Opts, []).
% conn_opts([], Acc) ->
%     Acc;
% conn_opts([Opt = {database, _} | Opts], Acc) ->
%     conn_opts(Opts, [Opt | Acc]);
% conn_opts([{ssl, Bool} | Opts], Acc) when is_boolean(Bool) ->
%     Flag =
%         case Bool of
%             true -> required;
%             false -> false
%         end,
%     conn_opts(Opts, [{ssl, Flag} | Acc]);
% conn_opts([Opt = {port, _} | Opts], Acc) ->
%     conn_opts(Opts, [Opt | Acc]);
% conn_opts([Opt = {timeout, _} | Opts], Acc) ->
%     conn_opts(Opts, [Opt | Acc]);
% conn_opts([Opt = {ssl_opts, _} | Opts], Acc) ->
%     conn_opts(Opts, [Opt | Acc]);
% conn_opts([_Opt | Opts], Acc) ->
%     conn_opts(Opts, Acc).

parse_prepare_sql(Config) ->
    SQL =
        case maps:get(prepare_statement, Config, undefined) of
            undefined ->
                case maps:get(sql, Config, undefined) of
                    undefined -> #{};
                    Template -> #{<<"send_message">> => Template}
                end;
            Any ->
                Any
        end,
    parse_prepare_sql(maps:to_list(SQL), #{}, #{}).

parse_prepare_sql([{Key, H} | T], Prepares, Tokens) ->
    {PrepareSQL, ParamsTokens} = emqx_plugin_libs_rule:preproc_sql(H, ':n'),
    parse_prepare_sql(
        T, Prepares#{Key => PrepareSQL}, Tokens#{Key => ParamsTokens}
    );
parse_prepare_sql([], Prepares, Tokens) ->
    #{
        prepare_sql => Prepares,
        params_tokens => Tokens
    }.

init_prepare(State = #{prepare_sql := Prepares, poolname := PoolName}) ->
    case maps:size(Prepares) of
        0 ->
            State;
        _ ->
            case prepare_sql(Prepares, PoolName) of
                {ok, Sts} ->
                    State#{prepare_statement := Sts};
                Error ->
                    LogMeta = #{
                        msg => <<"Oracle Database init prepare statement failed">>, error => Error
                    },
                    ?SLOG(error, LogMeta),
                    %% mark the prepare_sql as failed
                    State#{prepare_sql => {error, Prepares}}
            end
    end.

prepare_sql(Prepares, PoolName) when is_map(Prepares) ->
    prepare_sql(maps:to_list(Prepares), PoolName);
prepare_sql(Prepares, PoolName) ->
    case do_prepare_sql(Prepares, PoolName) of
        {ok, _Sts} = Ok ->
            %% prepare for reconnect
            ecpool:add_reconnect_callback(PoolName, {?MODULE, prepare_sql_to_conn, [Prepares]}),
            Ok;
        Error ->
            Error
    end.

do_prepare_sql(Prepares, PoolName) ->
    do_prepare_sql(ecpool:workers(PoolName), Prepares, PoolName, #{}).

do_prepare_sql([{_Name, Worker} | T], Prepares, PoolName, _LastSts) ->
    {ok, Conn} = ecpool_worker:client(Worker),
    case prepare_sql_to_conn(Conn, Prepares) of
        {ok, Sts} ->
            do_prepare_sql(T, Prepares, PoolName, Sts);
        Error ->
            Error
    end;
do_prepare_sql([], _Prepares, _PoolName, LastSts) ->
    {ok, LastSts}.

prepare_sql_to_conn(Conn, Prepares) ->
    prepare_sql_to_conn(Conn, Prepares, #{}).

prepare_sql_to_conn(Conn, [], Statements) when is_pid(Conn) -> {ok, Statements};
prepare_sql_to_conn(Conn, [{Key, SQL} | PrepareList], Statements) when is_pid(Conn) ->
    LogMeta = #{msg => "Oracle Database Prepare Statement", name => Key, prepare_sql => SQL},
    ?SLOG(info, LogMeta),
    prepare_sql_to_conn(Conn, PrepareList, Statements#{Key => SQL}).

to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(Atom) when is_atom(Atom) ->
    erlang:atom_to_binary(Atom).

handle_result({error, disconnected}) ->
    {error, {recoverable_error, disconnected}};
handle_result({error, Error}) ->
    {error, {unrecoverable_error, Error}};
handle_result({error, Type, Reason}) ->
    {error, {unrecoverable_error, {Type, Reason}}};
handle_result(Res) ->
    Res.

handle_batch_result([{affected_rows, RowCount} | Rest], Acc) ->
    handle_batch_result(Rest, Acc + RowCount);
handle_batch_result([{proc_result, RetCode, _Rows} | Rest], Acc) when RetCode =:= 0 ->
    handle_batch_result(Rest, Acc);
handle_batch_result([{proc_result, RetCode, Reason} | _Rest], _Acc) ->
    {error, {unrecoverable_error, {RetCode, Reason}}};
handle_batch_result([], Acc) ->
    {ok, Acc}.

do_async_reply(Result, {ReplyFun, [Context]}) ->
    ReplyFun(Context, Result).
