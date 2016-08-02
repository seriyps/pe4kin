pe4kin
=====

Erlang Telegram bot library.
Erlang wrapper for Telegram messenger bot APIs.

With pe4kin you can receive, send, reply and forward text, as well as media
messages using [telegram bot API](https://core.telegram.org/bots/api).

Pe4kin is the name of the [multiplicational postman](https://ru.wikipedia.org/wiki/%D0%9F%D0%BE%D1%87%D1%82%D0%B0%D0%BB%D1%8C%D0%BE%D0%BD_%D0%9F%D0%B5%D1%87%D0%BA%D0%B8%D0%BD).


Example
-------

```erlang
% $ rebar3 compile
% $ rebar3 shell

> application:ensure_all_started(pe4kin).

% First of all, you need to get bot's credentials.
% Consult telegram docs https://core.telegram.org/bots#6-botfather
> BotName = <<"Pe4kin_Test_Bot">>.
> BotToken = <<"186***:******">>.


%
% Receive messages from users
%

% Launch incoming messages receiver worker.
% XXX: In real applications you'll want to launch pe4kin_receiver gen_server
%      under supervisor!
> pe4kin:launch_bot(BotName, BotToken, #{receiver => true}).

% Subscribe self to incoming messages
> pe4kin_receiver:subscribe(BotName, self()).

% Start HTTP-polling of telegram server for incoming messages
> pe4kin_receiver:start_http_poll(BotName, #{limit=>100, timeout=>60}).

% Wait for new messages.
% ...here you should send "/start" to this bot via telegram client...
> Update = receive {pe4kin_update, BotName, Upd} -> Upd end.

% Guess incoming update payload type.
> message = pe4kin_types:update_type(Update).

% Note `ChatId` - it uniquely identifies this particular chat and will be used
% in replies.
> #{<<"message">> := #{<<"chat">> := #{<<"id">> := ChatId}} = Message} = Update.

% Guess message payload type
> text = pe4kin_types:message_type(Message).

% Decode "/start" command (will raise exception if no commands in message)
> {<<"/start">>, BotName, true, _} = pe4kin_types:message_command(BotName, Message).


%
% Send messages
%

% Check that bot configured properly
> {ok, #{<<"first_name">> := _, <<"id">> := _, <<"username">> := _}} = pe4kin:get_me(BotName).

% Send reply to previously received `Update` message (note `ChatId`)
> From = maps:get(<<"first_name">>, maps:get(<<"from">>, Message, #{}), <<"Anonumous">>).
> HeartEmoji = pe4kin_emoji:name_to_char('heart').
> ResponseText = unicode:characters_to_binary([<<"Hello, ">>, From, HeartEmoji]).
> {ok, _} = pe4kin:send_message(BotName, #{chat_id => ChatId, text => ResponseText}).

% Send image to the same chat
> CatImgFileName = "funny_cat.jpg".
> {ok, CatImgBin} = file:read_file(CatImgFileName).
> Photo = {file, CatImgFileName, <<"image/jpeg">>, CatImgBin}.
> {ok, _} = pe4kin:send_photo(BotName, #{chat_id => ChatId, photo => Photo}).
```
