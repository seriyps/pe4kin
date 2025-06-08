%% @doc mock server for telegram long-poll API
-module(mock_longpoll_server).

-export([start/1, stop/1]).
-export([add_updates/2]).

-behaviour(cowboy_handler).
-export([init/2]).

-type update() :: map().

-record(st,
        {cowboy,
         state :: pid()}).

start(Opts0) ->
    application:ensure_all_started(cowboy),
    StatePid = proc_lib:spawn_link(fun state_enter/0),
    Defaults = #{port => 1080,
                 token => <<"1234:my-token">>,
                 state_pid => StatePid,
                 api_handler => fun default_api_handler/4},
    Opts = maps:merge(Defaults, Opts0),
    Routes =
        [{'_',
          [{"/:token/:method", ?MODULE, Opts}
          ]}],
    Dispatch = cowboy_router:compile(Routes),
    {ok, _} = cowboy:start_clear(
                ?MODULE,
                #{max_connections => 64,
                  socket_opts => [{port, maps:get(port, Opts)}]},
                #{env => #{dispatch => Dispatch}}),
    Host = iolist_to_binary(io_lib:format("http://localhost:~w",
                                          [maps:get(port, Opts)])),
    ok = application:set_env(pe4kin, api_server_endpoint, Host),
    #st{cowboy = ?MODULE,
        state = StatePid}.

stop(#st{cowboy = ?MODULE,
         state = StatePid}) ->
    unlink(StatePid),
    exit(StatePid, shutdown),
    cowboy:stop_listener(?MODULE).

-spec add_updates([update()], #st{}) -> ok.
add_updates(Updates, #st{state = StatePid}) ->
    StatePid ! {add, Updates},
    ok.

subscribe(Pid, Offset, Timeout) ->
    %% There is a race-condition here when Timeout is too short
    Pid ! {subscribe, self(), Offset},
    receive
        {updates, Updates} ->
            Updates
    after Timeout ->
            Pid ! {unsubscribe, self()},
            []
    end.

state_enter() ->
    Updates = [],
    Subscribers = [],
    state_loop(Updates, 0, Subscribers).

state_loop(Updates, Offset, Subscribers) ->
    ct:pal("~p(~p, ~p, ~p)", [?FUNCTION_NAME, Updates, Offset, Subscribers]),
    receive
        {add, NewUpdates} ->
            NUpdates = length(NewUpdates),
            Offsets = lists:seq(Offset, Offset + NUpdates - 1),
            UpdatesWithOffsets = lists:zip(Offsets, NewUpdates),
            Updates1 = lists:sort(UpdatesWithOffsets ++ Updates),
            state_loop(Updates1, Offset + NUpdates,
                       state_invariant(Updates1, Subscribers));
        {subscribe, Pid, After} ->
            Subscribers1 = [{Pid, After} | Subscribers],
            state_loop(Updates, Offset, state_invariant(Updates, Subscribers1));
        {unsubscribe, Pid} ->
            state_loop(Updates, Offset, [Sub || {SubPid, _} = Sub <- Subscribers,
                                                SubPid =/= Pid])
    end.

state_invariant(Updates, [{Pid, After} = Sub | Subscribers]) ->
    ToNotify = [Upd || {At, _} = Upd <- Updates, At >= After],
    case ToNotify of
        [] ->
            [Sub | state_invariant(Updates, Subscribers)];
        _ ->
            Pid ! {updates, ToNotify},
            state_invariant(Updates, Subscribers)
    end;
state_invariant(_, []) -> [].


init(Req0, #{token := Token} = Opts) ->
    %% Method = cowboy_req:method(Req0),
    %% Path = cowboy_req:path(Req0),
    QS = maps:from_list(cowboy_req:parse_qs(Req0)),
    <<"bot", ReqToken/binary>> = cowboy_req:binding(token, Req0),
    ApiMethod = cowboy_req:binding(method, Req0),
    case Token == ReqToken of
        true ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            {Code, Response} = handle_api_call(ApiMethod, QS, Body, Opts),
            reply(Code, Response, Req1);
        false ->
            reply(401, <<"Unauthorized">>, Req0)
    end.

reply(Code, Response, Req) when Code < 300, Code >= 200 ->
    Body = pe4kin_http:json_encode(#{ok => true,
                          result => Response}),
    Req1 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req1, []};
reply(Code, Response, Req) ->
    Body = pe4kin_http:json_encode(#{ok => false,
                          error_code => Code,
                          description => Response}),
    Req1 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req1, []}.

handle_api_call(<<"getUpdates">>, QS, <<>>, #{state_pid := Pid}) ->
    Defaults = #{<<"offset">> => <<"0">>,
                 <<"timeout">> => <<"10">>},
    #{<<"offset">> := OffsetBin,
      <<"timeout">> := TimeoutBin} = maps:merge(Defaults, QS),
    Offset = binary_to_integer(OffsetBin),
    Timeout = binary_to_integer(TimeoutBin) * 1000,
    Changes = subscribe(Pid, Offset, Timeout),  %Will block
    {200, lists:map(fun({UpdOffset, Upd}) ->
                            Upd#{update_id => UpdOffset}
                    end, Changes)};
handle_api_call(Method, QS, Body, #{api_handler := Handler} = Opts) ->
    Handler(Method, QS, Body, Opts).

default_api_handler(Method, QS, Body, _) ->
    {200, #{method => Method,
            query => QS,
            body => Body}}.
