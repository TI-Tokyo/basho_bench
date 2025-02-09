%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
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
%% ---------------------------------------------------------------------

%%
%% Please note that the in order
%% to run basho_bench_driver_cs
%% `auth_bypass` must be set to true
%% on the riak_cs app.config

-module(basho_bench_driver_cs).

-include_lib("kernel/include/logger.hrl").

-define(BLOCK, (1024*1024)).
-define(VERYLONG_TIMEOUT, (300*1000)).
-define(REPORTFUN_APPKEY, report_fun).
-define(START_KEY, {?MODULE, start}).
-define(BLOCKSIZE_KEY, {?MODULE, block_size}).
-define(PERHAPS_KEY, perhaps_sleep_done_yet).

-export([new/1,
         run/4]).
-export([bigfile_valgen/2]).

-record(state, { client_id,
                 hosts,
                 bucket,
                 report_fun,
                 working_op,
                 current_host,
                 req_id,
                 http_proxy_host,
                 http_proxy_port
               }).

%% ====================================================================
%% API
%% ====================================================================

-spec new(integer()) -> {ok, term()}.
new(ID) ->
    %% TODO:
    %% We'll start with a single
    %% IP for now
    Ip  = basho_bench_config:get(cs_raw_ip, "127.0.0.1"),
    Port = basho_bench_config:get(cs_raw_port, 8080),
    Disconnect = basho_bench_config:get(cs_disconnect_frequency, infinity),
    erlang:put(disconnect_freq, Disconnect),

    %% Get our measurement units: ops/sec, Byte/sec, KB/sec, KiB/sec, MB/sec, MiB/sec.
    %% Throw a run-time exception if the config file has cs_measurement_units set 
    %% to an unrecognized value.
    {RF_name, ReportFun} =
        %% Use standard IEC units for KB/s, KiB/s, MB/s, MiB/s.
        %% See http://en.wikipedia.org/wiki/Mebibyte for more information.
        case (catch basho_bench_config:get(cs_measurement_units)) of
            N = ops_sec  -> {N, fun(_) -> 1.0 end};
            N = byte_sec -> {N, fun(X) -> X / 1 end};
            N = kb_sec   -> {N, fun(X) -> X / 1000 end};
            N = kib_sec  -> {N, fun(X) -> X / 1024 end};
            N = mb_sec   -> {N, fun(X) -> X / (1000 * 1000) end};
            N = mib_sec  -> {N, fun(X) -> X / (1024 * 1024) end};
            _ ->
                logger:log(
                  error, self(),
                  "Unrecognized value for cs_measurement_units.\n", []),
                exit(unrecognized_value)
        end,
    if ID == 1 ->
            application:start(ibrowse),
            application:start(crypto),
            logger:log(info, self(), "Reporting factor = ~p\n", [RF_name]);
       true ->
            ok
    end,
    %% For ops other than get, basho_bench doesn't give us an explicit
    %% way to pass ReportFun to the necessary place in a purely
    %% functional way.
    application:set_env(?MODULE, ?REPORTFUN_APPKEY, ReportFun),
    put(?PERHAPS_KEY, ID),

    OpsList = basho_bench_config:get(operations, []),
    case RF_name /= ops_sec andalso
         lists:keymember(delete, 1, OpsList) andalso
         length(OpsList) > 1 of
        true ->
            logger:log(
              warning, self(),
              "Mixing delete and non-delete operations together with "
              "~p measurements unit can yield nonsense results!\n\n",
              [RF_name]);
        false ->
            ok
    end,

    Hosts = [{Ip, Port}],
    ProxyHosts  = case basho_bench_config:get(cs_http_proxy_host,
                                              ["127.0.0.1"]) of
                      [C|_] = String when is_integer(C), C < 256 ->
                          [String];
                      T when is_tuple(T) ->
                          [T];
                      Else ->
                          Else
                  end,
    ProxyPort = basho_bench_config:get(cs_http_proxy_port, 8080),
    ProxyTargets = basho_bench_config:normalize_ips(ProxyHosts, ProxyPort),
    {ProxyH, ProxyP} = lists:nth((ID rem length(ProxyTargets)+1), ProxyTargets),
    ID_max = 30,
    if ID == ID_max ->
            logger:log(info, self(), "Suppressing additional proxy info", []);
       ID < ID_max ->
            logger:log(info, self(), "ID ~p Proxy host ~p TCP port ~p\n",
                      [ID, ProxyH, ProxyP]);
       true ->
            ok
    end,

    State = #state{client_id=ID, hosts=Hosts,
                   bucket = basho_bench_config:get(cs_bucket, "test"),
                   report_fun = ReportFun,
                   http_proxy_host = ProxyH, http_proxy_port = ProxyP},
    case ID of
        1 -> ok = setup_user_and_bucket(State);
        _ -> ok
    end,
    {ok, State}.

%% This module does some crazy stuff, but it's there for a reason.
%% The reason is that basho_bench is expecting the run() function to
%% do something that takes a few/several seconds at most.  It is not
%% expecting run() to finish after minutes/hours/days of runtime,
%% which is quite possible when testing 5GB files or larger.
%%
%% So, we adopt a strategy where run() will return after ?BLOCK of
%% data received/sent.  That will allow R to create graphs of the
%% latency of ?BLOCK chunk retrievals.  We will do our own throughput
%% reporting to allow R to graph total throughput in terms of
%% KByte/sec or MByte/sec -- we do it via a kludge, but at least it
%% works.
%%
%% This scheme will also allow b_b's built-in rate-limiting scheme to
%% work, though on a granularity of ?BLOCK increments per second,
%% which is probably still too sucky and may need finer control.

-spec run(atom(), fun(), fun(), term()) -> {{ok, number()}, term()} | {error, term(), term()}.

run(get, KeyGen, _ValueGen, #state{working_op = undefined,
                                   bucket = Bucket} = State) ->
    perhaps_sleep(),
    {NextHost, S2} = next_host(State),
    {Host, Port} = NextHost,
    Key = KeyGen(),
    Url = url(Host, Port, Bucket, Key),
    case do_get_first_unit({Host, Port}, Url, [], S2) of
        {ok, S3} ->
            {{silent, ok}, S3};
        Else ->
            Else
    end;
run(_, _KeyGen, _ValueGen, #state{working_op = get} = State) ->
    perhaps_sleep(),
    case do_get_loop(State) of
        {ok, S2} ->
            {{silent, ok}, S2};
        Else ->
            Else
    end;
run(Op, KeyGen, ValueGen, State) ->
    perhaps_sleep(),
    run2(Op, KeyGen, ValueGen, State).

run2(insert, KeyGen, ValueGen, #state{bucket = Bucket} = State) ->
    {NextHost, S2} = next_host(State),
    ConnInfo = NextHost,
    case insert(KeyGen, ValueGen, ConnInfo, Bucket, State) of
        ok ->
            {{silent, ok}, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run2(delete, KeyGen, _ValueGen, #state{bucket = Bucket} = State) ->
    {NextHost, S2} = next_host(State),
    {Host, Port} = NextHost,
    Key = KeyGen(),
    Url = url(Host, Port, Bucket, Key),
    case do_delete({Host, Port}, Url, [], State) of
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run2(copy, KeyGen, _ValueGen, #state{bucket = Bucket} = State) ->
    {NextHost, S2} = next_host(State),
    {Host, Port} = NextHost,
    SourceKey = KeyGen(),
    DestKey = SourceKey ++ basho_bench_config:get(cs_copy_suffix, "-copy"),
    Url = url(Host, Port, Bucket, DestKey),
    Headers = [{"x-amz-copy-source", "/" ++ Bucket ++ "/" ++ SourceKey}],
    case do_copy({Host, Port}, Url, Headers, State) of
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run2(Op, _KeyGen, _ValueGen, State) ->
    {error, {unknown_op, Op}, State}.

perhaps_sleep() ->
    case get(?PERHAPS_KEY) of
        ID when is_integer(ID) ->
            %% For large numbers of load generators, it's a good idea to
            %% stagger things out a little bit to avoid thundering herd
            %% problems at the server side.
            put(?PERHAPS_KEY, yes_we_slept),
            timer:sleep(basho_bench_config:get(cs_new_delay, 25) * (ID - 1));
        _ ->
            ok
    end.

%% The ibrowse client can take a {fun-arity-1, Arg::term()} tuple for
%% a value and use the fun to generate body bytes on-the-fly.
%%
%% Proplist:
%%
%% file_size -- Size of the S3 file that we'll be uploading to the
%%              S3/S3-like service.  Right now, this is a constant value.
%%              If a variable file size is needed, we'll have to add code
%%              to do it.  No default: this property *must* be defined.
%% max_rate_per_chunk -- Maximum rate per second that an
%%                       'ibrowse_chunk_size' sized piece of data will
%%                       be transmitted.
%%                       NOTE: This rate is global/shared across all
%%                             worker processes.
%%                       Default = no limit.
%% ibrowse_chunk_size -- Amount of data that the ibrowse data chunk
%%                       creation function will create.  Default = 1MByte.

bigfile_valgen(Id, Props) ->
    if Id == 1 ->
            logger:log(info, self(), "~p value gen props: ~p\n", [?MODULE, Props]);
       true ->
            ok
    end,
    FileSize = proplists:get_value(file_size, Props, file_size_undefined),
    ChunkSize = proplists:get_value(ibrowse_chunk_size, Props, 1024*1024),
    MaxRate = proplists:get_value(max_rate_per_chunk, Props, 9999999) /
        basho_bench_config:get(concurrent),
    MaxRateSleepUS = trunc((1 / MaxRate) * 1000000),

    Chunk = list_to_binary(lists:duplicate(ChunkSize, 42)),
    {fun(get_content_length) ->
             FileSize;
        (Start) when Start < FileSize ->
             case erlang:get(?START_KEY) of
                 undefined ->
                     ok; %% This is our first call, so no timing to report.
                 StartT ->
                     DiffT = timer:now_diff(os:timestamp(), StartT),
                     ReportFun = element(2, application:get_env(
                                              ?MODULE, ?REPORTFUN_APPKEY)),
                     SleepUS = erlang:max(0, MaxRateSleepUS - DiffT),
                     %% io:format(user, "LINE ~p time ~p\n", [?LINE, SleepUS div 1000]),
                     timer:sleep(SleepUS div 1000),
                     LastChunkSize = erlang:get(?BLOCKSIZE_KEY),
                     basho_bench_stats:op_complete(
                       {insert,insert}, {ok, ReportFun(LastChunkSize)}, DiffT)
             end,
             %% Alright, now set up for the next block to write.
             PrefixSize = erlang:min(FileSize - Start, ChunkSize),
             erlang:put(?START_KEY, os:timestamp()),
             erlang:put(?BLOCKSIZE_KEY, PrefixSize),
             <<Prefix:PrefixSize/binary, _/binary>> = Chunk,
             {ok, Prefix, Start + PrefixSize};
        (_Start) ->
             eof
     end, 0}.

%% ====================================================================
%% Internal functions
%% ====================================================================

insert(KeyGen, ValueGen, {Host, Port}, Bucket, State) ->
    Key = KeyGen(),
    Url = url(Host, Port, Bucket, Key),
    {ValueT, CL} =
        case ValueGen of
            {ValFunc, _ValArg} when is_function(ValFunc, 1) ->
                %% Ibrowse can be given a Value that is a tuple of
                %% {func-arity-1, term()} that will generate an
                %% partial amount of data at a time.  That fun
                %% should return:
                %% a. {ok, Data, ArgForNextCall}
                %% b. eof
                %%
                %% However, we've augmented that function to be able to
                %% tell us its content length.
                {ValueGen, ValFunc(get_content_length)};
            _ ->
                logger:log(
                  error, self(),
                  "This driver cannot use the standard basho_bench "
                  "generator functions, please see refer to "
                  "'cs.config.sample' file for an example.\n", []),
                exit(bad_generator)
        end,
    do_put({Host, Port}, Url, [{"content-length", integer_to_list(CL)}], ValueT,
           State).

url(Host, Port, Bucket, undefined) ->
    UnparsedUrl = lists:concat(["http://", Host, ":", Port, "/", Bucket]),
    ibrowse_lib:parse_url(UnparsedUrl);
url(Host, Port, Bucket, Key) ->
    UnparsedUrl = lists:concat(["http://", Host, ":", Port, "/", Bucket, "/", Key]),
    ibrowse_lib:parse_url(UnparsedUrl).

-spec next_host(term()) -> {term(), term()}.
%% TODO:
%% Currently we only support
%% one host, so just return
%% that
next_host(State=#state{hosts=Hosts}) ->
    [Host] = Hosts,
    {Host, State#state{current_host = Host}}.

%% This is ripped from basho_bench_driver_http_raw.erl
connect(Host) ->
    case erlang:get({ibrowse_pid, Host}) of
        undefined ->
            {ok, Pid} = ibrowse_http_client:start(Host),
            erlang:put({ibrowse_pid, Host}, Pid),
            Pid;
        Pid ->
            case is_process_alive(Pid) of
                true ->
                    Pid;
                false ->
                    erlang:erase({ibrowse_pid, Host}),
                    connect(Host)
            end
    end.


%% This is ripped from basho_bench_driver_http_raw.erl
disconnect(Url) ->
    case erlang:get({ibrowse_pid, Url}) of
        undefined ->
            ok;
        OldPid ->
            catch(ibrowse_http_client:stop(OldPid))
    end,
    erlang:erase({ibrowse_pid, Url}),
    ok.

maybe_disconnect(Url) ->
    case erlang:get(disconnect_freq) of
        infinity -> ok;
        {ops, Count} -> should_disconnect_ops(Count,Url) andalso disconnect(Url);
        Seconds -> should_disconnect_secs(Seconds,Url) andalso disconnect(Url)
    end.

should_disconnect_ops(Count, _) when Count =< 0 ->
    false;
should_disconnect_ops(Count, _) when Count =:= 1 ->
    true;
should_disconnect_ops(Count, {Host, Port}) ->
    Key = {ops_since_disconnect, {Host, Port}},
    case erlang:get(Key) of
        undefined ->
            erlang:put(Key, 1),
            false;
        CountUntilLastOne when CountUntilLastOne =:= Count - 1 ->
            erlang:put(Key, 0),
            true;
        Incr ->
            erlang:put(Key, Incr + 1),
            false
    end.

should_disconnect_secs(Seconds, {Host, Port}) ->
    Key = {last_disconnect, {Host, Port}},
    case erlang:get(Key) of
        undefined ->
            erlang:put(Key, os:timestamp()),
            false;
        Time when is_tuple(Time) andalso size(Time) == 3 ->
            Diff = timer:now_diff(os:timestamp(), Time),
            if
                Diff >= Seconds * 1000000 ->
                    erlang:put(Key, os:timestamp()),
                    true;
                true -> false
            end
    end.

clear_disconnect_freq(ConnInfo) ->
    case erlang:get(disconnect_freq) of
        infinity -> ok;
        {ops, _Count} -> erlang:put({ops_since_disconnect, ConnInfo}, 0);
        _Seconds -> erlang:put({last_disconnect, ConnInfo}, os:timestamp())
    end.

send_request(Host, Url, Headers, Method, Body, Options) ->
    send_request(Host, Url, Headers, Method, Body, Options, 3).

send_request(_Host, _Url, _Headers, _Method, _Body, _Options, 0) ->
    {error, max_retries};
send_request(Host, Url, Headers0, Method, Body, Options, Count) ->
    case (catch initiate_request(Host, Url, Headers0, Method, Body, Options)) of
        {ok, Status, RespHeaders, RespBody} ->
            maybe_disconnect(Host),
            {ok, Status, RespHeaders, RespBody};

        Error ->
            clear_disconnect_freq(Host),
            disconnect(Host),
            case should_retry(Error) of
                true ->
                    send_request(Host, Url, Headers0, Method, Body, Options,
                                 Count-1);
                false ->
                    normalize_error(Method, Error)
            end
    end.

do_put(Host, Url, Headers, Value, State) ->
    case send_request(Host, Url, Headers ++ [{'Content-Type', 'application/octet-stream'}],
                      put, Value, proxy_opts(State)) of
        {ok, "200", _Header, _Body} ->
            ok;
        {ok, "201", _Header, _Body} ->
            ok;
        {ok, "204", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_delete(Host, Url, Headers, State) ->
    case send_request(Host, Url, Headers, delete, <<>>, proxy_opts(State)) of
        {ok, "200", _Header, _Body} ->
            ok;
        {ok, "204", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_copy(Host, Url, Headers, State) ->
    case send_request(Host, Url, Headers, put, <<>>, proxy_opts(State)) of
        {ok, "200", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_get_first_unit(Host, Url, Headers, State) ->
    BufSize = 128*1024,
    Opts = [{max_pipeline_size, 9999999},
            {socket_options, [{recbuf, BufSize}]},
            {stream_chunk_size, BufSize},
            {stream_to, {self(), once}},
            {response_format, binary},
            {connect_timeout, 300*1000},
            {inactivity_timeout, 300*1000}],
    case initiate_request(Host, Url, Headers, get, <<>>, Opts++proxy_opts(State)) of
        {ibrowse_req_id, ReqId} ->
            receive
                {ibrowse_async_headers, ReqId, HTTPCode, _}
                  when HTTPCode == "200"; HTTPCode == "404" ->
                    do_get_loop(State#state{req_id = ReqId});
                {ibrowse_async_headers, ReqId, HTTPCode, _} ->
                    {error, {http_error, HTTPCode},
                     State#state{working_op = undefined}}
                %% Shouldn't happen at this time?
                %% {ibrowse_async_response, ReqId, Bin} ->
                %%     size(B);
                %% Shouldn't happen at this time?
                %% {ibrowse_async_response_end, ReqId} ->
                %%     all_done
            after ?VERYLONG_TIMEOUT ->
                    {error, ibrowse_timed_out,
                     State#state{working_op = undefined}}
            end;
        Else ->
            {error, Else, State#state{working_op = undefined}}
    end.

do_get_loop(#state{req_id = ReqId} = State) ->
    ibrowse:stream_next(ReqId),
    do_get_loop(0, os:timestamp(), State).

do_get_loop(Sum, StartT,
            #state{req_id = ReqId, report_fun = ReportFun, current_host = Host} = State) ->
    receive
        {ibrowse_async_response, ReqId, Bin} ->
            ibrowse:stream_next(ReqId),
            NewSum = Sum + size(Bin),
            if NewSum > ?BLOCK ->
                    DiffT = timer:now_diff(os:timestamp(), StartT),
                    basho_bench_stats:op_complete(
                      {get,get}, {ok, ReportFun(NewSum)}, DiffT),
                    {ok, State#state{working_op = get}};
               true ->
                    do_get_loop(NewSum, StartT, State)
            end;
        {ibrowse_async_response_end, ReqId} ->
            maybe_disconnect(Host),
            DiffT = timer:now_diff(os:timestamp(), StartT),
            basho_bench_stats:op_complete(
              {get,get}, {ok, ReportFun(Sum)}, DiffT),
            {ok, State#state{working_op = undefined}}
    after ?VERYLONG_TIMEOUT ->
            {error, do_get_loop_timed_out, State#state{working_op = undefined}}
    end.

should_retry({error, send_failed})       -> true;
should_retry({error, connection_closed}) -> true;
should_retry({'EXIT', {normal, _}})      -> true;
should_retry({'EXIT', {noproc, _}})      -> true;
should_retry(_)                          -> false.

normalize_error(Method, {'EXIT', {timeout, _}})  -> {error, {Method, timeout}};
normalize_error(Method, {'EXIT', Reason})        -> {error, {Method, 'EXIT', Reason}};
normalize_error(Method, {error, Reason})         -> {error, {Method, Reason}}.

proxy_opts(State) ->
    [{response_format, binary},
     {proxy_host, State#state.http_proxy_host},
     {proxy_port, State#state.http_proxy_port}].

uppercase_verb(put) ->
    'PUT';
uppercase_verb(get) ->
    'GET';
uppercase_verb(delete) ->
    'DELETE';
uppercase_verb(post) ->
    'POST'.

to_list(A) when is_atom(A) ->
    atom_to_list(A);
to_list(L) when is_list(L) ->
    L.

initiate_request(Host, Url, Headers0, Method, Body, Options) ->
    Pid = connect(Host),
    ContentTypeStr = to_list(proplists:get_value(
                               'Content-Type', Headers0,
                               'application/octet-stream')),
    Date = httpd_util:rfc1123_date(),
    Uri = element(7, Url),
    Headers = [{'Content-Type', ContentTypeStr},
               {'Date', Date}|lists:keydelete('Content-Type', 1, Headers0)],
    HeadersWithAuth =
        case basho_bench_config:get(cs_access_key, undefined) of
            undefined ->
                Headers;
            AccessKey ->
                AuthSig = auth_sig(AccessKey, basho_bench_config:get(cs_secret_key),
                                   uppercase_verb(Method), ContentTypeStr, Date,
                                   Headers, Uri),
                [{'Authorization', AuthSig}|Headers]
        end,
    Timeout = basho_bench_config:get(cs_request_timeout, 5000),
    ibrowse_http_client:send_req(Pid, Url, HeadersWithAuth, Method,
                                 Body, Options, Timeout).

%% S3 utilities

auth_sig(AccessKey, SecretKey, Method, ContentType, Date, Headers, Resource) ->
    AmzHeaders = lists:filter(fun ({"x-amz-" ++ _, V}) when V =/= undefined -> true; (_) -> false end, Headers),
    CanonizedAmzHeaders =
        [[Name, $:, Value, $\n] || {Name, Value} <- lists:sort(AmzHeaders)],
    StringToSign = [string:to_upper(atom_to_list(Method)), $\n,
                    "", $\n,  % Content-MD5
                    ContentType, $\n,
                    Date, $\n,
                    CanonizedAmzHeaders,
                    Resource
                   ],
    Signature = base64:encode(sha_mac(SecretKey, StringToSign)),
    ["AWS ", AccessKey, $:, Signature].

%% CS utilities

%% @doc copied from stanchion_utils
sha_mac(KeyData, STS) ->
    crypto:hmac(sha, KeyData, STS).

setup_user_and_bucket(State) ->
    case basho_bench_config:get(cs_access_key, undefined) of
        undefined ->
            DisplayName = basho_bench_config:get(cs_display_name, "test-user"),
            ok = maybe_create_user(DisplayName, State),
            {ok, {_DisplayName, KeyId, KeySecret}} = fetch_user_info(DisplayName, State),
            logger:info("Target User: ~p", [{DisplayName, KeyId, KeySecret}]),
            ok = basho_bench_config:set(cs_access_key, KeyId),
            ok = basho_bench_config:set(cs_secret_key, KeySecret);
        _ ->
            ok
    end,
    ok = maybe_create_bucket(State#state.bucket, State).

maybe_create_user(DisplayName, #state{hosts=Hosts} = State) ->
    {Host, Port} = hd(Hosts),
    Json = io_lib:format("{\"email\": \"~s@example.com\", \"name\": \"~s\"}",
                         [DisplayName, DisplayName]),
    Url = url(Host, Port, "riak-cs", "user"),
    Headers = [{'Content-Type', 'application/json'}],
    case send_request({Host, Port}, Url, Headers, post, Json, proxy_opts(State)) of
        {ok, "201", _Header, Body} ->
            logger:debug("User created: ~p~n", [Body]),
            ok;
        {ok, "409", _Header, Body} ->
            logger:debug("User already exists: ~p~n", [Body]),
            ok;
        {ok, Code, Header, Body} ->
            {error, {user_creation, Code, Header, Body}};
        {error, Reason} ->
            {error, {user_creation, Reason}}
    end.

fetch_user_info(DisplayName, State) ->
    case list_users(State) of
        {ok, UserList} ->
            {ok, lists:keyfind(DisplayName, 1, UserList)};
        {error, Reason} ->
            {error, Reason}
    end.

list_users(#state{hosts=Hosts} = State) ->
    {Host, Port} = hd(Hosts),
    Url = url(Host, Port, "riak-cs", "users"),
    case send_request({Host, Port}, Url, [{'Accept', 'application/json'}], get,
                       [], proxy_opts(State)) of
        {ok, "200", _Headers, Body} ->
            {ok, parse_user_info(Body)};
        {error, Reason} ->
            {error, {list_users, Reason}}
    end.

parse_user_info(Output) ->
    [Boundary | Tokens] = string:tokens(binary_to_list(Output), "\r\n"),
    parse_user_info(Tokens, Boundary, []).

parse_user_info([_LastToken], _, Users) ->
    ordsets:from_list(Users);
parse_user_info(["Content-Type: application/json", RawJson | RestTokens],
                 Boundary, Users) ->
    UpdUsers = parse_user_records(RawJson, json) ++ Users,
    parse_user_info(RestTokens, Boundary, UpdUsers);
parse_user_info([_ | RestTokens], Boundary, Users) ->
    parse_user_info(RestTokens, Boundary, Users).

parse_user_records(Output, json) ->
    JsonData = mochijson2:decode(Output),
    [begin
         KeyId = binary_to_list(proplists:get_value(<<"key_id">>, UserJson)),
         KeySecret = binary_to_list(proplists:get_value(<<"key_secret">>, UserJson)),
         Name = binary_to_list(proplists:get_value(<<"name">>, UserJson)),
         {Name, KeyId, KeySecret}
     end || {struct, UserJson} <- JsonData].

maybe_create_bucket(Bucket, #state{hosts=Hosts} = State) ->
    {Host, Port} = hd(Hosts),
    Url = url(Host, Port, Bucket, undefined),
    case send_request({Host, Port}, Url, [], put, [], proxy_opts(State)) of
        {ok, "200", _Headers, _Body} ->
            logger:debug("Bucket created (maybe): ~p~n", [Bucket]),
            ok;
        {ok, Code, Header, Body} ->
            logger:error("Create bucket: ~p~n", [{Code, Header, Body}]),
            {error, {bucket_creation, Code, Header, Body}};
        {error, Reason} ->
            logger:error("Create bucket: ~p~n", [Reason]),
            {error, {bucket_creation, Reason}}
    end.
