%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_kinesis_impl_producer).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(HEALTH_CHECK_TIMEOUT, 15000).
-define(TOPIC_MESSAGE,
    "Kinesis stream is invalid. Please check the logs, check if the stream exist "
    "in Kinesis account and if service account has permissions to use it."
).
-define(PERMISSION_MESSAGE,
    "Permission denied while interacting with endpoint. Please check that the "
    "provided service account has the correct permissions configured."
).

-type config() :: #{
    aws_access_key_id := binary(),
    aws_secret_access_key := binary(),
    endpoint := binary(),
    stream_name := binary(),
    partition_key := binary(),
    payload_template := binary(),
    max_retries := non_neg_integer(),
    pool_size := non_neg_integer(),
    instance_id => resource_id(),
    any() => term()
}.
-type templates() :: #{
    partition_key := list(),
    send_message := list()
}.
-type state() :: #{
    pool_name := resource_id(),
    templates := templates()
}.
-export_type([config/0]).

%% `emqx_resource' API
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_get_status/2
]).

-export([
    connect/1
]).

%%-------------------------------------------------------------------------------------------------
%% `emqx_resource' API
%%-------------------------------------------------------------------------------------------------

callback_mode() -> always_sync.

-spec on_start(resource_id(), config()) -> {ok, state()} | {error, term()}.
on_start(
    InstanceId,
    #{
        pool_size := PoolSize
    } = Config0
) ->
    ?SLOG(info, #{
        msg => "starting_kinesis_bridge",
        connector => InstanceId,
        config => redact(Config0)
    }),
    Config = Config0#{instance_id => InstanceId},
    Options = [
        {config, Config},
        {pool_size, PoolSize}
    ],
    Templates = parse_template(Config),
    State = #{
        pool_name => InstanceId,
        templates => Templates
    },

    case emqx_resource_pool:start(InstanceId, ?MODULE, Options) of
        ok ->
            ?tp(emqx_bridge_kinesis_impl_producer_start_ok, #{config => Config}),
            {ok, State};
        Error ->
            ?tp(emqx_bridge_kinesis_impl_producer_start_failed, #{config => Config}),
            Error
    end.

-spec on_stop(resource_id(), state()) -> ok | {error, term()}.
on_stop(InstanceId, _State) ->
    emqx_resource_pool:stop(InstanceId).

-spec on_get_status(resource_id(), state()) ->
    connected | disconnected | {disconnected, state(), {unhealthy_target, string()}}.
on_get_status(_InstanceId, #{pool_name := Pool} = State) ->
    case
        emqx_resource_pool:health_check_workers(
            Pool,
            {emqx_bridge_kinesis_connector_client, connection_status, []},
            ?HEALTH_CHECK_TIMEOUT,
            #{return_values => true}
        )
    of
        {ok, Result} ->
            lists:foldl(
                fun
                    ({error, resource_not_found}, connected = _Acc) ->
                        {disconnected, State, {unhealthy_target, ?TOPIC_MESSAGE}};
                    ({error, access_denied}, connected = _Acc) ->
                        {disconnected, State, {unhealthy_target, ?PERMISSION_MESSAGE}};
                    ({error, Reason}, connected = _Acc) ->
                        {disconnected, State, Reason};
                    (_, Acc) ->
                        Acc
                end,
                connected,
                Result
            );
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "kinesis_producer_get_status_failed",
                state => State,
                reason => Reason
            }),
            disconnected
    end.

-spec on_query(
    resource_id(),
    {send_message, map()},
    state()
) ->
    {ok, map()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_query(ResourceId, {send_message, Message}, State) ->
    Requests = [{send_message, Message}],
    ?tp(emqx_bridge_kinesis_impl_producer_sync_query, #{message => Message}),
    do_send_requests_sync(ResourceId, Requests, State).

-spec on_batch_query(
    resource_id(),
    [{send_message, map()}],
    state()
) ->
    {ok, map()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
%% we only support batch insert
on_batch_query(ResourceId, [{send_message, _} | _] = Requests, State) ->
    ?tp(emqx_bridge_kinesis_impl_producer_sync_batch_query, #{requests => Requests}),
    do_send_requests_sync(ResourceId, Requests, State).

connect(Opts) ->
    Options = proplists:get_value(config, Opts),
    emqx_bridge_kinesis_connector_client:start_link(Options).

%%-------------------------------------------------------------------------------------------------
%% Helper fns
%%-------------------------------------------------------------------------------------------------

-spec do_send_requests_sync(
    resource_id(),
    [{send_message, map()}],
    state()
) ->
    {ok, non_neg_integer()}
    | {error, {recoverable_error, term()}}
    | {error, {unrecoverable_error, {invalid_request, term()}}}
    | {error, {unrecoverable_error, {unhealthy_target, string()}}}
    | {error, {unrecoverable_error, term()}}
    | {error, term()}.
do_send_requests_sync(
    InstanceId,
    Requests,
    #{pool_name := PoolName, templates := Templates}
) ->
    Records = render_records(Requests, Templates),
    Result = ecpool:pick_and_do(
        PoolName,
        {emqx_bridge_kinesis_connector_client, query, [Records]},
        no_handover
    ),
    handle_result(Result, Requests, InstanceId).

handle_result({ok, Result}, Requests, InstanceId) ->
    RequestCount = length(Requests),
    FailedMsgCount = proplists:get_value(<<"FailedRecordCount">>, Result, 0),
    case FailedMsgCount of
        0 ->
            %% zero can mean a single Request success (so there is no FailedRecordCount field
            %% in the response) or all Requests were succeed. In any case, there was no
            %% error processing the request.
            ?tp(emqx_bridge_kinesis_impl_producer_msg_ok, #{count => RequestCount}),
            {ok, RequestCount};
        _ ->
            %% non-zero means that some (or all) message in the request has failed. The possible
            %% reasons are limited to "ProvisionedThroughputExceededException" or "InternalFailure"
            %% (https://docs.aws.amazon.com/kinesis/latest/APIReference/API_PutRecords.html) and
            %% both results will be handled as recoverable error, so all Requests might be retried
            %% as we do not support partial success on batch requests.
            %% @TODO: support partial success on batch requests
            {OkCount, ThroughputCount, InternalErrorCount} = lists:foldl(
                fun(RecordResult, {OkCount, ThroughputCount, InternalErrorCount}) ->
                    case proplists:get_value(<<"ErrorCode">>, RecordResult, undefined) of
                        undefined ->
                            {OkCount + 1, ThroughputCount, InternalErrorCount};
                        <<"ProvisionedThroughputExceededException">> ->
                            {OkCount, ThroughputCount + 1, InternalErrorCount};
                        <<"InternalFailure">> ->
                            {OkCount, ThroughputCount, InternalErrorCount + 1}
                    end
                end,
                {0, 0, 0},
                proplists:get_value(<<"Records">>, Result, [])
            ),
            ResultSummary = #{
                succeed => OkCount,
                throughput_exceeded => ThroughputCount,
                internal_error => InternalErrorCount
            },
            ?SLOG(error, #{
                msg => "kinesis_error_response",
                request => Requests,
                connector => InstanceId,
                result => ResultSummary
            }),
            ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => ResultSummary}),
            {error, {recoverable_error, ResultSummary}}
    end;
% handle_result(
%     {error, {<<"ProvisionedThroughputExceededException">>, _} = Reason}, Requests, InstanceId
% ) ->
%     ?SLOG(error, #{
%         msg => "kinesis_error_response",
%         request => Requests,
%         connector => InstanceId,
%         reason => Reason
%     }),
%     {error, {recoverable_error, Reason}};
handle_result({error, {<<"ResourceNotFoundException">>, _} = Reason}, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => <<"ResourceNotFoundException">>}),
    {error, {unrecoverable_error, {unhealthy_target, ?TOPIC_MESSAGE}}};
handle_result({error, {<<"AccessDeniedException">>, _} = Reason}, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    {error, {unrecoverable_error, {unhealthy_target, ?PERMISSION_MESSAGE}}};
handle_result({error, {<<"InvalidArgumentException">>, _} = Reason}, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => <<"InvalidArgumentException">>}),
    {error, {unrecoverable_error, Reason}};
handle_result({error, {<<"ValidationException">>, _} = Reason}, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => <<"ValidationException">>}),
    {error, {unrecoverable_error, Reason}};
handle_result({error, {econnrefused = Reason, _} = Error}, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => Error}),
    {error, {recoverable_error, Reason}};
handle_result({error, Reason} = Error, Requests, InstanceId) ->
    ?SLOG(error, #{
        msg => "kinesis_error_response",
        request => Requests,
        connector => InstanceId,
        reason => Reason
    }),
    ?tp(emqx_bridge_kinesis_impl_producer_msg_failed, #{result => Error}),
    Error.

parse_template(Config) ->
    #{payload_template := PayloadTemplate, partition_key := PartitionKeyTemplate} = Config,
    Templates = #{send_message => PayloadTemplate, partition_key => PartitionKeyTemplate},
    maps:map(fun(_K, V) -> emqx_placeholder:preproc_tmpl(V) end, Templates).

render_records(Items, Templates) ->
    PartitionKeyTemplate = maps:get(partition_key, Templates),
    MsgTemplate = maps:get(send_message, Templates),
    render_messages(Items, {MsgTemplate, PartitionKeyTemplate}, []).

render_messages([], _Templates, RenderedMsgs) ->
    RenderedMsgs;
render_messages(
    [{send_message, Msg} | Others],
    {MsgTemplate, PartitionKeyTemplate} = Templates,
    RenderedMsgs
) ->
    Data = emqx_placeholder:proc_tmpl(MsgTemplate, Msg),
    PartitionKey = emqx_placeholder:proc_tmpl(PartitionKeyTemplate, Msg),
    RenderedMsg = {Data, PartitionKey},
    render_messages(Others, Templates, [RenderedMsg | RenderedMsgs]).

redact(Config) ->
    emqx_utils:redact(Config, fun(Any) -> Any =:= aws_secret_access_key end).
