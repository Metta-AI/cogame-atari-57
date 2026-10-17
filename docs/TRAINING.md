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

From a Metta checkout, use the public collector and exporter to build a matched
teacher corpus. Run from a clean, committed game checkout and retain the private
trajectory alongside the exported examples:

```bash
uv run --package metta-posttraining python - <<'PYTHON'
from pathlib import Path
import subprocess

from metta_training.language.dataset import export_dataset
from metta_training.language.private_io import write_private
from metta_training.language.rollout import collect
from metta_training.prompt_selection import PromptSelection

game_repo = Path("/path/to/cogame-atari-57")
assert not subprocess.check_output(
    ["git", "-C", str(game_repo), "status", "--porcelain"], text=True
).strip()
revision = subprocess.check_output(
    ["git", "-C", str(game_repo), "rev-parse", "HEAD"], text=True
).strip()
bridge = Path("/tmp/atari57-training-bridge")
output = Path("train_dir/atari57/chomper")
output.mkdir(parents=True, mode=0o700)
trajectories = []
for prompt_seed in range(5):
    trajectory = output / f"wording-{prompt_seed}.jsonl"
    episodes = collect(
        bridge, trajectory, [str(seed) for seed in range(16)], revision,
        game="atari-57", action_schema_revision="atari57-stance-v1",
        teacher_policy="atari57-arcader", players=4, max_decisions=700,
        bridge_command=[str(bridge), "chomper"],
        prompt_selection=PromptSelection(
            bank="atari-57-rules-v1", variant="mixed", seed=prompt_seed
        ),
    )
    assert len(episodes) == 16 and all(episode.status == "completed" for episode in episodes)
    trajectories.append(trajectory)
combined = output / "trajectories.jsonl"
write_private(combined, "".join(path.read_text() for path in trajectories))
export_dataset(combined, output / "dataset")
PYTHON
```

For `brickfall` or `gallery`, change the bridge's ROM argument and output path.
The five collections cover every training wording for each of the 16 scenario
seeds. Export splitting depends only on the scenario seed, so related wordings
cannot cross splits. The scripted `arcader` supplies labels; this does not
establish strong play. The text bridge preserves the full stance and private view.

## Rules wording

The text bridge uses the same full rules bank as hosted players. It replaces the
previous abbreviated text-bridge instructions. The numeric interface keeps its
existing prompt, 435 features, and 51 actions.

Reset accepts `promptVariant` and `promptSeed`. Training variants are `canonical`,
`plain`, `numbered`, `questions`, and `reordered`. `mixed` requires a nonnegative
integer seed and selects one of those five by seed modulo five. Selection stays
fixed for the episode and consumes no simulation randomness. Hosted evaluation
also accepts `heldout-briefing` and `heldout-reference`; the training bridge rejects
both. Keep scenario seeds and prompt seeds independent.

Each text decision exposes `semantic_view.prompt_template`: bank `atari-57-rules-v1`,
requested selection, resolved variant, prompt seed, and SHA-256 hashes of the exact
system and user messages. Metadata stays outside the model's observation text.
Numerical rules, action schema, scoring and decision cadence are shared verbatim.
Keep the original private trajectory alongside exported examples: its source and
selection records are tied to the export through the manifest trajectory hash.

For a matched study, collect the same scenario seeds with all five training
wordings. Keep all versions of a scenario in the same train/validation split.
Evaluate fixed policies on paired canonical and held-out panels with identical
scenario seeds, seats, budgets and opponents. Report invalid actions, fallback,
incomplete episodes and scores. Scripted parity does not establish improved learning.

Local complete-game checks, after building the game, player and bridge:

```bash
python tools/test_prompt_variants.py /tmp/atari57-training-bridge
python tools/test_prompt_socket_games.py /tmp/atari57-game /tmp/atari57-sockets SOURCE_REVISION
python tools/test_prompt_socket_games.py /tmp/atari57-game /tmp/atari57-native SOURCE_REVISION /tmp/atari57-player
```

The last command runs actual player processes against a closed localhost model
endpoint. It checks retry contexts and fallback without model calls. Socket checks
wait for final artifacts, then stop their own processes during shutdown grace.
The existing Docker and browser checks separately cover natural exit and replay.
