# Agent operating guide — cogame-atari-57

Orientation for coding agents working in this repo. The game's rules live in
[docs/RULES.md](docs/RULES.md), the wire in
[docs/PROTOCOL.md](docs/PROTOCOL.md), the policy interface in
[docs/STANCES.md](docs/STANCES.md), and the whole design in
[docs/plans/2026-08-28-atari-57-design.md](docs/plans/2026-08-28-atari-57-design.md).
This file covers the things that are easy to get wrong.

## The determinism gate is inviolable

Replays are re-simulated by the **emscripten/wasm32** build of the very same
`src/lane/sim.nim` the **native amd64** server ran, and their per-tick
`gameHash` chains must agree bit for bit. So:

- **No floating point** in `src/lane/{sim,grid,rom,maps,sprites,sim_types,
  sim_config,sim_state}.nim`. No `sin`, `cos`, `sqrt`, `pow`, `float`. Floats
  are legal in `control.nim`, `global.nim`, `observation.nim` and the numeric
  parsing in `stances.nim`, because none of those is re-run at playback.
- Every stored sim field is explicitly `int32` / `int64` / `uint8` / `int8` /
  `bool` / an enum. **No bare `int` in a hashed field** — Nim's `int` is 64-bit
  natively and 32-bit under `--cpu:wasm32`.
- Every product or quotient of two sim quantities is computed in `int64` and
  narrowed with an explicit truncating `div`.
- **No `rand(`.** Every draw goes through `grid.drawInt` on the `uint64`
  domain; a per-lane `rngDraws` counter is hashed.
- No unbounded loop: every BFS is capped at `BfsNodeCap`, every prediction at a
  fixed iteration count, and every wait at a deadline.

`tests/test_determinism.nim` greps for all of this and fails on any hit. If the
gate fails, the physics or a build flag changed — **fix the code, never the
test**.

## `GameVersion` is a claim, and it is prepend-only

`GameVersion` in `src/lane/sim_types.nim` gates replay compatibility: a replay
records it, and `parseReplayBytes` refuses a mismatch. Bump it for **any**
change to hashed state or to the rules that produce it, and prepend the new
rule's headline above the old one in the changelog comment — the shape is
`GVnn (short rule name): HEADLINE`. `tools/ci/check_gameversion.sh <base>`
compares your claim against the base branch's.

## The lane invariant

`stepLane` takes no `SimServer`. If you find yourself wanting to pass one, stop:
the whole point of this coworld is that nothing a seat does can reach another
lane. The one cross-lane read is `observation.scoreboardJson`, which is composed
outside the sim and never read back into it, and `tests/test_isolation.nim`
asserts both halves.

## Two name spaces

In game a seat is `RED`, `BLUE`, `GREEN` or `YELLOW` and **nothing else**. Real
policy names appear only in the replay's config JSON, the chrome `roster`, the
endcard and `results.names`. A prompt is never written to the replay or the
results. `tests/test_locality.nim` pins both directions.

## The chrome is the starter's

`client/chrome_common.js` is **byte-identical** to `coworld-ctf`'s copy and
`tests/test_viewer.nim` pins its sha256. It reads `window.CTF_WIRE`, which this
repo deliberately does **not** define: every value it falls back to (the
playback speeds, 24 fps) is already this game's, and keeping the file
byte-identical is worth more than the identifier. That one read is the only
`CTF_` string in `client/`, and the identifier grep in `test_viewer.nim`
excludes exactly that file for exactly that reason.

`client/replay_broadcast.html` is the starter's page with the cabinet's block
**appended** under the `atari-57 additions to the inherited coworld-ctf chrome`
banner. Only the elements the design note lists are removed (`#viewpanel`,
`#fpv`, `#povBadge` and their children). A page written from scratch that
reuses the starter's ids is a rewrite and fails review.

## The viewer's four files come from ONE starter

`replay-viewer/config.nims`, `replay-viewer/atari57_replay.nim`,
`replay-viewer/static_replay*.js` and the `index.html` built from
`client/replay_broadcast.html` all come from `coworld-ctf` and from nowhere
else. The emscripten link flags and the JS bootstrap are a **matched pair**:
this lineage waits for `Module.onRuntimeInitialized`, so `config.nims` must
never gain `MODULARIZE` or `EXPORT_NAME` — a mixture throws nothing, logs
nothing and hangs on "Loading replay…" forever (cogame-lantern, 2026-08-23).

## Building

Dependencies come from nimby (`nimby --global sync nimby.lock`); the Dockerfile
is the canonical recipe and regenerates `nim.cfg` from the container's own
package tree, because the committed one would pin somebody else's paths.

```bash
nim r --hints:off --path:src tests/test_determinism.nim   # debug
nim r --hints:off -d:release --path:src tests/test_perf.nim
./tools/ci/docker_smoke.sh coworld-atari-57:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

CI runs every `tests/*.nim` twice, once debug (range and overflow checks) and
once `-d:release` (codegen bugs a debug-only CI never sees). The repo variable
`NIM_TESTS_RELEASE_ONLY` lists `tests/test_perf.nim tests/test_baselines.nim`.
