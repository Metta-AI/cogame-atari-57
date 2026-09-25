# Train on Atari 57

The headless bridge runs the shipped simulator and uses the same seat-specific
`laneViewJson`, `parseLaneStance`, `laneCommand`, and `arcaderStance` as the hosted
game. All four seats choose a stance before each 120-tick turn. The bridge
supports the `chomper`, `brickfall`, and `gallery` ROMs.

For PufferLib or Metta reinforcement learning (RL), append `--numeric` after
the ROM. The numeric codec exposes 435 fixed values from that private view and
51 actions: `0` takes the ordinary `arcader` stance; `1..50` select one of five
modes and ten zones. The game still parses the selected stance and owns its
legality, fallback, score, and replay. The codec fixes risk, lead time, and
fire for actions `1..50`; it does not cover every legal stance.

Build and test from this repository root:

```bash
nimby sync nimby.lock
nim c -d:release --path:src --out:/tmp/atari57-training-bridge \
  src/lane/training_bridge.nim
python3 tests/test_training_bridge.py
```

Use these parameters with the generic Coworld `DecisionEnvironment` or
`recipes/external/coworld.py` from Metta:

```text
command: [/tmp/atari57-training-bridge, chomper, --numeric]
observation_size: 435
actions: 51
players: 4
seat: 0
max_decisions: 700
```

Replace `chomper` with `brickfall` or `gallery` for the other certified
variants. A local `DecisionEnvironment` full episode completed on each ROM with
24, 24, and 12 learner steps respectively. This verifies interface execution,
not improvement from training. Use a timestep limit for every training run.

From a Metta checkout containing the generic Coworld bridge, collect and
export seed-separated teacher trajectories:

```bash
uv run --package metta-posttrain metta-posttrain collect-teacher \
  --bridge /tmp/atari57-training-bridge \
  --bridge-command /tmp/atari57-training-bridge \
  --output train_dir/atari57/chomper.jsonl \
  --source-revision "$(git -C /path/to/cogame-atari-57 rev-parse HEAD)" \
  --episodes 16 --max-decisions 700 --players 4 \
  --game atari57 --action-schema-revision atari57-stance-v1 \
  --teacher-policy atari57-arcader
uv run --package metta-posttrain metta-posttrain export \
  --trajectory train_dir/atari57/chomper.jsonl \
  --output train_dir/atari57/chomper-dataset
```

For `brickfall` or `gallery`, pass the ROM as a second `--bridge-command`
argument and use separate trajectory and dataset paths. The scripted `arcader`
baseline supplies protocol-valid labels; this does not establish strong play.
The text bridge preserves the full stance for Metta post-training and exposes
the same private observation as the numeric codec.
