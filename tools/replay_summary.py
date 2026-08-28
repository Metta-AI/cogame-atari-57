#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of an atari-57 `COWLDA57` replay.

The replay is the starter's BINARY format — the static wasm viewer parses
exactly those bytes, and a JSON replay would mean rewriting the codec, the
replay runtime, the worker and the whole seek/keyframe machinery. This script
is the repo's own forensics reader for it, and it is what phase 60 substitutes
for SPEC §Definition of done check 4:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null
    jq -r '.protocol, .rom, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.stances[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.stances[]|select(.source=="llm")|.mode]|unique' /tmp/ep.json

Python 3 standard library only: no Nim, no Docker, no dependencies.
"""

import json
import struct
import sys

MAGIC = b"COWLDA57"
PROTOCOL = "atari-57/v1"

TICK_HASH = 0x01
INPUT = 0x02
JOIN = 0x03
LEAVE = 0x04
CHAT = 0x05
DEBUG_SPRITE = 0x06


class Reader:
    """A cursor over the replay bytes. Every read is bounds-checked, because a
    truncated artifact is a normal thing to be handed and must produce a clean
    error rather than a traceback."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        if self.pos + n > len(self.data):
            raise ValueError(
                "replay is truncated at byte %d (wanted %d more)" % (self.pos, n))
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def i16(self):
        return struct.unpack("<h", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def string(self):
        return self.take(self.u16())

    def done(self):
        return self.pos >= len(self.data)


def brace_match(text, start):
    """The config JSON, brace-matched from the first `{`. The header stores it
    as a length-prefixed string, so this is belt and braces — but it is the
    technique the starter's own forensics documents, and it is what recovers a
    config from a file whose length prefix was mangled."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def decode(raw):
    """Every recorded string is truncated on RUNE boundaries by the server, so
    strict UTF-8 decoding is the point of this function: a byte-truncated
    multi-byte character would raise here, which is exactly the signal wanted."""
    return raw.decode("utf-8")


def summarize(path):
    with open(path, "rb") as handle:
        data = handle.read()

    if not data.startswith(MAGIC):
        raise ValueError("not a %s replay" % MAGIC.decode("ascii"))

    reader = Reader(data)
    reader.take(len(MAGIC))
    format_version = reader.u16()
    game_name = decode(reader.string())
    game_version = decode(reader.string())
    reader.u64()                                    # recorded-at, milliseconds
    config_raw = decode(reader.string())

    config = {}
    if config_raw:
        try:
            config = json.loads(config_raw)
        except ValueError:
            brace = brace_match(config_raw, config_raw.find("{"))
            config = json.loads(brace) if brace else {}

    tick_count = 0
    inputs = 0
    joins = []
    stances = []
    registers = []
    fallbacks = 0
    budget_guards = 0
    stopped = False
    results = {}

    while not reader.done():
        kind = reader.u8()
        if kind == TICK_HASH:
            tick = reader.u32()
            reader.u64()
            tick_count = max(tick_count, tick)
        elif kind == INPUT:
            reader.u32()
            reader.u8()
            reader.u8()
            inputs += 1
        elif kind == JOIN:
            reader.u32()
            player = reader.u8()
            name = decode(reader.string())
            slot = reader.i16()
            reader.string()
            joins.append({"player": player, "name": name, "slot": slot})
        elif kind == LEAVE:
            reader.u32()
            reader.u8()
        elif kind == CHAT:
            reader.u32()
            reader.u8()
            message = decode(reader.string())
            if not message.startswith("{"):
                continue
            try:
                record = json.loads(message)
            except ValueError:
                continue
            key = record.get("k")
            if key == "stance":
                stances.append(record)
            elif key == "register":
                registers.append(record)
            elif key == "fallback":
                fallbacks += 1
            elif key == "budget_guard":
                budget_guards += 1
            elif key == "stopped":
                stopped = True
            elif key == "result":
                results = record.get("results", {})
        elif kind == DEBUG_SPRITE:
            reader.u32()
            reader.u8()
            reader.take(reader.u32())
        else:
            raise ValueError("unknown replay record type %d at byte %d"
                             % (kind, reader.pos - 1))

    names = results.get("names") or [j["name"] for j in joins]
    aliases = results.get("aliases") or [r.get("alias", "") for r in registers]
    policy_kinds = results.get("policyKinds") or [
        r.get("kind", "") for r in registers]

    return {
        "protocol": PROTOCOL,
        "formatVersion": format_version,
        "gameName": game_name,
        "gameVersion": game_version,
        "rom": config.get("rom", results.get("rom", "")),
        "seed": config.get("seed"),
        "parScore": config.get("parScore"),
        "names": names,
        "aliases": aliases,
        "policyKinds": policy_kinds,
        "tickCount": tick_count,
        "inputRecords": inputs,
        "stances": stances,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "stopped": stopped,
        "results": results,
    }


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: replay_summary.py <replay path>\n")
        return 2
    try:
        summary = summarize(argv[1])
    except (OSError, ValueError) as error:
        sys.stderr.write("replay_summary: %s\n" % error)
        return 1
    # ensure_ascii=False so the output is real UTF-8 and a strict parser
    # actually exercises the rune discipline the server promises.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
