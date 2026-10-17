"""Real game/player socket episodes; private prompt records and replay hash parity."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys

import websockets
from replay_summary import Reader, summarize


async def play(binary, player_binary, folder, config, revision):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = config | {"tokens": [str(seat) for seat in range(4)]}
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "PLAYER_PROMPT",
        "PLAYER_SCRIPTED",
    ):
        environment.pop(key, None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "episode.replay").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "prompts.jsonl").as_uri(),
        COWORLD_SOURCE_REVISION=revision,
    )
    received = {}
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=environment, stdout=log, stderr=log
        )
        tasks, players, logs = [], [], []
        try:
            # Socket bind is probed without starting a player or mutating game state.
            async with asyncio.timeout(30):
                while True:
                    assert process.returncode is None, (folder / "game.log").read_text()
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            break
                    await asyncio.sleep(0.02)

            async def seat_client(seat):
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}",
                    max_size=2**20,
                ) as connection:
                    registration = json.dumps(
                        {
                            "type": "register",
                            "kind": "external",
                            "policy": f"test-{seat}",
                        }
                    ).encode()
                    packet = (
                        b"\x81" + struct.pack("<H", len(registration)) + registration
                    )
                    await connection.send(packet)
                    frames = 0
                    async for raw in connection:
                        if isinstance(raw, bytes):
                            frames += 1
                            if frames < 240 and frames % 24 == 1:
                                await connection.send(packet)
                            await connection.send(b"\x85")
                            continue
                        frame = json.loads(raw)
                        assert frame["type"] == "decision"
                        view = frame["view"]
                        assert (
                            view["you"]["alias"]
                            == ["RED", "BLUE", "GREEN", "YELLOW"][seat]
                        )
                        assert all(
                            set(row) == {"alias", "score", "lives", "screen"}
                            for row in view["scoreboard"]
                        )
                        for other in range(4):
                            if other != seat:
                                assert (
                                    f"PRIVATE-{other}" not in raw
                                    and f"SPECTATOR-{other}" not in raw
                                )
                        received[frame["id"], seat] = frame
                        action = {
                            "mode": "clear",
                            "zone": "none",
                            "risk": 0.55,
                            "lead_ticks": 12,
                            "fire": "auto",
                            "note": f"PRIVATE-{seat}",
                            "say": f"SPECTATOR-{seat}",
                        }
                        await connection.send(
                            json.dumps(
                                {"type": "action", "id": frame["id"], "action": action}
                            )
                        )

            if player_binary:
                for seat in range(4):
                    player_env = environment | {
                        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}",
                        "PLAYER_PROMPT": f"PRIVATE-OPERATOR-{seat}: maximize your score.",
                        "COWORLD_LLM_ENDPOINT": "http://127.0.0.1:9",
                    }
                    player_log = (folder / f"player-{seat}.log").open("w")
                    logs.append(player_log)
                    players.append(
                        await asyncio.create_subprocess_exec(
                            player_binary,
                            env=player_env,
                            stdout=player_log,
                            stderr=player_log,
                        )
                    )
            else:
                tasks = [asyncio.create_task(seat_client(seat)) for seat in range(4)]
            async with asyncio.timeout(180):
                while "results: " not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    for task in tasks:
                        if task.done():
                            task.result()
                            raise AssertionError("seat ended before artifacts")
                    await asyncio.sleep(0.05)
            # Artifacts are final; stop this test's processes during the unchanged grace.
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for child in players + [process]:
                if child.returncode is None:
                    child.terminate()
                await asyncio.wait_for(child.wait(), timeout=10)
            for player_log in logs:
                player_log.close()
    results = json.loads((folder / "results.json").read_text())
    summary = summarize(folder / "episode.replay")
    assert results == summary["results"]
    assert results["reason"] == "complete"
    assert summary["tickCount"] >= config["minTicks"]
    assert summary["budgetGuards"] == 0 and not summary["stopped"]
    assert all(kind == "llm" for kind in summary["policyKinds"])
    records = [
        json.loads(line) for line in (folder / "prompts.jsonl").read_text().splitlines()
    ]
    episode = records[-1]
    assert (
        episode["kind"] == "episode_summary" and episode["source_revision"] == revision
    )
    assert episode["game_seed"] == config["seed"] and episode["results"] == results
    selected = (
        ["canonical", "plain", "numbered", "questions", "reordered"][
            config["promptSeed"] % 5
        ]
        if config["promptVariant"] == "mixed"
        else config["promptVariant"]
    )
    server_records = {}
    reports = {}
    systems = set()
    for record in records[:-1]:
        assert record["schema"] == "atari57.prompt-provenance.v1"
        is_report = record["kind"] == "player_report"
        if is_report:
            record = record["report"]
        metadata = record["prompt_template"]
        assert (
            metadata["bank"],
            metadata["variant"],
            metadata["selection"],
            metadata["seed"],
        ) == (
            "atari57-rules-v1",
            selected,
            config["promptVariant"],
            config["promptSeed"],
        )
        messages = record["messages"]
        assert [m["role"] for m in messages] == ["system", "user"]
        for message in messages:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
        systems.add(messages[0]["content"])
        key = record["request_id"], record["seat"]
        if is_report:
            assert record["kind"] == "player_request_context"
            reports[key] = record
            for other in range(4):
                assert (f"PRIVATE-OPERATOR-{other}" in messages[1]["content"]) == (
                    other == record["seat"]
                )
        else:
            assert record["kind"] == "server_decision_context"
            server_records[key] = record
            if not player_binary:
                frame = received[key]
                assert metadata == frame["prompt_template"]
                assert messages[0]["content"] == frame["system"]
                assert json.loads(messages[1]["content"]) == frame["view"]
    assert len(systems) == 1 and server_records
    if player_binary:
        assert reports.keys() == server_records.keys()
        assert any(r["retry"] for r in reports.values())
        assert summary["fallbacks"] > 0
        assert all(s["source"] != "llm" for s in summary["stances"])
    else:
        assert not reports and server_records.keys() == received.keys()
        assert summary["fallbacks"] == 0
    replay_bytes = (folder / "episode.replay").read_bytes()
    for secret in (
        b"prompt_template",
        b"atari57-rules-v1",
        b"promptSeed",
        b"PRIVATE-OPERATOR",
    ):
        assert secret not in replay_bytes and secret not in json.dumps(results).encode()
    # Read the real action/hash log, excluding timestamps and wall-clock latency.
    reader = Reader(replay_bytes)
    assert reader.take(8) == b"COWLDA57"
    reader.u16()
    reader.string()
    reader.string()
    reader.u64()
    replay_config = json.loads(reader.string())
    hashes, actions = [], []
    while not reader.done():
        kind = reader.u8()
        tick = reader.u32()
        if kind == 1:
            hashes.append((tick, reader.u64()))
        elif kind == 2:
            actions.append((tick, reader.u8(), reader.u8()))
        elif kind == 3:
            reader.u8()
            reader.string()
            reader.i16()
            reader.string()
        elif kind == 4:
            reader.u8()
        elif kind == 5:
            reader.u8()
            reader.string()
        elif kind == 6:
            reader.u8()
            reader.take(reader.u32())
        else:
            raise AssertionError(kind)
    return (
        replay_config,
        hashes,
        actions,
        results["scores"],
        results["endRule"],
        systems.pop(),
    )


async def main():
    binary, output, revision = sys.argv[1:4]
    player_binary = sys.argv[4] if len(sys.argv) == 5 else ""
    output = Path(output).resolve()
    output.mkdir(mode=0o700)
    manifest = json.loads(
        (
            Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
        ).read_text()
    )
    completed = 0
    for variant in manifest["variants"]:
        direct = (
            ["canonical", "plain", "heldout-briefing"]
            if player_binary
            else [
                "canonical",
                "plain",
                "numbered",
                "questions",
                "reordered",
                "heldout-briefing",
                "heldout-reference",
            ]
        )
        selections = [(name, 0) for name in direct]
        if not player_binary:
            selections += [("mixed", index) for index in range(5)]
        canonical = None
        systems = {}
        for selection, prompt_seed in selections:
            config = variant["game_config"] | {
                "seed": 17,
                "promptVariant": selection,
                "promptSeed": prompt_seed,
                "turnSpacingMs": 0,
            }
            outcome = await play(
                binary,
                player_binary,
                output / f"{variant['id']}-{selection}-{prompt_seed}",
                config,
                revision,
            )
            if canonical is None:
                canonical = outcome[:-1]
            else:
                assert outcome[:-1] == canonical, (
                    "Wording changed replay config, hash chain, actions, score, or ending"
                )
            if selection == "mixed":
                assert outcome[-1] == systems[direct[prompt_seed]]
            else:
                systems[selection] = outcome[-1]
            completed += 1
            print(variant["id"], selection, prompt_seed, "PASS", flush=True)
        assert len(set(systems.values())) == len(direct)
    print(
        json.dumps(
            {
                "complete_socket_games": completed,
                "native_failed_transport": bool(player_binary),
            }
        )
    )


asyncio.run(main())
