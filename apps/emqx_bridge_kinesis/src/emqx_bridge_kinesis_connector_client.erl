%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_kinesis_connector_client).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("erlcloud/include/erlcloud_aws.hrl").
-include_lib("emqx/include/logger.hrl").

-behaviour(gen_server).

-type state() :: #{
    instance_id := resource_id(),
    partition_key := binary(),
    stream_name := binary()
}.
-type record() :: {Data :: binary(), PartitionKey :: binary()}.

-define(DEFAULT_PORT, 443).

%% API
-export([
    start_link/1,
    connection_status/1,
    query/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([execute/2]).
-endif.

%% The default timeout for Kinesis API calls is 10 seconds,
%% but this value for `gen_server:call` is 5s,
%% so we should adjust timeout for `gen_server:call`
-define(HEALTH_CHECK_TIMEOUT, 15000).

%%%===================================================================
%%% API
%%%===================================================================
connection_status(Pid) ->
    try
        gen_server:call(Pid, connection_status, ?HEALTH_CHECK_TIMEOUT)
    catch
        _:_ ->
            {error, timeout}
    end.

query(Pid, Records) ->
    gen_server:call(Pid, {query, Records}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Starts Bridge which communicates to Amazon Kinesis Data Streams
%% @end
%%--------------------------------------------------------------------
start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% Initialize kinesis connector
-spec init(emqx_bridge_kinesis_impl_producer:config()) -> {ok, state()}.
init(#{
    aws_access_key_id := AwsAccessKey,
    aws_secret_access_key := AwsSecretAccessKey,
    endpoint := Endpoint,
    partition_key := PartitionKey,
    stream_name := StreamName,
    max_retries := MaxRetries,
    instance_id := InstanceId
}) ->
    process_flag(trap_exit, true),

    #{scheme := Scheme, hostname := Host, port := Port} =
        emqx_schema:parse_server(
            Endpoint,
            #{
                default_port => ?DEFAULT_PORT,
                supported_schemes => ["http", "https"]
            }
        ),
    State = #{
        instance_id => InstanceId,
        partition_key => PartitionKey,
        stream_name => StreamName
    },
    New =
        fun(AccessKeyID, SecretAccessKey, HostAddr, HostPort, ConnectionScheme) ->
            Config0 = erlcloud_kinesis:new(
                AccessKeyID,
                SecretAccessKey,
                HostAddr,
                HostPort,
                ConnectionScheme ++ "://"
            ),
            Config0#aws_config{retry_num = MaxRetries}
        end,
    erlcloud_config:configure(
        to_str(AwsAccessKey), to_str(AwsSecretAccessKey), Host, Port, Scheme, New
    ),
    % check the connection
    case erlcloud_kinesis:list_streams() of
        {ok, _} ->
            {ok, State};
        {error, Reason} ->
            ?tp(kinesis_init_failed, #{instance_id => InstanceId, reason => Reason}),
            ?SLOG(error, #{
                msg => "failed_to_list_stream",
                instance_id => InstanceId,
                stream_name => StreamName,
                reason => Reason
            }),
            {stop, Reason}
    end.

handle_call(
    connection_status, _From, #{stream_name := StreamName, instance_id := InstanceId} = State
) ->
    Status =
        case erlcloud_kinesis:describe_stream(StreamName) of
            {ok, _} ->
                {ok, connected};
            {error, {<<"ResourceNotFoundException">>, _}} ->
                ?SLOG(error, #{
                    msg => "failed_to_describe_stream",
                    instance_id => InstanceId,
                    stream_name => StreamName,
                    reason => "Resource not found"
                }),
                {error, resource_not_found};
            {error, {<<"AccessDeniedException">>, _}} ->
                ?SLOG(error, #{
                    msg => "failed_to_describe_stream",
                    instance_id => InstanceId,
                    stream_name => StreamName,
                    reason => "Access denied"
                }),
                {error, access_denied};
            Error ->
                ?SLOG(error, #{
                    msg => "failed_to_describe_stream",
                    instance_id => InstanceId,
                    stream_name => StreamName,
                    reason => Error
                }),
                {error, Error}
        end,
    {reply, Status, State};
handle_call({query, Records}, _From, #{stream_name := StreamName} = State) ->
    Result = do_query(StreamName, Records),
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, #{instance_id := InstanceId} = _State) ->
    ?tp(kinesis_stop, #{instance_id => InstanceId, reason => Reason}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec do_query(binary(), [record()]) ->
    {ok, jsx:json_term() | binary()}
    | {error, {unrecoverable_error, term()}}
    | {error, term()}.
do_query(StreamName, Records) ->
    try
        execute(put_record, {StreamName, Records})
    catch
        _Type:Reason ->
            {error, {unrecoverable_error, {invalid_request, Reason}}}
    end.

-spec execute(put_record, {binary(), [record()]}) ->
    {ok, jsx:json_term() | binary()}
    | {error, term()}.
execute(put_record, {StreamName, [{Data, PartitionKey}] = Record}) ->
    Result = erlcloud_kinesis:put_record(StreamName, PartitionKey, Data),
    ?tp(kinesis_put_record, #{records => Record, result => Result}),
    Result;
execute(put_record, {StreamName, Items}) when is_list(Items) ->
    Result = erlcloud_kinesis:put_records(StreamName, Items),
    ?tp(kinesis_put_record, #{records => Items, result => Result}),
    Result.

-spec to_str(list() | binary()) -> list().
to_str(List) when is_list(List) ->
    List;
to_str(Bin) when is_binary(Bin) ->
    erlang:binary_to_list(Bin).
