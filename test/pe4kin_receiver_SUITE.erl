%% @doc Basic tests with long pooling
-module(pe4kin_receiver_SUITE).

-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([basic_update_case/1,
         basic_2_updates_case/1,
         basic_3_separate_updates_case/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-define(APP, temp_email).


all() ->
    %% All exported functions of arity 1 whose name ends with "_case"
    [{group, all}].

groups() ->
    Exports = ?MODULE:module_info(exports),
    Cases = [F
             || {F, A} <- Exports,
                A == 1,
                case lists:reverse(atom_to_list(F)) of
                    "esac_" ++ _ -> true;
                    _ -> false
                end],
    [{all, Cases}].


init_per_suite(Cfg) ->
    {ok, _} = application:ensure_all_started(pe4kin),
    Cfg.

end_per_suite(Cfg) ->
    ok = application:stop(pe4kin),
    Cfg.


init_per_testcase(Name, Cfg) ->
    Env = application:get_all_env(pe4kin),
    Tok = <<"my-token">>,
    Srv = mock_longpoll_server:start(#{token => Tok}),
    [{pre_env, Env} | ?MODULE:Name({pre, [{server, Srv}, {token, Tok} | Cfg]})].

end_per_testcase(Name, Cfg) ->
    Env = ?config(pre_env, Cfg),
    Srv = ?config(server, Cfg),
    ?MODULE:Name({post, Cfg}),
    ok = mock_longpoll_server:stop(Srv),
    ok = application:set_env([{pe4kin, Env}]),
    Cfg.


%% @doc Test single update
basic_update_case({pre, Cfg}) ->
    Name = <<"my-bot">>,
    Tok = ?config(token, Cfg),
    {ok, Pid} = pe4kin_receiver:start_link(Name, Tok, #{}),
    [{name, Name}, {recv_pid, Pid} | Cfg];
basic_update_case({post, Cfg}) ->
    RecvPid = ?config(recv_pid, Cfg),
    unlink(RecvPid),
    exit(RecvPid, shutdown),
    Cfg;
basic_update_case(Cfg) when is_list(Cfg) ->
    Srv = ?config(server, Cfg),
    Name = ?config(name, Cfg),
    ok = pe4kin_receiver:subscribe(Name, self()),
    ok = pe4kin_receiver:start_http_poll(Name, #{}),
    ok = mock_longpoll_server:add_updates([#{<<"message">> => #{}}], Srv),
    ?assertEqual([#{<<"message">> => #{},
                    <<"update_id">> => 0}], recv(Name, 1)),
    ?assertEqual([], flush(Name)).

%% @doc Test 2 updates at once
basic_2_updates_case({pre, Cfg}) ->
    Name = <<"my-bot">>,
    Tok = ?config(token, Cfg),
    {ok, Pid} = pe4kin_receiver:start_link(Name, Tok, #{}),
    [{name, Name}, {recv_pid, Pid} | Cfg];
basic_2_updates_case({post, Cfg}) ->
    RecvPid = ?config(recv_pid, Cfg),
    unlink(RecvPid),
    exit(RecvPid, shutdown),
    Cfg;
basic_2_updates_case(Cfg) when is_list(Cfg) ->
    Srv = ?config(server, Cfg),
    Name = ?config(name, Cfg),
    ok = pe4kin_receiver:subscribe(Name, self()),
    ok = pe4kin_receiver:start_http_poll(Name, #{}),
    ok = mock_longpoll_server:add_updates(
           [#{<<"message">> => #{<<"text">> => <<"msg1">>}},
            #{<<"message">> => #{<<"text">> => <<"msg2">>}}], Srv),
    ?assertEqual([#{<<"message">> => #{<<"text">> => <<"msg1">>},
                   <<"update_id">> => 0},
                  #{<<"message">> => #{<<"text">> => <<"msg2">>},
                   <<"update_id">> => 1}], recv(Name, 2)),
    ?assertEqual([], flush(Name)).

%% @doc Test 3 updates at once
basic_3_separate_updates_case({pre, Cfg}) ->
    Name = <<"my-bot">>,
    Tok = ?config(token, Cfg),
    {ok, Pid} = pe4kin_receiver:start_link(Name, Tok, #{}),
    [{name, Name}, {recv_pid, Pid} | Cfg];
basic_3_separate_updates_case({post, Cfg}) ->
    RecvPid = ?config(recv_pid, Cfg),
    unlink(RecvPid),
    exit(RecvPid, shutdown),
    Cfg;
basic_3_separate_updates_case(Cfg) when is_list(Cfg) ->
    Srv = ?config(server, Cfg),
    Name = ?config(name, Cfg),
    ok = pe4kin_receiver:subscribe(Name, self()),
    ok = pe4kin_receiver:start_http_poll(Name, #{}),
    lists:foreach(
      fun(I) ->
              Text = <<"msg", (integer_to_binary(I))/binary>>,
              ok = mock_longpoll_server:add_updates(
                     [#{<<"message">> => #{<<"text">> => Text}}], Srv),
              ?assertEqual([#{<<"message">> => #{<<"text">> => Text},
                              <<"update_id">> => I}], recv(Name, 1)),
              ?assertEqual([], flush(Name))
      end, lists:seq(0, 2)).

flush(Bot) ->
    recv(Bot, 5, 0).

recv(Bot, N) ->
    recv(Bot, N, 5000).

recv(_, 0, _) ->
    [];
recv(Bot, N, Timeout) ->
    receive
        {pe4kin_update, Bot, Update} ->
            [Update | recv(Bot, N - 1, Timeout)]
    after Timeout ->
            []
    end.
