## The three shared sprite behaviours (`Chaser`, `Ballistic`, `Marcher`) and
## the committed `BallFan` table.
##
## The fan is a LITERAL, not a computation: it is the only source of oblique
## motion in the whole game, which is what lets the sim ship with no
## trigonometry, no square roots and no floating point anywhere (design note
## §World, units, and why they are integers). Its two invariants —
## every entry has `vy < 0`, so a paddle can never send the ball back into
## the drain, and every magnitude is within 5 % of 2 800 µu/tick — are
## asserted exhaustively by `tests/test_physics.nim`.

import sim_types, grid, maps, rom

const
  BallFan*: array[7, tuple[vx, vy: int32]] = [
    (-2600'i32, -1200'i32),
    (-2100'i32, -1900'i32),
    (-1200'i32, -2500'i32),
    (0'i32, -2800'i32),
    (1200'i32, -2500'i32),
    (2100'i32, -1900'i32),
    (2600'i32, -1200'i32)
  ]
  BallFanNominal* = 2_800'i32
  ## Serve angles: never straight down, never a wall-grazer.
  ServeFanIndices*: array[4, int32] = [1'i32, 2, 4, 5]
  BallServeTile*: tuple[col, row: int] = (8, 12)

proc fanMagnitudeSq*(i: int): int64 =
  ## |v|^2 of one fan entry, in int64 so the 5 % assertion needs no sqrt.
  int64(BallFan[i].vx) * int64(BallFan[i].vx) +
    int64(BallFan[i].vy) * int64(BallFan[i].vy)

proc scaleVelocity*(v: int32, permille: int32): int32 {.inline.} =
  ## Every product of two sim quantities is computed in int64 and narrowed
  ## with an explicit truncating `div`, so scaling is symmetric under
  ## negation on both builds.
  int32((int64(v) * int64(permille)) div 1000'i64)

proc newChaser*(id: int32): LaneSprite =
  let start = ChaserStarts[int(id) mod ChaserStarts.len]
  let c = tileCentreU(start.col, start.row)
  LaneSprite(
    kind: skChaser,
    state: ssChasing,
    alive: true,
    x: c.x, y: c.y,
    vx: 0, vy: 0,
    dir: 3'u8,
    timer: 0,
    id: id,
    homeCol: int8(ChaserHome.col),
    homeRow: int8(ChaserHome.row)
  )

proc newBall*(): LaneSprite =
  let c = tileCentreU(BallServeTile.col, BallServeTile.row)
  LaneSprite(
    kind: skBall,
    state: ssServing,
    alive: true,
    x: c.x, y: c.y,
    vx: 0, vy: 0,
    dir: 0'u8,
    timer: BallServeTicks,
    id: 0
  )

proc newMarcher*(id: int32, col, row: int): LaneSprite =
  let c = tileCentreU(col, row)
  LaneSprite(
    kind: skMarcher,
    state: ssIdle,
    alive: true,
    x: c.x, y: c.y,
    vx: 0, vy: 0,
    dir: 0'u8,
    timer: 0,
    id: id,
    homeCol: int8(col),
    homeRow: int8(row)
  )

proc newSaucer*(fromLeft: bool): LaneSprite =
  let c = tileCentreU((if fromLeft: 0 else: GridW - 1), 1)
  LaneSprite(
    kind: skSaucer,
    state: ssIdle,
    alive: true,
    x: c.x, y: c.y,
    vx: (if fromLeft: SaucerSpeed else: -SaucerSpeed), vy: 0,
    dir: (if fromLeft: 4'u8 else: 3'u8),
    timer: 0,
    id: 900
  )

proc newBolt*(friendly: bool, x, y: int32): LaneSprite =
  LaneSprite(
    kind: (if friendly: skBoltFriendly else: skBoltHostile),
    state: ssIdle,
    alive: true,
    x: x, y: y,
    vx: 0,
    vy: (if friendly: -BoltSpeedFriendly else: BoltSpeedHostile),
    dir: (if friendly: 1'u8 else: 2'u8),
    timer: 0,
    id: 0
  )

proc isHostile*(sprite: LaneSprite): bool {.inline.} =
  ## What the threat field walks from. A fleeing or returning chaser is not
  ## a threat, and a friendly bolt never is.
  if not sprite.alive:
    return false
  case sprite.kind
  of skChaser: sprite.state == ssChasing or sprite.state == ssScatter
  of skBall: true
  of skMarcher: true
  of skBoltHostile: true
  else: false

proc spriteHalf*(sprite: LaneSprite): int32 {.inline.} =
  case sprite.kind
  of skBall, skBoltFriendly, skBoltHostile: BallHalf
  else: BoxHalf

proc spriteLabel*(sprite: LaneSprite): string =
  ## The id a policy sees. Stable across a screen, so a stance can name the
  ## same hunter twice.
  case sprite.kind
  of skChaser: "H" & $sprite.id
  of skBall: "B"
  of skMarcher: "A" & $sprite.id
  of skSaucer: "S"
  of skBoltFriendly: "^"
  of skBoltHostile: "v" & $sprite.id
  else: "?"

proc spriteKindText*(sprite: LaneSprite): string =
  case sprite.kind
  of skChaser: "hunter"
  of skBall: "ball"
  of skMarcher: "marcher"
  of skSaucer: "saucer"
  of skBoltFriendly: "your_bolt"
  of skBoltHostile: "enemy_bolt"
  else: "none"

proc spriteStateText*(sprite: LaneSprite): string =
  case sprite.state
  of ssChasing: "chasing"
  of ssScatter: "scatter"
  of ssFleeing: "fleeing"
  of ssReturning: "returning"
  of ssServing: "serving"
  of ssIdle: "alive"

proc glyphFor*(sprite: LaneSprite): char =
  ## The ASCII screen glyph, matching the observation's own legend.
  case sprite.kind
  of skChaser:
    case sprite.state
    of ssFleeing: 'h'
    of ssReturning: 'r'
    else: 'H'
  of skBall: 'B'
  of skMarcher: 'A'
  of skSaucer: 'S'
  of skBoltFriendly: '^'
  of skBoltHostile: 'v'
  else: '?'

proc tileGlyph*(t: Tile): char =
  case t
  of tlWall: '#'
  of tlPellet: '.'
  of tlPower: 'o'
  of tlBrick: '='
  of tlBunker: 'X'
  of tlTunnel: ' '
  of tlFloor: ','

proc chaserSpeed*(sprite: LaneSprite, permille: int32): int32 =
  ## A chaser's speed for its current state, with the per-screen ramp applied
  ## exactly once (int64 product, truncating div).
  let base: int32 =
    case sprite.state
    of ssFleeing: ChaserFleeSpeed
    of ssReturning: ChaserReturnSpeed
    else: ChaserChaseSpeed
  scaleVelocity(base, permille)

proc chaserTarget*(
  id: int32,
  avatarCol, avatarRow: int32,
  facing: uint8,
  scatter: bool
): tuple[col, row: int32] =
  ## The four deterministic personalities: H0 takes your tile, H1 two tiles
  ## ahead of your facing, H2 four ahead, H3 six ahead — and in `Scatter`
  ## every hunter takes its own corner instead.
  if scatter:
    return case id
      of 0: (int32(GridW - 2), 1'i32)
      of 1: (1'i32, 1'i32)
      of 2: (1'i32, int32(GridH - 2))
      else: (int32(GridW - 2), int32(GridH - 2))
  let lead = int32(id) * 2'i32
  let v = dirVector(int32(facing))
  (int32(clamp(int(avatarCol + v.dx * lead), 0, GridW - 1)),
   int32(clamp(int(avatarRow + v.dy * lead), 0, GridH - 1)))
