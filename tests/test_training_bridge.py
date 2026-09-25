"""Exercise complete Atari 57 games through the JSONL training interface."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def request(process: subprocess.Popen[str], command: dict) -> dict:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / "atari57-training-bridge"
    subprocess.run(
        ["nim", "c", "--hints:off", "--path:src", f"--out:{binary}",
         "src/lane/training_bridge.nim"],
        cwd=ROOT,
        check=True,
    )
    for rom in ("chomper", "brickfall", "gallery"):
        with subprocess.Popen(
            [str(binary), rom], cwd=ROOT, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, text=True,
        ) as process:
            observation = request(process, {"kind": "reset", "seed": "7", "players": 4})
            decisions = 0
            while observation["kind"] == "decision":
                assert observation["seat"] == decisions % 4
                assert observation["decision_id"] == decisions
                visible = json.loads(observation["messages"][1]["content"])
                assert visible["you"]["alias"] == ["RED", "BLUE", "GREEN", "YELLOW"][decisions % 4]
                assert visible["rom"] == rom
                assert len(visible["screen_map"]) == 17
                stale = request(process, {"kind": "step", "decision_id": -1,
                                          "response": "{}"})
                assert stale["kind"] == "rejected"
                invalid = request(process, {"kind": "step", "decision_id": decisions,
                                            "response": "not JSON"})
                assert invalid["kind"] == "rejected"
                teacher = request(process, {"kind": "teacher"})["response"]
                assert json.loads(teacher)["mode"] in {"clear", "hunt", "strike", "safe", "bank"}
                result = request(process, {"kind": "step", "decision_id": decisions,
                                           "response": teacher})
                assert result["kind"] == "accepted"
                assert result["action"]["mode"] == json.loads(teacher)["mode"]
                observation = result["observation"]
                decisions += 1
                assert decisions <= 700
            assert observation["kind"] == "terminal"
            assert set(observation["scores"]) == {"0", "1", "2", "3"}
            assert len(set(observation["scores"].values())) == 1
        assert process.returncode == 0
        print(rom, decisions, observation["scores"]["0"])

    for rom in ("chomper", "brickfall", "gallery"):
        with subprocess.Popen(
            [str(binary), rom, "--numeric"], cwd=ROOT, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, text=True,
        ) as process:
            first = request(process, {"kind": "reset", "seed": "7", "players": 4})
            assert first["game"] == "atari-57"
            assert first["seat"] == first["engine_seat"] == 0
            assert first["semantic_view"]["rom"] == rom
            assert first["action_schema"]["properties"]["choice"]["maximum"] == 50
            encoded = request(process, {"kind": "encode"})
            assert len(encoded["values"]) == 435
            assert all(isinstance(value, (int, float)) for value in encoded["values"])
            assert [action["choice"] for action in encoded["actions"]] == list(range(51))
            assert request(process, {"kind": "reset", "seed": "7", "players": 4}) == first
            assert request(process, {"kind": "encode"}) == encoded
            assert json.loads(request(process, {"kind": "teacher"})["response"]) == {"choice": 0}
            stale = request(process, {"kind": "step", "decision_id": -1,
                                      "response": '{"choice": 50}'})
            assert stale["kind"] == "rejected"
            result = request(process, {"kind": "step", "decision_id": 0,
                                       "response": '{"choice": 50}'})
            assert result["kind"] == "accepted"
            assert result["action"] == {"choice": 50}
            assert result["observation"]["seat"] == 1
        assert process.returncode == 0
        print(rom, "numeric", len(encoded["values"]), len(encoded["actions"]))
