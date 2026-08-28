# Rules — the league cabinet

Every number the sim actually runs on. If a number here and a number in
`src/lane/` disagree, the code is right and this file is a bug.

## The shape of a game

- **`num_agents` = 4.** One seat = one lane = one quadrant of the cabinet
  screen. Seat `s` plays lane `s`; there is deliberately no seat→lane
  permutation, because the four lanes are identical by construction.
- Each lane is a **17 × 17 tile screen**, drawn into one **35 × 35 tile** board
  with a one-tile gutter: lane origins `(0,0)`, `(18,0)`, `(0,18)`, `(18,18)`.
- **`maxTicks` = 2880 ticks = 120.0 s** at 24 Hz, with a floor of
  **`minTicks` = 1440**: the episode does not end early on "all four lanes over"
  before tick 1440 — over lanes sit on their `GAME OVER` screen.
- **24 decision turns** of `turnTicks` = 120 ticks (5.0 s).

## Isolation — the invariant

`stepLane(lane, cmd, preset, tick, par)` is a **pure function of one lane's own
state, that lane's own action byte and that lane's own RNG stream.** It takes no
`SimServer`, reads no other lane and writes no other lane. Consequently:

- rewriting lane `j`'s whole action-byte stream leaves every other lane's
  per-tick state byte-identical;
- lane `i` run alone in a one-lane sim reproduces its four-lane trajectory
  exactly;
- four lanes fed the identical action-byte stream finish with identical points,
  lives, screens, sprite positions and RNG draw counts — the fairness proof.

The **one** thing that crosses lanes is the scoreboard, and it crosses in the
observation layer only: each seat sees every rival's `alias`, `score`, `lives`
and `screen` and **nothing else**. It is composed outside `stepLane` and is
never read back by the sim.

## Units

| quantity | unit | type |
|---|---|---|
| position, size | **micro-units (µu)**; 1 tile = 12 000 µu | `int32` |
| velocity | µu per tick | `int32` |
| tile coordinate | `col, row ∈ 0…16` | `int8` |
| direction | 0 stay, 1 up, 2 down, 3 left, 4 right | `uint8` |
| points | whole arcade points | `int32` |
| score accumulator | micro-points | `int64` |

The whole sim is integers: replays are re-simulated by the **emscripten/wasm32**
build of the same module the **native amd64** server ran, and their per-tick
`gameHash` chains must agree bit for bit. There is no floating point, no
trigonometry and no square root anywhere in `src/lane/{sim,grid,rom,maps,
sprites,sim_types,sim_config,sim_state}.nim` — grep-enforced by
`tests/test_determinism.nim`.

## The action byte

One byte per seat per tick, 15 legal values:

```
dir = cmd mod 5      # 0 stay, 1 up, 2 down, 3 left, 4 right
act = cmd div 5      # 0 none, 1 fire, 2 brake
```

`cmd >= 15` is **repaired to 0** in both the server and the replay runtime, so a
corrupt byte can never desynchronise the two.

## The three cartridges

| config key | `chomper` | `brickfall` | `gallery` | meaning |
|---|---|---|---|---|
| `livesPerLane` | 3 | 3 | 3 | credits per lane |
| `avatarMode` | `freeGrid` | `railBottom` | `railBottom` | how the avatar may move |
| `avatarSpeedMilli` | 1 500 | 2 200 | 1 900 | µu/tick |
| `parScore` | 2 600 | 1 800 | 2 000 | the standing record |
| `fireEnabled` | no | no | **yes** | whether `fire` does anything |
| `brakeEnabled` | **yes** | no | no | whether `brake` does anything |
| `screenClearBonus` | 500 | 350 | 300 | points for clearing the screen |
| `rampPermille` | 1 060 | 1 150 | 1 200 | per-screen speed multiplier |

Everything else — grid size, tile size, tick rate, `maxTicks`, `minTicks`, the
decision cadence, the wall-clock budget, the action byte, the scoring formula
and `num_agents` — is **identical across all three**, which is what makes one
score scale and one budget arithmetic correct for all of them.

### `chomper` — maze-chomp

The committed map has **120 pellets, 4 power pellets, 127 walkable tiles** and
**one wrap tunnel across row 8** (leaving column 0 re-enters at column 16).

- **Avatar**: moves along corridors, turns only at tile centres, with a 6-tick
  turn latch (a buffered direction older than 6 ticks is discarded). `brake`
  halves speed for that tick — it is how you let a hunter commit before you do.
- **Sprites**: four `Chaser`s starting at `(8,4)`, `(4,8)`, `(12,8)`, `(8,1)`.
  Speeds 1 250 (chasing) / 900 (fleeing) / 2 000 (returning) µu per tick. At
  every tile centre a chaser picks the legal direction (never a reverse unless
  it is the only one) minimising the tunnel-aware Manhattan distance to its
  target; ties break UP, LEFT, DOWN, RIGHT. Targets: `H0` your tile, `H1` two
  tiles ahead of your facing, `H2` four ahead, `H3` six ahead. Every
  `scatterTicks` (drawn per screen in `[360, 600]`) the roster flips to
  `Scatter` for 120 ticks and takes the four corners instead.
- **Points**: pellet **10**, power pellet **50**, eating a fleeing chaser
  **100 / 150 / 200 / 250** by chain position within one power window, screen
  clear **+500**.
- **Power window**: 144 ticks (6.0 s); every non-returning chaser flees and
  reverses once, and the chain counter resets.
- **Life lost**: your box overlaps a chasing/scattering chaser's box (both boxes
  8 000 µu on a side, centred).
- **Screen clear**: every pellet and power pellet gone.

### `brickfall` — brick-breaking

Walls on row 0 and columns 0 and 16; **row 16 is the drain**; 60 bricks on rows
3–6; a 3-tile paddle on row 15.

- **Avatar**: only `left`/`right` do anything; the paddle centre is clamped to
  `x ∈ [18 000, 186 000]`.
- **Ball**: served from `(8,12)` after a 24-tick delay at `BallFan[j]` for `j`
  drawn from `{1,2,4,5}` (never straight down, never a wall-grazer).
- **The fan** — a committed 7-entry integer table indexed by which **seventh of
  the paddle** the ball struck. Every entry has `vy < 0`, so **a paddle can
  never send the ball back into the drain**, and every magnitude is within 5 %
  of 2 800 µu/tick:

  ```
  BallFan = [(-2600,-1200), (-2100,-1900), (-1200,-2500), (0,-2800),
             (1200,-2500), (2100,-1900), (2600,-1200)]
  ```
- **Speed ramp**: every 8 brick hits `speedPermille += 50`, capped at 1 400;
  the applied velocity is `(v · speedPermille) div 1000`.
- **Points**: brick row 3 = **50**, row 4 = **30**, row 5 = **20**, row 6 =
  **10** (1 650 per screen); screen clear **+350**.
- **Life lost**: the ball's centre crosses `y = 192 000 µu`, the top of row 16.

### `gallery` — shooter gallery

Walls on row 0, columns 0 and 16 and row 16; six bunker tiles on row 12 (each
takes 3 hits); a 3-tile paddle on row 14.

- **Avatar**: `fire` spawns a friendly bolt (`vy = -4 000 µu/tick`) from the
  paddle centre, at most **2 in flight**, with a **6-tick** reload.
- **Sprites**: **32 marchers** in a 4 × 8 formation on rows 2–5. The formation
  moves as one body: every `marchTicks` (screen 1: 20 ticks) it steps one tile
  horizontally, and when any marcher would leave columns 1…15 the whole body
  steps one tile down and reverses. `marchTicks` shortens per eight marchers
  destroyed, so a thinning formation accelerates. A live marcher fires a hostile
  bolt (`vy = +2 600`) when the per-tick draw is below `fireChancePermille`
  (18) and fewer than 3 hostile bolts are in flight; the firing marcher is the
  lowest live one in a drawn column.
- **Saucer**: 12/1000 per tick, never within 240 ticks of the last, crossing row
  1 at 3 000 µu/tick. **100 points.**
- **Points**: top marcher rank **30**, then **20**, **10**, **10**; saucer
  **100**; wave clear **+300**.
- **Life lost**: a hostile bolt overlaps you, **or** any marcher reaches row 13
  (which also resets the formation and restores the bunkers — a setback, not an
  instant game over).

> The design note lists the eight formation columns as 1, 3, 5, 7, 9, 11, 13 and
> 15. That spread is flush against the note's own "would leave columns 1…15"
> bounds rule, so the body would step DOWN on every march tick and breach row 13
> in 160 ticks — a wave nothing could clear. The eight columns shipped are
> adjacent and centred (5…12), which leaves four tiles of room to the left and
> three to the right: a drop every ~7 march steps, ~1 120 ticks to a breach,
> which is the pacing every other number in the note is sized for.

## No tunnelling, proved rather than hoped

The fastest collidable is a gallery bolt at 4 000 µu/tick; the shallowest
contact window is half a tile plus a box half-side, `6 000 + 3 000 = 9 000 µu`.
`9 000 > 4 000`, so every collidable is overlapped for at least two consecutive
end-of-tick positions in every legal configuration. `tests/test_physics.nim`
asserts the inequality directly and cross-checks the swept test against the
end-position test over 50 000 randomised states.

## Scoring

```
scoreMicro[s] = 10 000 · points[s] + 1 000 000 · lives[s]
score[s]      = scoreMicro[s] / 1 000 000        (three decimals)
```

**Placement** is computed once at game over by this exact chain: higher score,
then more lives left, then **earlier** `lastScoreTick` (reaching the same total
sooner is better play), then lower seat index. The index tiebreak makes the
chain total, so `placements` is always a strict permutation of 1…4 and exactly
one seat wins. There are no shared places.

The league ranks by the seat's **mean `results.scores` value** across its
episodes. `results.rom` records which cartridge an episode played, so a board
can always be split per ROM afterwards.

## Ending

| `reason` | `endRule` | when |
|---|---|---|
| `complete` | `all_lanes_over` | `t ≥ minTicks` **and** all four lanes have spent their lives |
| `complete` | `full_time` | `maxTicks` reached with at least one lane alive — the normal ending |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` (660) elapsed first; the sim stops at that tick and scores the state as it stands |
| `fault` | `sim_fault` | an invariant guard tripped; a partial replay is still written |
| `fault` | `host_error` | an unexpected server-side exception |

A seat that never connects does **not** end the episode: the lobby timeout
expires, the no-show is reported to `COGAME_PLAYER_FAILURE_URI`, its lane is
driven by `arcader` for the whole run, and the round plays to a normal ending.

There is no rescue rule, no mercy and no difficulty *reduction*. A lane whose
avatar never moves loses three lives and finishes near zero — a legible,
correctly scored failure.
