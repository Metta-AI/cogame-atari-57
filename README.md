# cogame-atari-57 — the league cabinet

**Four lanes. One cartridge. One credit. Two minutes.**

Four cogs sit at four cabinets running the **same game, from the same seed, at
the same moment**, each on its own private **17 × 17 tile screen**. Nobody can
touch anybody. There is no defence, no interference and no trade: there is only
*how good is your agent at this game*. When the clock runs out the highest score
takes the board.

Which cartridge is loaded — **`chomper`** (maze-chomp), **`brickfall`**
(brick-breaking) or **`gallery`** (shooter gallery) — is a manifest variant,
announced before the round, stamped into the replay and printed on the
scorebug.

```
SCORE = points / 100 + lives you still have
```

Both terms are non-negative, so the minimum is `0.000`, higher is always better,
and nothing is ever subtracted. Dying is punished by *not keeping* the lives
term rather than by a negative number — which is what keeps the whole scale
readable on a scorebug.

## A policy is just a prompt

Every 5 seconds (120 ticks) each seat sets one **stance**; a deterministic
autopilot runs it 24 times a second, doing the pathfinding, the dodging, the
aiming and the firing. You choose **what to go for** and **how much risk to
take**:

```json
{"note": "power pellet 62 ticks away in sw and nothing is chasing me there",
 "mode": "hunt", "zone": "sw", "risk": 0.55, "lead_ticks": 16,
 "fire": "auto", "say": "going for the power"}
```

`mode` is one of `clear` (take the nearest scoring thing), `hunt` (go for the
highest-value thing reachable), `strike` (cash in — the chain, the top brick
rows, the densest flank), `safe` (keep your distance and still score) and `bank`
(refuse every trade; you will score slowly and you will not die).

Ship your own by reusing this image and setting `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-atari-57:latest --name my-atari-57 \
  --run /bin/atari-57-player --secret-env PLAYER_PROMPT="<your strategy>"
```

Two scripted baselines ship in the same image, selected with
`PLAYER_SCRIPTED`: **`arcader`** (the certification player, the per-turn
fallback and the default — it clears screens and cashes chains) and
**`hoover`** (deliberately weaker: it never dodges).

## What a seat can see

Its **own whole screen** — every tile, every sprite, its avatar, its lives, its
points — as a 17-line ASCII map plus structured `threats`, `targets` and
`zones`, and a four-row **scoreboard** carrying every rival's
`{alias, score, lives, screen}` **and nothing else**. No other lane's board,
sprites, stance or policy is visible to anybody, ever. In game a seat is
`RED`, `BLUE`, `GREEN` or `YELLOW` and nothing else; real policy names live
spectator-side only, in the replay config, the scorebug roster and the endcard.

## The replay

The replay is the starter's binary `COWLDA57` action log plus a per-tick
`gameHash` chain. The viewer is a **static wasm bundle** that re-runs the very
same `src/lane/sim.nim` the server ran, from the recorded action bytes, and
checks its own hash against the recorded one **every tick** — one divergent bit
is caught at the tick it happens. No pod, no server, no live connection but S3.

## Layout

| path | what |
|---|---|
| `src/atari57.nim` | the cabinet entrypoint (`/bin/atari-57`) |
| `src/atari57_player.nim` | the thin seat registrar (`/bin/atari-57-player`) |
| `src/lane/sim.nim` | the four-lane container, the tick loop and `stepLane` |
| `src/lane/{grid,maps,rom,sprites}.nim` | the tile lattice, the three committed maps, the cartridge presets, the sprite behaviours and the `BallFan` table |
| `src/lane/{stances,control,baselines}.nim` | the reply schema, the autopilot, the two published baselines |
| `src/lane/{observation,decide,llm}.nim` | the board view, the per-turn parallel batch, the Bedrock/Anthropic transport |
| `src/lane/{server,global,broadcast,replays,replay_runtime}.nim` | the mummy server, the board render, the chrome frame, the replay codec and the shared replay runtime |
| `replay-viewer/atari57_replay.nim` | the wasm entry — the same sim module, re-simulating in the browser |
| `client/` | the broadcast chrome (`chrome_common.js` is byte-identical to the starter's) |
| `docs/RULES.md` | every number in the game |
| `docs/PROTOCOL.md` | the wire protocol |
| `docs/STANCES.md` | how to write a stance |

Nim module names may not contain `-`, so the sources are `atari57*` while the
binaries are `/bin/atari-57` and `/bin/atari-57-player`, which is what every
manifest, compose and slug string says.

## Building and testing

The whole toolchain lives in CI (`.github/workflows/ci.yml`): the Nim tests run
in **both debug and release**, `docker-smoke` plays a real episode in raw
Docker from the certification fixture, and `wasm-viewer` builds the static
bundle and **opens it in headless chromium** against the replay that episode
produced.

```bash
nimby --global sync nimby.lock          # dependencies
nim r --path:src tests/test_determinism.nim
./tools/ci/docker_smoke.sh coworld-atari-57:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot). Design note: [`docs/plans/2026-08-28-atari-57-design.md`](docs/plans/2026-08-28-atari-57-design.md).
