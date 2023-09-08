%% @doc abstract API for HTTP client

-module(pe4kin_http).

-export([start_pool/0, stop_pool/0]).
-export([open/0, open/3, get/1, post/3]).
-export([json_encode/1, json_decode/1]).

-export_type([req_body/0]).

-type response() :: {non_neg_integer(), [{binary(), binary()}], iodata()}.
-type path() :: iodata().
-type req_headers() :: [{binary(), iodata()}].
-type disposition() ::
        {Disposition :: binary(), Params :: [{binary(), iodata()}]}.
-type multipart() ::
        [{file, file:name_all(), disposition(), req_headers()} |
         {Name :: binary(), Payload :: binary(), disposition(), req_headers()} |
         {Name :: binary(), Payload :: binary()}].
-type req_body() :: binary() |
                    iodata() |
                    {form, #{binary() => binary()}} |
                    {json, pe4kin:json_value()} |
                    {multipart, multipart()}.

open() ->
    {ok, Endpoint} = pe4kin:get_env(api_server_endpoint),
    {Transport, Host, Port} = parse_endpoint(Endpoint),
    open(Transport, Host, Port).

open(Transport, Host, Port) ->
    {ok, Pid} = gun:open(Host, Port, #{transport => Transport}),
    _Protocol = gun:await_up(Pid),
    {ok, Pid}.

-spec get(iodata()) -> response() | {error, any()}.
get(Path) ->
    {Opts, Host} = http_req_opts(),
    await(gun_pool:get(Path, #{<<"host">> => Host}, Opts)).

-spec post(path(), req_headers(), req_body()) -> response() | {error, any()}.
post(Path, Headers, Body) when is_binary(Body);
                               is_list(Body) ->
    {Opts, Host} = http_req_opts(),
    await(gun_pool:post(Path, [{<<"host">>, Host} | Headers], Body, Opts));
post(Path, Headers, {form, KV}) ->
    post(Path, Headers, cow_qs:qs(maps:to_list(KV)));
post(Path, Headers, {json, Struct}) ->
    post(Path, Headers, json_encode(Struct));
post(Path, Headers0, {multipart, Multipart}) ->
    Boundary = cow_multipart:boundary(),
    {value, {_, <<"multipart/form-data">>}, Headers1} =
        lists:keytake(<<"content-type">>, 1, Headers0),
    Headers = [{<<"content-type">>,
                [<<"multipart/form-data;boundary=">>, Boundary]}
              | Headers1],
    {Opts, Host} = http_req_opts(),
    {async, Ref} = gun_pool:post(Path, [{<<"host">>, Host} | Headers], Opts),
    multipart_stream(Ref, Boundary, Multipart),
    await(Ref).

http_req_opts() ->
    {ok, PoolOpts} = pe4kin:get_env(keepalive_pool),
    Opts = #{reply_to => self(),
             scope => ?MODULE,
             checkout_retry => maps:get(checkout_retry, PoolOpts, [])},
    {ok, Endpoint} = pe4kin:get_env(api_server_endpoint),
    {Transport, Host, Port} = parse_endpoint(Endpoint),
    {Opts, gun_http:host_header(Transport, Host, Port)}.

await({async, Ref}) ->
    await(Ref);
await(Ref) ->
    case gun_pool:await(Ref, 30_000) of
        {response, fin, Status, Headers} ->
            {Status, Headers, []};
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun_pool:await_body(Ref),
            {Status, Headers, Body};
        {error, _} = Err ->
            Err
    end.

multipart_stream(Ref, Boundary, Multipart) ->
    ok = lists:foreach(
          fun({file, Path, Disposition, Hdrs0}) ->
                  {ok, Bin} = file:read_file(Path),
                  Hdrs = [{<<"content-disposition">>, encode_disposition(Disposition)}
                         | Hdrs0],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun_pool:data(Ref, nofin, [Chunk, Bin]);
             ({_Name, Payload, Disposition, Hdrs0}) ->
                  Hdrs = [{<<"content-disposition">>, encode_disposition(Disposition)}
                         | Hdrs0],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun_pool:data(Ref, nofin, [Chunk, Payload]);
             ({Name, Value}) ->
                  Hdrs = [{<<"content-disposition">>,
                           encode_disposition({<<"form-data">>,
                                               [{<<"name">>, Name}]})}],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun_pool:data(Ref, nofin, [Chunk, Value])
          end, Multipart),
    Closing = cow_multipart:close(Boundary),
    ok = gun_pool:data(Ref, fin, Closing).

encode_disposition({Disposition, Params}) ->
    [Disposition
     | [[";", K, "=\"", V, "\""] || {K, V} <- Params]].

%% Pool

start_pool() ->
    {ok, Opts} = pe4kin:get_env(keepalive_pool),
    {ok, Endpoint} = pe4kin:get_env(api_server_endpoint),
    {Transport, Host, Port} = parse_endpoint(Endpoint),
    ConnOpts0 = case Transport of
                    tls ->
                        case pe4kin:get_env(http_tls_opts, []) of
                            [] -> #{};
                            TlsOpts -> #{tls_opts => TlsOpts}
                        end;
                    tcp ->
                        case pe4kin:get_env(http_tcp_opts, []) of
                            [] -> #{};
                            TcpOpts -> #{tcp_opts => TcpOpts}
                        end
                end,
    {ok, ManagerPid} = gun_pool:start_pool(Host, Port, #{
        conn_opts => ConnOpts0#{protocols => [http2],
                                transport => Transport},
        scope => ?MODULE,
        size => maps:get(max_count, Opts, 10)
	}),
	gun_pool:await_up(ManagerPid).

stop_pool() ->
    {ok, Endpoint} = pe4kin:get_env(api_server_endpoint),
    {Transport, Host, Port} = parse_endpoint(Endpoint),
    ok = gun_pool:stop_pool(Host, Port, #{transport => Transport,
                                          scope => ?MODULE}).

parse_endpoint(Uri) ->
    Parts = case Uri of
                <<"https://", Rest/binary>> ->
                    [tls | binary:split(Rest, <<":">>)];
                <<"http://", Rest/binary>> ->
                    [tcp | binary:split(Rest, <<":">>)]
            end,
    case Parts of
        [tls, Host] ->
            {tls, binary_to_list(Host), 443};
        [tcp, Host] ->
            {tcp, binary_to_list(Host), 80};
        [Transport, Host, Port] ->
            {Transport, binary_to_list(Host), binary_to_integer(Port)}
    end.

-dialyzer({nowarn_function, json_decode/1}).
-spec json_decode(binary()) -> pe4kin:json_value().
json_decode(Body) ->
    jiffy:decode(Body, [return_maps]).

-dialyzer({nowarn_function, json_encode/1}).
-spec json_encode(pe4kin:json_value()) -> binary().
json_encode(Struct) ->
    jiffy:encode(Struct).
