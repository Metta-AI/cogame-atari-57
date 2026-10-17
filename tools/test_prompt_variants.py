"""Complete games through the real bridge, with matched wording and numeric panels."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
templates = ["canonical", "plain", "numbered", "questions", "reordered"]
roms = ["chomper", "brickfall", "gallery"]
completed = 0


def request(process, value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for rom in roms:
    process = subprocess.Popen(
        [binary, rom], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )
    try:
        for seed in ("17", "946001"):
            canonical = None
            direct = []
            for selection, prompt_seed in [
                *((name, 0) for name in templates),
                *(("mixed", i) for i in range(5)),
            ]:
                selected = templates[prompt_seed] if selection == "mixed" else selection
                observation = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 4,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                    },
                )
                transcript = []
                systems = set()
                while observation["kind"] == "decision":
                    view = observation["semantic_view"]
                    metadata = view.pop("prompt_template")
                    assert metadata["bank"] == "atari57-rules-v1"
                    assert (
                        metadata["selection"],
                        metadata["seed"],
                        metadata["variant"],
                    ) == (selection, prompt_seed, selected)
                    messages = observation["messages"]
                    assert [m["role"] for m in messages] == ["system", "user"]
                    for message in messages:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    systems.add(messages[0]["content"])
                    assert observation["inference_mode"] == "text_action"
                    assert json.loads(messages[1]["content"]) == view
                    assert view["rom"] == rom
                    assert len(view["screen_map"]) == 17
                    assert len(view["scoreboard"]) == 4
                    assert all(
                        set(row) == {"alias", "score", "lives", "screen"}
                        for row in view["scoreboard"]
                    )
                    seat = observation["seat"]
                    for other in range(4):
                        if other != seat:
                            assert f"PRIVATE-{other}" not in messages[1]["content"]
                            assert f"SPECTATOR-{other}" not in messages[1]["content"]
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    assert set(action) == {
                        "mode",
                        "zone",
                        "risk",
                        "lead_ticks",
                        "fire",
                        "say",
                        "note",
                    }
                    action["note"] = f"PRIVATE-{seat}"
                    action["say"] = f"SPECTATOR-{seat}"
                    transcript.append((view, messages[1], action))
                    result = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": observation["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert result["kind"] == "accepted" and result["action"] == action
                    observation = result["observation"]
                    assert len(transcript) <= 96
                assert observation["kind"] == "terminal" and 48 <= len(transcript) <= 96
                assert len(systems) == 1
                system = systems.pop()
                outcome = transcript, observation
                if selection == "canonical":
                    canonical = outcome
                    mechanics = system[
                        system.index("Your screen is 17 columns") : system.index(
                            "YOU CAN SEE YOUR WHOLE SCREEN"
                        )
                    ]
                    schema = system[system.index("Reply with a single JSON object") :]
                else:
                    assert outcome == canonical, (
                        "Wording changed private state, actions, or outcome"
                    )
                assert mechanics in system and schema in system
                if selection == "mixed":
                    assert system == direct[prompt_seed]
                else:
                    direct.append(system)
                completed += 1
            assert len(set(direct)) == 5
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    for invalid in (
        {"promptVariant": "heldout-briefing"},
        {"promptVariant": "heldout-reference"},
        {"promptVariant": "mixed"},
        {"promptVariant": "unknown"},
        {"promptVariant": 1},
        {"promptVariant": "mixed", "promptSeed": -1},
        {"promptVariant": "mixed", "promptSeed": True},
        {"promptVariant": "mixed", "promptSeed": 1.5},
    ):
        result = subprocess.run(
            [binary, rom],
            input=json.dumps({"kind": "reset", "seed": "17", "players": 4} | invalid)
            + "\n",
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

comparisons = 0
if len(sys.argv) == 3:
    baseline = str(Path(sys.argv[2]).resolve())
    for rom in roms:
        processes = [
            subprocess.Popen(
                [program, rom, "--numeric"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for program in (baseline, binary)
        ]
        try:
            for seed in ("17", "946001"):
                observations = [
                    request(p, {"kind": "reset", "seed": seed, "players": 4})
                    for p in processes
                ]
                while observations[0]["kind"] == "decision":
                    assert observations[0] == observations[1], (
                        "Numeric canonical behavior changed"
                    )
                    encoded = [request(p, {"kind": "encode"}) for p in processes]
                    assert encoded[0] == encoded[1]
                    assert len(encoded[0]["values"]) == 435
                    actions = [
                        request(p, {"kind": "teacher"})["response"] for p in processes
                    ]
                    assert actions[0] == actions[1]
                    results = [
                        request(
                            p,
                            {
                                "kind": "step",
                                "decision_id": obs["decision_id"],
                                "response": action,
                            },
                        )
                        for p, obs, action in zip(
                            processes, observations, actions, strict=True
                        )
                    ]
                    assert results[0] == results[1]
                    observations = [r["observation"] for r in results]
                assert observations[0] == observations[1]
                comparisons += 1
        finally:
            for p in processes:
                p.stdin.close()
                p.stdout.close()
                assert p.wait(timeout=5) == 0
print(
    json.dumps(
        {
            "complete_language_games": completed,
            "original_numeric_comparisons": comparisons,
        }
    )
)
