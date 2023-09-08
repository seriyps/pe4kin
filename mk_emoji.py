#!/bin/env python
#
# This script generates src/pe4kin_emoji.erl from emoji.json
# emoji.json extracted from https://web.telegram.org by smth like
# ```
# var nodes = document.querySelectorAll("a.composer_emoji_btn");
# var pairs = Array.prototype.slice.call(nodes.map(function(a) { return [a.dataset.code, a.getAttribute("title")] }))
# JSON.stringify(pairs)
# ```
# and minor postprocessing.
# FIXME: telegram specificaly handles some emojes. It sends 2 unicode chars:
# ```
# :hash: 35,8419
# :zero: 48,8419
# :one: 49,8419
# :two: 50,8419
# :three: 51,8419
# :four: 52,8419
# :five: 53,8419
# :six: 54,8419
# :seven: 55,8419
# :eight: 56,8419
# :nine: 57,8419
# ```
# Generated code now handles them not correctly.

import json
import datetime
import sys


TEMPLATE = """%%
%% This file is auto-generated at {when} by {script} from {json}.
%% DO NOT EDIT!

-module(pe4kin_emoji).
-export([name_to_char/1, char_to_name/1, is_emoji/1, names/0]).

-spec name_to_char(atom()) -> char().
{name2char};
name_to_char(_) -> throw({{pe4kin, invalid_emoji_name}}).

-spec char_to_name(char()) -> atom().
{char2name};
char_to_name(_) -> throw({{pe4kin, unknown_emoji}}).

-spec names() -> ordsets:ordset(atom()).
names() ->
[{names}].

-spec is_emoji(char()) -> boolean().
is_emoji(Char) ->
    try char_to_name(Char) of
        _ -> true
    catch throw:{{pe4kin, unknown_emoji}} ->
        false
    end.
"""


def main():
    src_file = "emoji.json"
    dst_file = "src/pe4kin_emoji.erl"
    when = datetime.datetime.utcnow()
    script = sys.argv[0]
    with open(src_file) as src:
        emoji_map = json.load(src)

    name2char = ";\n".join(
        "name_to_char('{}') -> 16#{}".format(name, char)
        for name, char in sorted(emoji_map.items(), key=lambda kv: kv[0])
    )
    char2name = ";\n".join(
        "char_to_name(16#{}) -> '{}'".format(char, name)
        for name, char in sorted(emoji_map.items(), key=lambda kv: int(kv[1], 16))
    )
    names = ",\n".join(
        "'{}'".format(name)
        for name in sorted(emoji_map.keys())
    )
    erl_module = TEMPLATE.format(
        when=when,
        script=script,
        json=src_file,
        name2char=name2char,
        char2name=char2name,
        names=names
    )
    with open(dst_file, "w") as dst:
        dst.write(erl_module)
    print "See", dst_file


if __name__ == '__main__':
    main()
