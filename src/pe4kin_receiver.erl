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

-include_lib("kernel/include/logger.hrl").

-type longpoll_state() :: #{pid => pid(),
                            ref => reference(),
                            state => start | status | headers | body | undefined,
                            status => pos_integer() | undefined,
                            headers => [{binary(), binary()}] | undefined,
                            body => iodata() | undefined}.
-type longpoll_opts() :: #{limit => 1..100,
                           timeout => non_neg_integer()}.

-record(state,
        {
          name :: pe4kin:bot_name(),
          token :: binary(),
          buffer_edge_size :: non_neg_integer(),
          method :: webhook | longpoll | undefined,
          method_opts :: longpoll_opts() | undefined,
          method_state :: longpoll_state() | undefined,
          active :: boolean(),
          last_update_id :: integer() | undefined,
          subscribers :: #{pid() => reference()},
          monitors :: #{reference() => pid()},
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


-spec subscribe(pe4kin:bot_name(), pid()) -> ok | {error, process_already_subscribed}.
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
                subscribers = #{},
                monitors = #{},
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
handle_call({subscribe, _, Pid}, _From, #state{subscribers=Subs, monitors = Mons} = State) ->
    case maps:is_key(Pid, Subs) of
        false ->
            Ref = erlang:monitor(process, Pid),
            Subs1 = Subs#{Pid => Ref},
            Mons1 = Mons#{Ref => Pid},
            {reply, ok, invariant(State#state{subscribers=Subs1, monitors = Mons1})};
        true ->
            {reply, {error, process_already_subscribed}, State}
    end;
handle_call({unsubscribe, _, Pid}, _From, #state{subscribers=Subs, monitors = Mons} = State) ->
    {Mon, Subs1} = maps:take(Pid, Subs),
    erlang:demonitor(Mon, [flush]),
    {reply, ok,
     State#state{subscribers = Subs1,
                 monitors = maps:remove(Mon, Mons)}};
handle_call({get_updates, _, Limit}, _From, #state{buffer_edge_size=BESize, subscribers=Subs} = State)
  when map_size(Subs) == 0 ->
    (BESize >= Limit) orelse
        ?LOG_WARNING("get_updates limit ~p is greater than buffer_edge_size ~p",
                     [Limit, BESize],
                     #{domain => [pe4kin]}),
    {Reply, State1} = pull_updates(Limit, State),
    {reply, Reply, invariant(State1)};
handle_call(_Request, _From, #state{method=Method, subscribers=Subs, ulen=ULen, active=Active}=State) ->
    {reply, {error, bad_request, #{method => Method,
                                   n_subscribers => map_size(Subs),
                                   ulen => ULen,
                                   active => Active}}, State}.
handle_cast(Msg, State) ->
    ?LOG_WARNING("Unexpected cast ~p; state ~p", [Msg, State], #{domain => [pe4kin]}),
    {noreply, State}.

handle_info({gun_response, Pid, Ref, IsFin, Status, Headers}, #state{method_state=#{ref := Ref}} = State) ->
    WithBody =
        case IsFin of
            fin ->
                {Status, Headers, <<>>};
            nofin ->
                {ok, Body} = gun:await_body(Pid, Ref),
                {Status, Headers, Body};
            {error, _} = Err ->
                Err
        end,
    State1 = handle_http_poll_msg(WithBody, State),
    {noreply, invariant(State1)};
handle_info({gun_response, Ref, Msg}, #state{method_state=MState, name = Name} = State) ->
    ?LOG_WARNING("Unexpected http msg ~p, ~p; state ~p", [Ref, Msg, MState],
                 #{domain => [pe4kin], bot => Name}),
    {noreply, State};
handle_info({gun_error, Pid, Ref, Reason}, #state{method_state=#{ref := Ref, pid := Pid}} = State) ->
    State1 = handle_http_poll_msg({error, Reason}, State),
    {noreply, invariant(State1)};
handle_info({gun_error, Pid, Reason}, #state{method_state=#{pid := Pid}} = State) ->
    State1 = handle_http_poll_msg({error, Reason}, State),
    {noreply, invariant(State1)};
handle_info({'DOWN', Ref, process, Pid, _Reason}, #state{subscribers=Subs, monitors = Mons} = State) ->
    {noreply,
     State#state{subscribers = maps:remove(Pid, Subs),
                 monitors = maps:remove(Ref, Mons)}};
handle_info(Info, #state{name = Name} = State) ->
    ?LOG_WARNING("Unexpected info msg ~p; state ~p", [Info, State],
                 #{domain => [pe4kin],
                   bot => Name}),
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
activate_get_updates(#state{method=longpoll, active=false,
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


do_start_http_poll(Opts, #state{token=Token, active=false, method_state = #{pid := Pid}} = State) ->
    Opts1 = maps:merge(#{timeout => 30}, Opts),
    QS = cow_qs:qs([{atom_to_binary(Key, utf8), integer_to_binary(Val)}
                    || {Key, Val} <- maps:to_list(Opts1)]),
    Url = <<"/bot", Token/binary, "/getUpdates?", QS/binary>>,
    Ref = gun:get(Pid, Url),
    ?LOG_DEBUG("Long poll ~s", [Url], #{domain => [pe4kin]}),
    State#state{%% method = longpoll,
      active = true,
      method_state = #{pid => Pid,
                       ref => Ref,
                       state => start}};
do_start_http_poll(Opts, #state{active=false, method_state = undefined} = State) ->
    {ok, Pid} = pe4kin_http:open(),
    do_start_http_poll(Opts, State#state{method_state = #{pid => Pid}}).

do_stop_http_poll(#state{active=true, method=longpoll,
                         method_state=#{ref := Ref, pid := Pid}} = State) ->
    ok = gun:cancel(Pid, Ref),
    ok = gun:close(Pid),
    State#state{active=false, method_state=undefined}.


handle_http_poll_msg({200, _Headers, Body},
                     #state{method_state = #{pid := Pid}} = State) ->
    push_updates(Body, State#state{method_state=#{pid => Pid}, active=false});
handle_http_poll_msg({Status, _, _},
                     #state{method_state = #{pid := Pid} = MState, name = Name} = State) ->
    gun:close(Pid),
    ?LOG_WARNING("Bot ~p: longpool bad status ~p when state ~p", [Name, Status, MState],
                 #{domain => [pe4kin],
                   bot => Name}),
    State#state{method_state = undefined, active=false};
handle_http_poll_msg({error, Reason}, #state{method_state = #{pid := Pid} = MState, name=Name} = State) ->
    gun:close(Pid),
    ?LOG_WARNING("Bot ~p: http longpoll error ~p when state ~p", [Name, Reason, MState],
                 #{domain => [pe4kin],
                   bot => Name}),
    State#state{method_state=undefined, active=false}.


push_updates(<<>>, State) -> State;
push_updates(UpdatesBin, #state{last_update_id = LastID, updates = UpdatesQ, ulen = ULen} = State) ->
    case pe4kin_http:json_decode(UpdatesBin) of
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
  #state{subscribers = Subscribers,
         ulen = ULen,
         updates = Updates,
         name = Name} = State) when ULen > 0, map_size(Subscribers) > 0 ->
    [Subscriber ! {pe4kin_update, Name,  Update}
     || Subscriber <- maps:keys(Subscribers),
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
