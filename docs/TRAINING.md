# Train on Atari 57

The headless bridge runs the shipped simulator and uses the same seat-specific
`laneViewJson`, `parseLaneStance`, `laneCommand`, and `arcaderStance` as the hosted
game. All four seats choose a stance before each 120-tick turn. The bridge
supports the `chomper`, `brickfall`, and `gallery` ROMs.

Build and test from this repository root:

```bash
nimby sync nimby.lock
nim c -d:release --path:src --out:/tmp/atari57-training-bridge \
  src/lane/training_bridge.nim
python3 tests/test_training_bridge.py
```

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
The stance contains quantized risk and lead values plus categorical controls.
PufferLib and Metta RL need a fixed numeric observation codec before they can
train this game through their current generic bridge.
