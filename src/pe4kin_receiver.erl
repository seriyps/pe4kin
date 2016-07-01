%%%-------------------------------------------------------------------
%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% @copyright (C) 2016, Sergey Prokhorov
%%% @doc
%%% Telegram bot update pooler.
%%% Receive incoming messages (updates) via webhook or http longpolling.
%%% @end
%%% Created : 18 May 2016 by Sergey Prokhorov <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(pe4kin_receiver).

-behaviour(gen_server).

%% API
-export([start_link/3]).
-export([start_http_poll/2, stop_http_poll/1,
         start_set_webhook/3, stop_set_webhook/1]).
-export([webhook_callback/3]).
-export([subscribe/2, unsubscribe/2, get_updates/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type longpoll_state() :: #{ref => hackney:client_ref(),
                            state => start | status | headers | body,
                            status => pos_integer(),
                            headers => [{binary(), binary()}],
                            body => iodata()}.
-type longpoll_opts() :: #{limit => 1..100,
                           timeout => non_neg_integer()}.

-record(state,
        {
          name :: pe4kin:bot_name(),
          token :: binary(),
          buffer_edge_size :: non_neg_integer(),
          method :: webhook | longpoll,
          method_opts :: longpoll_opts(),
          method_state :: longpoll_state(),
          active :: boolean(),
          last_update_id :: integer(),
          subscribers :: ordsets:ordset(pid()),
          ulen :: non_neg_integer(),
          updates :: queue:queue()
        }).


-spec start_http_poll(pe4kin:bot_name(),
                        #{offset => integer(),
                          limit => 1..100,
                          timeout => non_neg_integer()}) -> ok.
start_http_poll(Bot, Opts) ->
    gen_server:call(?MODULE, {start_http_poll, Bot, Opts}).

-spec stop_http_poll(pe4kin:bot_name()) -> ok.
stop_http_poll(Bot) ->
    gen_server:call(?MODULE, {stop_http_poll, Bot}).

-spec start_set_webhook(pe4kin:bot_name(),
                        binary(),
                        #{certfile_id => integer()}) -> ok.
start_set_webhook(Bot, UrlPrefix, Opts) ->
    gen_server:call(?MODULE, {start_set_webhook, Bot, UrlPrefix, Opts}).

-spec stop_set_webhook(pe4kin:bot_name()) -> ok.
stop_set_webhook(Bot) ->
    gen_server:call(?MODULE, {stop_set_webhook, Bot}).

-spec webhook_callback(binary(), #{binary() => binary()}, binary()) -> ok.
webhook_callback(Path, Query, Body) ->
    gen_server:call(?MODULE, {webhook_callback, Path, Query, Body}).


-spec subscribe(pe4kin:bot_name(), pid()) -> ok.
subscribe(Bot, Pid) ->
    gen_server:call(?MODULE, {subscribe, Bot, Pid}).

-spec unsubscribe(pe4kin:bot_name(), pid()) -> ok | not_found.
unsubscribe(Bot, Pid) ->
    gen_server:call(?MODULE, {unsubscribe, Bot, Pid}).

%% @doc Return not more than 'Limit' updates. May return empty list.
-spec get_updates(pe4kin:bot_name(), pos_integer()) -> [pe4kin:update()].
get_updates(Bot, Limit) ->
    gen_server:call(?MODULE, {get_updates, Bot, Limit}).


start_link(Bot, Token, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Bot, Token, Opts], []).


init([Bot, Token, Opts]) ->
    {ok, #state{name = Bot,
                token = Token,
                active = false,
                subscribers = ordsets:new(),
                ulen = 0,
                updates = queue:new(),
                buffer_edge_size = maps:get(buffer_edge_size, Opts, 1000)}}.

handle_call({start_http_poll, _, Opts}, _From, #state{method = undefined, active = false} = State) ->
    State1 = do_start_http_poll(Opts, State),
    MOpts = maps:remove(offset, Opts),
    {reply, ok, State1#state{method_opts = MOpts, method = longpoll}};
handle_call({stop_http_poll, _}, _From, #state{method = longpoll, active = Active} = State) ->
    State1 = case Active of
                 true -> do_stop_http_poll(State);
                 false -> State
             end,
    {reply, ok, State1#state{method = undefined}};
handle_call(webhook___TODO, _From, State) ->
    Reply = ok,
    {reply, Reply, State};
handle_call({subscribe, _, Pid}, _From, #state{subscribers=Subs} = State) ->
    Subs1 = ordsets:add_element(Pid, Subs),
    {reply, ok, invariant(State#state{subscribers=Subs1})};
handle_call({unsubscribe, _, Pid}, _From, #state{subscribers=Subs} = State) ->
    Subs1 = ordsets:del_element(Pid, Subs),
    {reply, ok, State#state{subscribers=Subs1}};
handle_call({get_updates, _, Limit}, _From, #state{buffer_edge_size=BESize, subscribers=[]} = State) ->
    (BESize >= Limit) orelse error_logger:warning_msg(
                               "get_updates limit ~p is greater than buffer_edge_size ~p",
                               [Limit, BESize]),
    {Reply, State1} = pull_updates(Limit, State),
    {reply, Reply, invariant(State1)};
handle_call(_Request, _From, #state{method=Method, subscribers=Subs, ulen=ULen, active=Active}=State) ->
    {reply, {error, bad_request, #{method => Method,
                                   n_subscribers => length(Subs),
                                   ulen => ULen,
                                   active => Active}}, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({hackney_response, Ref, Msg}, #state{method_state=#{ref := Ref}} = State) ->
    case handle_http_poll_msg(Msg, State) of
        {ok, State1} ->
            {noreply, State1};
        {invariant, State1} ->
            {noreply, invariant(State1)}
    end;
handle_info({hackney_response, Ref, Msg}, #state{method_state=MState} = State) ->
    error_logger:warning_msg("Unexpected hackney msg ~p, ~p; state ~p",
                             [Ref, Msg, MState]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%
%%% Internal functions
%%%
activate_get_updates(#state{method=webhook, active=false} = State) ->
    State#state{active=true};
activate_get_updates(#state{method=longpoll, method_state=undefined, active=false,
                            method_opts=MOpts, last_update_id=LastUpdId} = State) ->
    MOpts1 = case LastUpdId of
                 undefined -> MOpts;
                 _ -> MOpts#{offset => LastUpdId + 1}
             end,
    do_start_http_poll(MOpts1, State).

pause_get_updates(#state{method=longpoll, active=true} = State) ->
    do_stop_http_poll(State);
pause_get_updates(#state{method=webhook, active=true} = State) ->
    State#state{active=false}.


do_start_http_poll(Opts, #state{token=Token, active=false} = State) ->
    Opts1 = #{timeout := Timeout} = maps:merge(#{timeout => 30}, Opts),
    QS = hackney_url:qs([{atom_to_binary(Key, utf8), integer_to_binary(Val)}
                         || {Key, Val} <- maps:to_list(Opts1)]),
    Endpoint = application:get_env(pe4kin, api_server_endpoint, <<"https://api.telegram.org">>),
    Url = <<Endpoint/binary, "/bot", Token/binary, "/getUpdates?", QS/binary>>,
    case hackney:request(<<"GET">>, Url, [], <<>>,
                         [async, {recv_timeout, (Timeout + 5) * 1000}]) of
        {ok, Ref} ->
            State#state{%% method = longpoll,
              active = true,
              method_state = #{ref => Ref,
                               state => start,
                               status => undefined,
                               headers => undefined,
                               body => undefined}};
        {error, Reason} ->
            error_logger:warning_msg("Long polling HTTP error: ~p", [Reason]),
            timer:sleep(1000),
            do_start_http_poll(Opts, State)
    end.

do_stop_http_poll(#state{active=true, method=longpoll,
                         method_state=#{ref := Ref}} = State) ->
    {ok, _} = hackney:cancel_request(Ref),
    State#state{active=false, method_state=undefined}.


handle_http_poll_msg({status, Status, _Reason},
                     #state{method_state = #{state := start,
                                             status := undefined}=MState} = State) ->
    %% XXX: maybe assert Status == 200?
    {ok, State#state{method_state = MState#{state := status, status := Status}}};
handle_http_poll_msg({headers, Headers},
                     #state{method_state = #{state := status,
                                             headers := undefined}=MState} = State) ->
    {ok, State#state{method_state = MState#{state := headers, headers := Headers}}};
handle_http_poll_msg(done, #state{method_state = #{state := body,
                                                   body := Body}} = State) ->
    State1 = push_updates(Body, State#state{method_state=undefined, active=false}),
    {invariant, State1};
handle_http_poll_msg(done, #state{method_state = #{state := _,
                                                   body := undefined}} = State) ->
    {invariant, State};
handle_http_poll_msg({error, Reason}, #state{method_state = MState, name=Name} = State) ->
    error_logger:error_msg("Bot ~p: hackney longpoll error ~p when state ~p",
                           [Name, Reason, MState]),
    {invariant, State#state{method_state=undefined, active=false}};
handle_http_poll_msg(Chunk, #state{method_state = #{state := headers,
                                                    body := undefined}=MState} = State) ->
    {ok, State#state{method_state = MState#{state := body, body := Chunk}}};
handle_http_poll_msg(Chunk, #state{method_state = #{state := body,
                                                    body := Body}=MState} = State) ->
    {ok, State#state{method_state = MState#{body := [Body | Chunk]}}}.


push_updates(<<>>, State) -> State;
push_updates(UpdatesBin, #state{last_update_id = LastID, updates = UpdatesQ, ulen = ULen} = State) ->
    case jiffy:decode(UpdatesBin, [return_maps]) of
        [] -> State;
        #{<<"ok">> := true, <<"result">> := []} -> State;
        #{<<"ok">> := true, <<"result">> := NewUpdates} ->
            #{<<"update_id">> := NewLastID} = lists:last(NewUpdates),
            ((LastID == undefined) or (NewLastID > LastID))
                orelse error({assertion_failed, "NewLastID>LastID", NewLastID, LastID}),
            NewUpdatesQ = queue:from_list(NewUpdates),
            UpdatesQ1 = queue:join(UpdatesQ, NewUpdatesQ),
            State#state{last_update_id = NewLastID, updates = UpdatesQ1,
                        ulen = ULen + length(NewUpdates)}
    end.

pull_updates(_, #state{ulen = 0} = State) -> {[], State};
pull_updates(1, #state{updates = UpdatesQ, ulen = ULen} = State) ->
    {{value, Update}, UpdatesQ1} = queue:out(UpdatesQ),
    {[Update], State#state{updates = UpdatesQ1, ulen = ULen - 1}};
pull_updates(N, #state{updates = UpdatesQ, ulen = ULen} = State) ->
    PopN = erlang:min(N, ULen),
    {RetQ, UpdatesQ1} = queue:split(PopN, UpdatesQ),
    {queue:to_list(RetQ), State#state{updates = UpdatesQ1, ulen = ULen - PopN}}.


invariant(
  #state{method = Method,
         active = false,
         ulen = ULen,
         buffer_edge_size = BEdge} = State) when (ULen < BEdge)
                                                 and (Method =/= undefined)->
    invariant(activate_get_updates(State));
invariant(
  #state{subscribers = [_|_] = Subscribers,
         ulen = ULen,
         updates = Updates,
         name = Name} = State) when ULen > 0 ->
    [Subscriber ! {pe4kin_update, Name,  Update}
     || Subscriber <- Subscribers,
        Update <- queue:to_list(Updates)],
    invariant(State#state{ulen = 0, updates = queue:new()});
invariant(
  #state{method = Method,
         active = true,
         ulen = ULen,
         buffer_edge_size = BEdge} = State) when (ULen > BEdge)
                                                 and (Method =/= undefined) ->
    invariant(pause_get_updates(State));
invariant(State) -> State.

