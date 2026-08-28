## The 17x17 tile lattice: coordinate helpers, the tunnel wrap, the seeded
## per-lane RNG, the axis-aligned contact tests, and the quad-split board
## mapping.
##
## Replaces `coworld-ctf`'s `src/ctf/arena.nim` + `map_art.nim` + `paint.nim`
## wholesale — there is no map generator, no `mapSpec` and no procedural
## terrain in this coworld.
##
## NO FLOATING POINT LIVES HERE, and none may ever be added: this module is
## compiled into both the native amd64 server and the emscripten/wasm32
## replay runtime, and their per-tick `gameHash` chains must agree bit for
## bit. `tests/test_determinism.nim` greps this file for `float`, `sqrt`,
## `sin`, `cos` and friends and fails on any hit.

import sim_types

# ---------------------------------------------------------------------------
#  The lane RNG
# ---------------------------------------------------------------------------
#
#  xoroshiro128+, the algorithm Nim's own `std/random` runs, written out
#  explicitly with `uint64` state. It is written here rather than imported
#  because (a) `Rand`'s fields are private, and flatty serializes SimServer
#  positionally into replay keyframes, and (b) `rand(int)` is 32-bit under
#  --cpu:wasm32 and 64-bit natively, which is exactly the hazard that makes a
#  replay diverge between the two builds. Every draw in the game goes through
#  `drawInt`, on the uint64 domain, and nothing else ever touches randomness.

proc rotl(x: uint64, k: int): uint64 {.inline.} =
  (x shl k) or (x shr (64 - k))

proc splitMix64(state: var uint64): uint64 =
  state = state + 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc seedLaneRng*(a, b: var uint64, seed: int) =
  ## Seeds one lane's stream. All four lanes are seeded IDENTICALLY from the
  ## game seed, which is what makes "same seed" mean "same challenge".
  var s = uint64(seed) xor 0xA57C0FFEE0DDBA11'u64
  a = splitMix64(s)
  b = splitMix64(s)
  if a == 0'u64 and b == 0'u64:
    a = 0x9E3779B97F4A7C15'u64

proc nextRng*(a, b: var uint64): uint64 =
  ## One step of the stream. The only source of randomness in the sim.
  let s0 = a
  var s1 = b
  result = s0 + s1
  s1 = s1 xor s0
  a = rotl(s0, 55) xor s1 xor (s1 shl 14)
  b = rotl(s1, 36)

proc drawInt*(lane: var Lane, lo, hi: int32): int32 =
  ## The ONE draw helper. Inclusive on both ends; a degenerate range returns
  ## `lo` WITHOUT consuming a draw, so the stream stays a pure function of
  ## the schedule rather than of the range arithmetic.
  if hi <= lo:
    return lo
  let span = uint64(hi - lo) + 1'u64
  let value = nextRng(lane.rngA, lane.rngB)
  inc lane.rngDraws
  lo + int32(value mod span)

# ---------------------------------------------------------------------------
#  Coordinates
# ---------------------------------------------------------------------------

proc tileCentreU*(col, row: int): tuple[x, y: int32] {.inline.} =
  ## The micro-unit centre of one tile.
  (int32(col) * TileU + HalfTileU, int32(row) * TileU + HalfTileU)

proc colOf*(x: int32): int32 {.inline.} =
  ## The column a micro-unit x falls in, clamped into the grid.
  if x < 0: 0'i32
  elif x >= LaneSpanU: int32(GridW - 1)
  else: x div TileU

proc rowOf*(y: int32): int32 {.inline.} =
  if y < 0: 0'i32
  elif y >= LaneSpanU: int32(GridH - 1)
  else: y div TileU

proc nearTileCentre*(v: int32): bool {.inline.} =
  ## True when a coordinate sits within `LatchWindowU` of a tile centre —
  ## the only moment `freeGrid` may take a buffered turn.
  let off = (v mod TileU) - HalfTileU
  (if off < 0: -off else: off) <= LatchWindowU

proc snapToCentre*(v: int32): int32 {.inline.} =
  (v div TileU) * TileU + HalfTileU

proc tileAt*(lane: Lane, col, row: int): Tile {.inline.} =
  if not inGrid(col, row): tlWall
  else: Tile(lane.tiles[tileIndex(col, row)])

proc setTile*(lane: var Lane, col, row: int, value: Tile) {.inline.} =
  if inGrid(col, row):
    lane.tiles[tileIndex(col, row)] = uint8(value)

proc isBlocking*(t: Tile): bool {.inline.} =
  ## Which tiles stop an avatar or a sprite. Bunkers stop bolts but not the
  ## paddle, which never reaches their row; treating them as solid here is
  ## what makes them absorb hits.
  t == tlWall or t == tlBunker

proc isWalkable*(t: Tile): bool {.inline.} =
  not isBlocking(t)

proc tunnelRow*(): int {.inline.} =
  ## `chomper`'s single wrap row.
  GridH div 2

proc wrapX*(x: int32): int32 {.inline.} =
  ## The row-8 tunnel wrap: leaving column 0 re-enters at column 16.
  if x < 0: x + LaneSpanU
  elif x >= LaneSpanU: x - LaneSpanU
  else: x

proc tunnelAwareDx*(ax, bx: int32, wrap: bool): int32 {.inline.} =
  ## Horizontal distance honouring the wrap, in micro-units.
  var d = bx - ax
  if wrap:
    if d > LaneSpanU div 2: d -= LaneSpanU
    elif d < -(LaneSpanU div 2): d += LaneSpanU
  d

proc manhattanTiles*(aCol, aRow, bCol, bRow: int32, wrap: bool): int32 =
  ## Tunnel-aware Manhattan distance in TILES, integer only.
  var dx = bCol - aCol
  if wrap:
    if dx > int32(GridW div 2): dx -= int32(GridW)
    elif dx < -int32(GridW div 2): dx += int32(GridW)
  let ax = (if dx < 0: -dx else: dx)
  let dy = bRow - aRow
  let ay = (if dy < 0: -dy else: dy)
  ax + ay

# ---------------------------------------------------------------------------
#  Contact tests — every collidable is an axis-aligned box
# ---------------------------------------------------------------------------

proc boxesOverlap*(ax, ay, ah, bx, by, bh: int32): bool {.inline.} =
  ## Two centred axis-aligned boxes with half-extents `ah` / `bh`.
  let
    dx = ax - bx
    dy = ay - by
    adx = (if dx < 0: -dx else: dx)
    ady = (if dy < 0: -dy else: dy)
  adx < ah + bh and ady < ah + bh

proc boxesOverlapXY*(
  ax, ay, ahx, ahy, bx, by, bhx, bhy: int32
): bool {.inline.} =
  ## Two centred axis-aligned boxes with SEPARATE half-extents per axis. The
  ## paddle is three tiles wide and a fraction of a tile tall, so a single
  ## half-extent cannot describe it — and a paddle tested as a square is a
  ## paddle the ball flies straight past.
  let
    dx = ax - bx
    dy = ay - by
    adx = (if dx < 0: -dx else: dx)
    ady = (if dy < 0: -dy else: dy)
  adx < ahx + bhx and ady < ahy + bhy

proc boxHitsTile*(x, y, half: int32, col, row: int32): bool {.inline.} =
  ## A centred box against one whole tile square.
  let c = tileCentreU(int(col), int(row))
  boxesOverlap(x, y, half, c.x, c.y, HalfTileU)

proc crossedAxis*(before, after, plane: int32): bool {.inline.} =
  ## True when a swept centre crossed one axis plane this tick, in either
  ## direction. Integer only, no division.
  (before < plane and after >= plane) or (before > plane and after <= plane)

# ---------------------------------------------------------------------------
#  The quad-split board
# ---------------------------------------------------------------------------

proc laneOriginTiles*(lane: int): tuple[col, row: int] {.inline.} =
  ## Where one lane's 17x17 screen sits in the 35x35 board.
  if lane >= 0 and lane < LaneOrigins.len: LaneOrigins[lane] else: (0, 0)

proc boardPixelOfTile*(lane, col, row: int): tuple[x, y: int] {.inline.} =
  ## The top-left board pixel of one lane tile.
  let o = laneOriginTiles(lane)
  ((o.col + col) * BoardTilePx, (o.row + row) * BoardTilePx)

proc boardPixelOfU*(lane: int, x, y: int32): tuple[x, y: int] {.inline.} =
  ## The board pixel of a micro-unit position inside one lane.
  let o = laneOriginTiles(lane)
  (o.col * BoardTilePx + int((int64(x) * BoardTilePx) div TileU),
   o.row * BoardTilePx + int((int64(y) * BoardTilePx) div TileU))

# ---------------------------------------------------------------------------
#  Zones (the five fixed regions a stance may name)
# ---------------------------------------------------------------------------

proc zoneOfTile*(col, row: int): string =
  ## `nw` = cols 0-7 rows 0-7, `ne` = cols 9-16 rows 0-7, `sw`/`se` the
  ## mirrors, and anything on column 8 or row 8 is `centre`.
  if col == GridW div 2 or row == GridH div 2:
    return "centre"
  if row < GridH div 2:
    return (if col < GridW div 2: "nw" else: "ne")
  (if col < GridW div 2: "sw" else: "se")

proc zoneMatches*(zone, tileZone: string): bool =
  ## Whether a tile's own zone falls inside the zone a stance named. The four
  ## unions (`left`/`right`/`top`/`bottom`) are accepted as well as the five
  ## quadrant names.
  case zone
  of "", "none": true
  of "left": tileZone == "nw" or tileZone == "sw"
  of "right": tileZone == "ne" or tileZone == "se"
  of "top": tileZone == "nw" or tileZone == "ne"
  of "bottom": tileZone == "sw" or tileZone == "se"
  else: zone == tileZone
