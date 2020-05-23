%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% @copyright (C) 2016, Sergey Prokhorov
%%% @doc
%%% Utility functions
%%% @end
%%% Created : 25 May 2016 by Sergey Prokhorov <me@seriyps.ru>

-module(pe4kin_util).
-export([slice/2, slice/3, slice_pos/2, slice_pos/3]).
-export([strlen/1]).
-export([strip/1, strip/2]).
-export([to_lower/1]).
-export([to_binary/1]).

%% @doc like binary:part/3 but Offset and Size in UTF-8 codepoints, not bytes
slice(Utf8, Offset, Size) ->
    {BOffset, BSize} = slice_pos(Utf8, Offset, Size),
    binary:part(Utf8, BOffset, BSize).

slice(Utf8, Size) ->
    BSize = slice_pos(Utf8, Size),
    binary:part(Utf8, 0, BSize).

%% @doc convert utf-8 Offset and Size to byte offset and size
-spec slice_pos(<<_:8>>, non_neg_integer(), non_neg_integer()) ->
                       {ByteOffset :: non_neg_integer(), ByteSize :: non_neg_integer()}.
slice_pos(Utf8, Offset, Size) ->
    slice_pos_(Utf8, Offset, Size, 0).
slice_pos_(Utf8, 0, Size, BO) -> {BO, slice_pos(Utf8, Size)};
slice_pos_(<<_C/utf8, Utf8/binary>> = B, Offset, Size, BO) ->
    SizeOfC = size(B) - size(Utf8),
    slice_pos_(Utf8, Offset -1, Size, BO + SizeOfC).

-spec slice_pos(<<_:8>>, non_neg_integer()) -> non_neg_integer().
slice_pos(Utf8, Size) ->
    slice_pos_(Utf8, Size, 0).
slice_pos_(_, 0, BS) -> BS;
slice_pos_(<<_C/utf8, Utf8/binary>> = B, Size, BS) ->
    SizeOfC = size(B) - size(Utf8),
    slice_pos_(Utf8, Size - 1, BS + SizeOfC).

%% slice(Utf8, 0, Size) ->
%%     slice(Utf8, Size);
%% slice(<<_/utf8, Utf8/binary>>, Offset, Size) ->
%%     slice(Utf8, Offset -1, Size).

%% slice(_, 0) -> <<>>;
%% slice(<<C/utf8, Rest/binary>>, Size) ->
%%     <<C/utf8, (slice(Rest, Size - 1))/binary>>.


strlen(Utf8) ->
    strlen(Utf8, 0).

strlen(<<_/utf8, Rest/binary>>, Len) ->
    strlen(Rest, Len + 1);
strlen(<<>>, Len) -> Len.



-define(IS_WSP(C), (C == $\s) orelse (C == $\n) orelse (C == $\t) orelse (C == $\r)).
strip(Bin) ->
    strip(Bin, both).

strip(Bin, both) ->
    strip(strip(Bin, left), right);

strip(<<C, Rest/binary>>, left) when ?IS_WSP(C) ->
    strip(Rest, left);
strip(Bin, right) when size(Bin) > 0 ->
    SizeMinus1 = size(Bin) - 1,
    case Bin of
        <<Rest:SizeMinus1/binary, C>> when ?IS_WSP(C) ->
            strip(Rest, right);
        Stripped ->
            Stripped
    end;
strip(Bin, _) -> Bin.



%% @doc lowercase ASCII binary
to_lower(Bin) ->
    list_to_binary(string:to_lower(binary_to_list(Bin))).

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(String) when is_list(String) -> list_to_binary(String);
to_binary(Int) when is_integer(Int) -> integer_to_binary(Int);
to_binary(Bin) when is_binary(Bin) ->  Bin.
