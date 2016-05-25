%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% @copyright (C) 2016, Sergey Prokhorov
%%% @doc
%%% Helpers to work with telegram data types.
%%% @end
%%% Created : 24 May 2016 by Sergey Prokhorov <me@seriyps.ru>

-module(pe4kin_types).

-export([message_type/1, message_command/2]).

-export([command_get_args/3]).


%% @doc Returns only 1st command
-spec message_command(perkin:bot_name(), pe4kin:json_object()) ->
                             {Cmd :: binary(),
                              BotName :: binary(),
                              SentToMe :: boolean(),
                              Command :: pe4kin:json_object()}.
message_command(BotName, #{<<"text">> := Text,
                           <<"entities">> := Entities}) ->
    #{<<"offset">> := Offset,
      <<"length">> := Length} = Command = hd(entities_filter_type(<<"bot_command">>, Entities)),
    BinBotName = pe4kin_util:to_binary(BotName),
    Cmd = pe4kin_util:to_lower(pe4kin_util:slice(Text, Offset, Length)),
    case binary:split(Cmd, <<"@">>) of
        [Cmd1, BinBotName] -> {Cmd1, BinBotName, true, Command};      % /cmd@this_bot
        [Cmd1, OtherBotName] -> {Cmd1, OtherBotName, false, Command}; % /cmd@other_bot
        [Cmd] -> {Cmd, BinBotName, true, Command}                     % /cmd
    end.

%% @doc Detect message type
message_type(#{<<"message_id">> := _, <<"text">> := _}) -> text;
message_type(#{<<"message_id">> := _, <<"audio">> := _}) -> audio;
message_type(#{<<"message_id">> := _, <<"document">> := _}) -> document;
message_type(#{<<"message_id">> := _, <<"photo">> := _}) -> photo;
message_type(#{<<"message_id">> := _, <<"sticker">> := _}) -> sticker;
message_type(#{<<"message_id">> := _, <<"video">> := _}) -> video;
message_type(#{<<"message_id">> := _, <<"voice">> := _}) -> voice;
message_type(#{<<"message_id">> := _, <<"caption">> := _}) -> caption;
message_type(#{<<"message_id">> := _, <<"contact">> := _}) -> contact;
message_type(#{<<"message_id">> := _, <<"location">> := _}) -> location;
message_type(#{<<"message_id">> := _, <<"venue">> := _}) -> venue;
message_type(#{<<"message_id">> := _, <<"new_chat_member">> := _}) -> new_chat_member;
message_type(#{<<"message_id">> := _, <<"left_chat_member">> := _}) -> left_chat_member;
message_type(#{<<"message_id">> := _, <<"new_chat_title">> := _}) -> new_chat_title;
message_type(#{<<"message_id">> := _, <<"new_chat_photo">> := _}) -> new_chat_photo;
message_type(#{<<"message_id">> := _, <<"delete_chat_photo">> := _}) -> delete_chat_photo;
message_type(#{<<"message_id">> := _, <<"group_chat_created">> := _}) -> group_chat_created;
message_type(#{<<"message_id">> := _, <<"supergroup_chat_created">> := _}) -> supergroup_chat_created;
message_type(#{<<"message_id">> := _, <<"channel_chat_created">> := _}) -> channel_chat_created;
message_type(#{<<"message_id">> := _, <<"migrate_to_chat_id">> := _}) -> migrate_to_chat_id;
message_type(#{<<"message_id">> := _, <<"migrate_from_chat_id">> := _}) -> migrate_from_chat_id;
message_type(#{<<"message_id">> := _, <<"pinned_message">> := _}) -> pinned_message;
message_type(#{<<"message_id">> := _}) -> undefined.


entities_filter_type(Type, Entities) ->
    lists:filter(fun(#{<<"type">> := T}) -> T == Type end, Entities).


%% @doc Parses not more than `NArgs' command arguments.
%% If `NArgs' is '*', parses all arguments (until meet the end of the message or new line).
-spec command_get_args(non_neg_integer() | '*', Command :: pe4kin:json_object(), Message :: pe4kin:json_object()) ->
                              [binary()].
command_get_args(NArgs, #{<<"offset">> := CmdOffset, <<"length">> := CmdLength}, #{<<"text">> := Text}) ->
    ArgsUtfOffset = CmdOffset + CmdLength + 1,
    ArgsByteOffset = pe4kin_util:slice_pos(Text, ArgsUtfOffset),
    read_args(NArgs, Text, ArgsByteOffset).

read_args('*', Text, O) ->
    Text1 = binary:part(Text, O, size(Text) - O),
    CmdLine = case binary:split(Text1, <<$\n>>) of
                  [CmdLine1, _] -> CmdLine1;
                  [CmdLine1] -> CmdLine1
              end,
    binary:split(CmdLine, [<<$\s>>, <<$\t>>], [global, trim_all]);
read_args(N, Text, O) ->
    Text1 = hd(binary:split(binary:part(Text, O, size(Text) - O), <<$\n>>)),
    read_args1(N, Text1).

read_args1(0, _) -> [];
read_args1(N, Text) ->
    case binary:split(pe4kin_util:strip(Text, left), [<<$\s>>, <<$\t>>], [trim]) of
        [Arg, Rest] ->
            [Arg | read_args1(N - 1, Rest)];
        [] -> [];
        [Arg] -> [Arg]
    end.


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

message_command_test() ->
    CommandObj = #{<<"type">> => <<"bot_command">>,
                   <<"offset">> => 10,
                   <<"length">> => 7},
    Message = #{<<"text">> => <<"asd \n fgh /CmD@ME qwe rty   \t  uio  \n jkl">>,
                <<"entities">> => [#{<<"type">> => <<"mention">>}, CommandObj]},
    ?assertEqual({<<"/cmd">>, <<"me">>, true, CommandObj},
                 message_command(<<"me">>, Message)),
    ?assertEqual({<<"/cmd">>, <<"me">>, false, CommandObj},
                 message_command(<<"not_me">>, Message)).

command_get_args_test() ->
    CommandObj = #{<<"type">> => <<"bot_command">>,
                   <<"offset">> => 10,
                   <<"length">> => 7},
    Message = #{<<"text">> => <<"asd \n fgh /CmD@ME qwe rty   \t  uio  \n jkl">>,
                <<"entities">> => [#{<<"type">> => <<"mention">>}, CommandObj]},
    ?assertEqual([<<"qwe">>, <<"rty">>, <<"uio">>], command_get_args('*', CommandObj, Message)),
    ?assertEqual([<<"qwe">>, <<"rty">>, <<"uio">>], command_get_args(3, CommandObj, Message)),
    ?assertEqual([<<"qwe">>, <<"rty">>, <<"uio">>], command_get_args(10, CommandObj, Message)),
    ?assertEqual([<<"qwe">>], command_get_args(1, CommandObj, Message)).

-endif.
