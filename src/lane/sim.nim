## The cabinet: four sealed lanes, one cartridge, one action byte per seat per
## tick.
##
## Replaces `coworld-ctf`'s `src/ctf/sim.nim` (the arena rules: teams, guns,
## flags, fog, paint, pickups, perks, the hill and the map pool are deleted,
## not disabled). What is INHERITED is the shape: an integer, wall-clock-paced
## `step` that takes one action byte per seat, a `gameHash` folded at the end
## of every tick, `Lobby -> Playing -> GameOver` phases, `initSimServer`, and
## the rule that nothing outside this module may mutate hashed state.
##
## THE LANE INVARIANT. `stepLane` is a pure function of ONE lane's own state,
## that lane's own action byte and that lane's own RNG stream. It takes no
## `SimServer`, reads no other lane and writes no other lane; the tick loop
## calls it four times. `tests/test_isolation.nim` pins all three halves of
## that (a rewritten neighbour stream cannot move you, a one-lane sim
## reproduces your four-lane trajectory, and four lanes fed one action stream
## finish identical).
##
## NO FLOATING POINT. Every quantity below is `int32`/`int64`; every product
## is computed in `int64` and narrowed with a truncating `div`. That is what
## makes the native amd64 server and the emscripten/wasm32 replay runtime
## agree bit for bit, which is the whole integrity story.

import std/[algorithm, json, strutils]
import sim_types, grid, maps, rom, sprites, sim_config, sim_state, roster

export sim_types, grid, maps, rom, sprites, sim_config, sim_state, roster

type
  LaneEventKind* = enum
    leNone
    lePickup
    leChip
    leBunker
    leChain
    leSaucer
    leNearMiss
    leLifeLost
    leScreenClear
    leRecord
    leLaneOver

  LaneEvent* = object
    ## What one lane's tick produced, for the broadcast feed and the tier-2
    ## stream. NEVER hashed, and never read back into the sim.
    kind*: LaneEventKind
    amount*: int32
    col*, row*: int32
    detail*: string

const
  NearMissU* = (6 * TileU) div 10   ## 0.6 tiles — the drama the game is made of.

proc avatarHalfX*(preset: RomPreset): int32 {.inline.} =
  ## The avatar's horizontal half-extent. A `railBottom` avatar is a THREE
  ## TILE paddle; a `freeGrid` avatar is one 8 000 µu box.
  if preset.avatarMode == amRailBottom: PaddleHalfU else: BoxHalf

proc avatarHalfY*(preset: RomPreset): int32 {.inline.} =
  BoxHalf

# ---------------------------------------------------------------------------
#  Screen construction
# ---------------------------------------------------------------------------

proc paddleRow(preset: RomPreset): int =
  if preset.rom == RomGallery: GalleryPaddleRow else: BrickfallPaddleRow

proc placeAvatar(lane: var Lane, preset: RomPreset) =
  ## Puts the avatar back on its start tile. Called on a fresh screen and on
  ## every respawn; pellets, bricks and destroyed marchers are NOT restored
  ## by this — only positions are.
  let start =
    if preset.avatarMode == amFreeGrid: ChomperStart
    else: (GridW div 2, paddleRow(preset))
  let c = tileCentreU(start.col, start.row)
  lane.ax = c.x
  lane.ay = c.y
  lane.facing = (if preset.avatarMode == amFreeGrid: 3'u8 else: 0'u8)
  lane.pendingDir = 0'u8
  lane.pendingAge = 0
  lane.reload = 0

proc spawnRoster(lane: var Lane, preset: RomPreset) =
  ## The cartridge's sprite roster at its respawn layout.
  lane.sprites.setLen(0)
  case preset.rom
  of RomChomper:
    for id in 0 ..< 4:
      lane.sprites.add(newChaser(int32(id)))
  of RomBrickfall:
    lane.sprites.add(newBall())
    lane.serveTimer = BallServeTicks
  else:
    var id = 0'i32
    for rank, row in MarcherRows:
      for col in MarcherCols:
        lane.sprites.add(newMarcher(id, col, int(lane.marchTopRow) + rank))
        inc id

proc restoreRoster(lane: var Lane, preset: RomPreset) =
  ## A RESPAWN restores POSITIONS only. Pellets, bricks and destroyed
  ## marchers stay destroyed — dying must never hand back progress, which is
  ## what separates a setback from a reset (design note §Resolution order
  ## 3.1).
  case preset.rom
  of RomChomper:
    for i in 0 ..< lane.sprites.len:
      if lane.sprites[i].kind != skChaser:
        continue
      let start = ChaserStarts[int(lane.sprites[i].id) mod ChaserStarts.len]
      let c = tileCentreU(start.col, start.row)
      lane.sprites[i].x = c.x
      lane.sprites[i].y = c.y
      lane.sprites[i].state = ssChasing
      lane.sprites[i].dir = 3'u8
    lane.powerTicksLeft = 0
    lane.chain = 0
  of RomBrickfall:
    if lane.sprites.len > 0:
      let c = tileCentreU(BallServeTile.col, BallServeTile.row)
      lane.sprites[0].x = c.x
      lane.sprites[0].y = c.y
      lane.sprites[0].vx = 0
      lane.sprites[0].vy = 0
      lane.sprites[0].state = ssServing
      lane.sprites[0].timer = BallServeTicks
      lane.sprites[0].alive = true
  else:
    var kept: seq[LaneSprite]
    for sprite in lane.sprites:
      if sprite.kind != skMarcher:
        continue                     ## bolts and saucers leave with the life.
      var restored = sprite
      if restored.alive:
        let c = tileCentreU(int(restored.homeCol), int(restored.homeRow))
        restored.x = c.x
        restored.y = c.y
      kept.add(restored)
    lane.sprites = kept
    lane.marchDir = 1
    lane.marchTimer = max(4'i32, lane.marchTicks)
    lane.reload = 0
    # The bunkers come back with the life: they are the shelter a fresh
    # credit is owed, and an eroded screen with no bunkers is unplayable.
    for row in 0 ..< GridH:
      for col in 0 ..< GridW:
        if tileOfChar(mapRows(preset.rom)[row][col]) == tlBunker:
          setTile(lane, col, row, tlBunker)
          lane.bunkerHp[tileIndex(col, row)] = BunkerHpFull

proc buildScreen(lane: var Lane, preset: RomPreset, first: bool) =
  ## A fresh screen: the committed map, the sprite roster, and the ramp state
  ## for whichever screen number this is.
  loadMapTiles(lane, preset.rom)
  if first:
    lane.screen = 1
    lane.speedPermille = 1000
    lane.marchTicks = preset.marchTicks0
    lane.marchTopRow = int32(MarcherRows[0])
  else:
    case preset.rom
    of RomChomper:
      lane.speedPermille = int32(
        (int64(lane.speedPermille) * int64(preset.rampPermille)) div 1000'i64)
    of RomBrickfall:
      lane.speedPermille = int32(min(
        (int64(lane.speedPermille) * int64(preset.rampPermille)) div 1000'i64,
        int64(BrickSpeedCap)))
    else:
      lane.marchTicks = max(4'i32, int32(
        (int64(lane.marchTicks) * 1000'i64) div int64(preset.rampPermille)))
      lane.marchTopRow = min(int32(MarcherRows[0]) + lane.screen - 1, 5'i32)
  lane.marchTimer = lane.marchTicks
  lane.marchDir = 1
  lane.powerTicksLeft = 0
  lane.chain = 0
  lane.saucerCooldown = 0
  lane.scatterHold = 0
  lane.scatterTimer = 0
  placeAvatar(lane, preset)
  spawnRoster(lane, preset)

proc initLane*(lane: var Lane, preset: RomPreset, seed: int) =
  ## One lane at tick 0. All four lanes are initialised IDENTICALLY, which is
  ## the fairness proof: same seed really does mean same challenge.
  lane = Lane()
  seedLaneRng(lane.rngA, lane.rngB, seed)
  lane.phase = lpPlaying
  lane.lives = preset.livesPerLane
  lane.points = 0
  lane.overTick = -1
  lane.lastScoreTick = -1
  lane.speedPermille = 1000
  buildScreen(lane, preset, first = true)
  if preset.rom == RomChomper:
    lane.scatterTimer = drawInt(lane, ScatterMinTicks, ScatterMaxTicks)
  if preset.rom == RomBrickfall:
    lane.sprites[0].timer = BallServeTicks
  lane.scoreMicro =
    int64(PointsMicro) * int64(lane.points) +
    int64(LifeMicro) * int64(lane.lives)

# ---------------------------------------------------------------------------
#  stepLane — the pure per-lane tick
# ---------------------------------------------------------------------------

proc bankPoints(lane: var Lane, amount: int32, tick: int) {.inline.} =
  ## Points are a running total and are NEVER taken away.
  if amount <= 0:
    return
  lane.points += amount
  lane.lastScoreTick = int32(tick)

proc loseLife(lane: var Lane, tick: int, events: var seq[LaneEvent],
              by: string) =
  if lane.phase != lpPlaying:
    return
  lane.lives = max(0'i32, lane.lives - 1)
  inc lane.deaths
  lane.phase = lpDying
  lane.phaseTimer = DyingTicks
  events.add(LaneEvent(kind: leLifeLost, amount: lane.lives, detail: by))
  if lane.lives <= 0:
    lane.phase = lpOver
    lane.overTick = int32(tick)
    events.add(LaneEvent(
      kind: leLaneOver, amount: lane.points, col: int32(tick)))

proc walkableFor(lane: Lane, col, row: int): bool {.inline.} =
  isWalkable(tileAt(lane, col, row))

proc chaserLegalDirs(lane: Lane, sprite: LaneSprite): array[4, bool] =
  ## UP, LEFT, DOWN, RIGHT — the fixed tie-break order.
  const dirs = [1'i32, 3'i32, 2'i32, 4'i32]
  let
    col = colOf(sprite.x)
    row = rowOf(sprite.y)
  for i, d in dirs:
    let v = dirVector(d)
    var ncol = int(col + v.dx)
    let nrow = int(row + v.dy)
    if row == int32(tunnelRow()):
      if ncol < 0: ncol = GridW - 1
      elif ncol >= GridW: ncol = 0
    result[i] = inGrid(ncol, nrow) and walkableFor(lane, ncol, nrow)

proc stepChasers(
  lane: var Lane, preset: RomPreset, tick: int, events: var seq[LaneEvent]
) =
  const dirs = [1'i32, 3'i32, 2'i32, 4'i32]
  let
    aCol = colOf(lane.ax)
    aRow = rowOf(lane.ay)
    scatter = lane.scatterHold > 0
  for i in 0 ..< lane.sprites.len:
    var sprite = lane.sprites[i]
    if sprite.kind != skChaser or not sprite.alive:
      continue
    # Retarget only at tile centres — the classic maze rule, and the reason
    # a chaser never oscillates between two tiles.
    if nearTileCentre(sprite.x) and nearTileCentre(sprite.y):
      sprite.x = snapToCentre(sprite.x)
      sprite.y = snapToCentre(sprite.y)
      let legal = chaserLegalDirs(lane, sprite)
      var legalCount = 0
      for ok in legal:
        if ok: inc legalCount
      let reverse =
        case sprite.dir
        of 1'u8: 2'i32
        of 2'u8: 1'i32
        of 3'u8: 4'i32
        of 4'u8: 3'i32
        else: 0'i32
      let target =
        if sprite.state == ssReturning:
          (col: int32(sprite.homeCol), row: int32(sprite.homeRow))
        else:
          chaserTarget(sprite.id, aCol, aRow, lane.facing, scatter)
      var
        bestDir = 0'i32
        bestScore = int32.high
      for k, d in dirs:
        if not legal[k]:
          continue
        if d == reverse and legalCount > 1:
          continue
        let v = dirVector(d)
        var ncol = sprite.x div TileU + v.dx
        let nrow = sprite.y div TileU + v.dy
        if nrow == int32(tunnelRow()):
          if ncol < 0: ncol = int32(GridW - 1)
          elif ncol >= int32(GridW): ncol = 0
        let score = manhattanTiles(
          ncol, nrow, target.col, target.row, nrow == int32(tunnelRow()))
        if score < bestScore:
          bestScore = score
          bestDir = d
      if bestDir != 0:
        sprite.dir = uint8(bestDir)
    let speed = chaserSpeed(sprite, lane.speedPermille)
    let v = dirVector(int32(sprite.dir))
    sprite.x = wrapX(sprite.x + v.dx * speed)
    sprite.y = clamp(sprite.y + v.dy * speed, 0'i32, LaneSpanU - 1)
    if sprite.state == ssReturning:
      let home = tileCentreU(int(sprite.homeCol), int(sprite.homeRow))
      let dx = sprite.x - home.x
      let dy = sprite.y - home.y
      if (if dx < 0: -dx else: dx) <= speed and
          (if dy < 0: -dy else: dy) <= speed:
        sprite.x = home.x
        sprite.y = home.y
        sprite.state = ssChasing
    lane.sprites[i] = sprite

proc resolveChaserContacts(
  lane: var Lane, preset: RomPreset, tick: int, events: var seq[LaneEvent]
) =
  for i in 0 ..< lane.sprites.len:
    var sprite = lane.sprites[i]
    if sprite.kind != skChaser or not sprite.alive:
      continue
    if not boxesOverlap(lane.ax, lane.ay, BoxHalf, sprite.x, sprite.y, BoxHalf):
      # A hostile that passed within 0.6 tiles without touching is the
      # near-miss the feed calls out.
      if sprite.state != ssReturning and
          boxesOverlap(lane.ax, lane.ay, NearMissU, sprite.x, sprite.y, 1):
        events.add(LaneEvent(kind: leNearMiss, amount: sprite.id))
      continue
    case sprite.state
    of ssFleeing:
      let pts = chainPoints(lane.chain)
      bankPoints(lane, pts, tick)
      inc lane.chain
      lane.bestChain = max(lane.bestChain, lane.chain)
      sprite.state = ssReturning
      lane.sprites[i] = sprite
      events.add(LaneEvent(kind: leChain, amount: pts, col: lane.chain))
    of ssReturning:
      discard
    else:
      loseLife(lane, tick, events, spriteLabel(sprite))
      return

proc stepBall(
  lane: var Lane, preset: RomPreset, tick: int, events: var seq[LaneEvent]
) =
  if lane.sprites.len == 0:
    return
  var ball = lane.sprites[0]
  if ball.kind != skBall or not ball.alive:
    return
  if ball.state == ssServing:
    if ball.timer > 0:
      dec ball.timer
      lane.sprites[0] = ball
      return
    let pick = ServeFanIndices[drawInt(lane, 0'i32, 3'i32)]
    ball.vx = BallFan[pick].vx
    ball.vy = BallFan[pick].vy
    ball.state = ssIdle
    lane.sprites[0] = ball
    return

  let
    speed = lane.speedPermille
    stepX = scaleVelocity(ball.vx, speed)
    stepY = scaleVelocity(ball.vy, speed)
  var
    nx = ball.x + stepX
    ny = ball.y + stepY
    contacted = false

  # X axis first, then Y: one contact per tick, resolved by axis, which is
  # exactly what makes a corner bounce deterministic on both builds.
  block xAxis:
    if nx < BallHalf:
      nx = BallHalf
      ball.vx = -ball.vx
      break xAxis
    if nx > LaneSpanU - BallHalf:
      nx = LaneSpanU - BallHalf
      ball.vx = -ball.vx
      break xAxis
    let t = tileAt(lane, int(colOf(nx)), int(rowOf(ball.y)))
    if t == tlWall:
      nx = ball.x
      ball.vx = -ball.vx
    elif t == tlBrick and not contacted:
      let
        col = int(colOf(nx))
        row = int(rowOf(ball.y))
      setTile(lane, col, row, tlFloor)
      let pts = brickRowPoints(row)
      bankPoints(lane, pts, tick)
      inc lane.brickHits
      if lane.brickHits mod BrickHitsPerStep == 0:
        lane.speedPermille = min(lane.speedPermille + BrickSpeedStep,
                                 BrickSpeedCap)
      nx = ball.x
      ball.vx = -ball.vx
      contacted = true
      events.add(LaneEvent(
        kind: leChip, amount: pts, col: int32(col), row: int32(row)))
  block yAxis:
    if ny < BallHalf:
      ny = BallHalf
      ball.vy = -ball.vy
      break yAxis
    let t = tileAt(lane, int(colOf(nx)), int(rowOf(ny)))
    if t == tlWall:
      ny = ball.y
      ball.vy = -ball.vy
    elif t == tlBrick and not contacted:
      let
        col = int(colOf(nx))
        row = int(rowOf(ny))
      setTile(lane, col, row, tlFloor)
      let pts = brickRowPoints(row)
      bankPoints(lane, pts, tick)
      inc lane.brickHits
      if lane.brickHits mod BrickHitsPerStep == 0:
        lane.speedPermille = min(lane.speedPermille + BrickSpeedStep,
                                 BrickSpeedCap)
      ny = ball.y
      ball.vy = -ball.vy
      contacted = true
      events.add(LaneEvent(
        kind: leChip, amount: pts, col: int32(col), row: int32(row)))

  ball.x = nx
  ball.y = ny

  # The paddle. A hit replaces the velocity with the fan entry for whichever
  # SEVENTH of the paddle it struck, so the angle really does come off the
  # paddle — and every fan entry has vy < 0, so a paddle can never send the
  # ball back into the drain.
  if ball.vy > 0 and
      boxesOverlapXY(ball.x, ball.y, BallHalf, BallHalf,
                     lane.ax, lane.ay,
                     avatarHalfX(preset), avatarHalfY(preset)):
    let offset = clamp(int(ball.x - (lane.ax - PaddleHalfU)), 0,
                       2 * PaddleHalfU - 1)
    let idx = clamp((offset * BallFan.len) div (2 * PaddleHalfU), 0,
                    BallFan.high)
    ball.vx = BallFan[idx].vx
    ball.vy = BallFan[idx].vy
    ball.y = lane.ay - avatarHalfY(preset) - BallHalf
  elif ball.y >= BrickfallDrainY:
    lane.sprites[0] = ball
    loseLife(lane, tick, events, "drain")
    return
  lane.sprites[0] = ball

proc liveMarchers(lane: Lane): int =
  for sprite in lane.sprites:
    if sprite.kind == skMarcher and sprite.alive:
      inc result

proc stepMarchers(
  lane: var Lane, preset: RomPreset, tick: int, events: var seq[LaneEvent]
) =
  if lane.marchTimer > 0:
    dec lane.marchTimer
    return
  lane.marchTimer = max(4'i32, lane.marchTicks)
  # Would any live marcher leave columns 1..15 on this step? Then the WHOLE
  # body drops one tile and reverses instead.
  var wouldLeave = false
  for sprite in lane.sprites:
    if sprite.kind != skMarcher or not sprite.alive:
      continue
    let col = colOf(sprite.x) + lane.marchDir
    if col < 1 or col > int32(GridW - 2):
      wouldLeave = true
      break
  if wouldLeave:
    lane.marchDir = -lane.marchDir
    for i in 0 ..< lane.sprites.len:
      if lane.sprites[i].kind == skMarcher and lane.sprites[i].alive:
        lane.sprites[i].y += TileU
  else:
    for i in 0 ..< lane.sprites.len:
      if lane.sprites[i].kind == skMarcher and lane.sprites[i].alive:
        lane.sprites[i].x += lane.marchDir * TileU
  # A marcher reaching row 13 costs a life AND resets the formation: a
  # setback, not an instant game over.
  for sprite in lane.sprites:
    if sprite.kind != skMarcher or not sprite.alive:
      continue
    if rowOf(sprite.y) >= 13'i32:
      loseLife(lane, tick, events, "breach")
      for i in 0 ..< lane.sprites.len:
        if lane.sprites[i].kind == skMarcher and lane.sprites[i].alive:
          let c = tileCentreU(int(lane.sprites[i].homeCol),
                              int(lane.sprites[i].homeRow))
          lane.sprites[i].x = c.x
          lane.sprites[i].y = c.y
      lane.marchDir = 1
      return

proc stepBolts(
  lane: var Lane, preset: RomPreset, tick: int, events: var seq[LaneEvent]
) =
  for i in 0 ..< lane.sprites.len:
    var bolt = lane.sprites[i]
    if not bolt.alive:
      continue
    if bolt.kind != skBoltFriendly and bolt.kind != skBoltHostile:
      continue
    bolt.y += bolt.vy
    if bolt.y < BallHalf or bolt.y > LaneSpanU - BallHalf:
      bolt.alive = false
      lane.sprites[i] = bolt
      continue
    let
      col = int(colOf(bolt.x))
      row = int(rowOf(bolt.y))
      t = tileAt(lane, col, row)
    if t == tlBunker:
      let idx = tileIndex(col, row)
      if lane.bunkerHp[idx] > 0'u8:
        dec lane.bunkerHp[idx]
      if lane.bunkerHp[idx] == 0'u8:
        setTile(lane, col, row, tlFloor)
      bolt.alive = false
      lane.sprites[i] = bolt
      events.add(LaneEvent(
        kind: leBunker, amount: int32(lane.bunkerHp[idx]),
        col: int32(col), row: int32(row)))
      continue
    if t == tlWall:
      bolt.alive = false
      lane.sprites[i] = bolt
      continue
    lane.sprites[i] = bolt

  # Friendly bolt vs marcher / saucer, in sprite id order.
  for b in 0 ..< lane.sprites.len:
    if lane.sprites[b].kind != skBoltFriendly or not lane.sprites[b].alive:
      continue
    for m in 0 ..< lane.sprites.len:
      let target = lane.sprites[m]
      if not target.alive:
        continue
      if target.kind == skMarcher:
        if boxesOverlap(lane.sprites[b].x, lane.sprites[b].y, BallHalf,
                        target.x, target.y, BoxHalf):
          let pts = marcherRowPoints(int(rowOf(target.y)), int(lane.marchTopRow))
          bankPoints(lane, pts, tick)
          lane.sprites[m].alive = false
          lane.sprites[b].alive = false
          let killed = 32 - liveMarchers(lane)
          if killed > 0 and killed mod 8 == 0:
            lane.marchTicks = max(4'i32, int32(
              (int64(lane.marchTicks) * 1000'i64) div
                int64(preset.rampPermille)))
          events.add(LaneEvent(
            kind: leChip, amount: pts,
            col: colOf(target.x), row: rowOf(target.y)))
          break
      elif target.kind == skSaucer:
        if boxesOverlap(lane.sprites[b].x, lane.sprites[b].y, BallHalf,
                        target.x, target.y, BoxHalf):
          bankPoints(lane, SaucerPoints, tick)
          lane.sprites[m].alive = false
          lane.sprites[b].alive = false
          events.add(LaneEvent(kind: leSaucer, amount: SaucerPoints))
          break

  # Hostile bolt vs avatar.
  for i in 0 ..< lane.sprites.len:
    let bolt = lane.sprites[i]
    if bolt.kind != skBoltHostile or not bolt.alive:
      continue
    if boxesOverlapXY(bolt.x, bolt.y, BallHalf, BallHalf,
                      lane.ax, lane.ay,
                      avatarHalfX(preset), avatarHalfY(preset)):
      lane.sprites[i].alive = false
      loseLife(lane, tick, events, "bolt")
      return
    if boxesOverlapXY(bolt.x, bolt.y, NearMissU, NearMissU,
                      lane.ax, lane.ay, 1, 1):
      events.add(LaneEvent(kind: leNearMiss, amount: bolt.id))

proc stepSaucer(lane: var Lane) =
  for i in 0 ..< lane.sprites.len:
    if lane.sprites[i].kind != skSaucer or not lane.sprites[i].alive:
      continue
    lane.sprites[i].x += lane.sprites[i].vx
    if lane.sprites[i].x < 0 or lane.sprites[i].x > LaneSpanU:
      lane.sprites[i].alive = false

proc compactSprites(lane: var Lane) =
  ## Dead bolts and saucers leave; chasers, the ball and marchers never do
  ## (their `alive` flag is state a screen depends on).
  var kept: seq[LaneSprite]
  for sprite in lane.sprites:
    if not sprite.alive and
        (sprite.kind == skBoltFriendly or sprite.kind == skBoltHostile or
         sprite.kind == skSaucer):
      continue
    kept.add(sprite)
  lane.sprites = kept

proc countBolts(lane: Lane, kind: SpriteKind): int =
  for sprite in lane.sprites:
    if sprite.kind == kind and sprite.alive:
      inc result

proc screenCleared(lane: Lane, preset: RomPreset): bool =
  case preset.rom
  of RomChomper:
    for i in 0 ..< GridCells:
      let t = Tile(lane.tiles[i])
      if t == tlPellet or t == tlPower:
        return false
    true
  of RomBrickfall:
    for i in 0 ..< GridCells:
      if Tile(lane.tiles[i]) == tlBrick:
        return false
    true
  else:
    liveMarchers(lane) == 0

proc guardLane(lane: Lane, preset: RomPreset) =
  ## Step-6's invariant guard, raised as `SimGuardError` so the tick loop can
  ## end the episode `fault` / `sim_fault` with a partial replay rather than
  ## crashing the container.
  if lane.ax < 0 or lane.ax >= LaneSpanU or lane.ay < 0 or lane.ay >= LaneSpanU:
    raise newException(SimGuardError, "avatar centre left its lane")
  if lane.lives < 0 or lane.lives > preset.livesPerLane:
    raise newException(SimGuardError, "lives out of range")
  if lane.points < 0:
    raise newException(SimGuardError, "points went negative")
  if lane.facing > 4'u8 or lane.pendingDir > 4'u8:
    raise newException(SimGuardError, "direction out of range")
  for sprite in lane.sprites:
    if not sprite.alive:
      continue
    if sprite.x < -TileU or sprite.x > LaneSpanU + TileU or
        sprite.y < -TileU or sprite.y > LaneSpanU + TileU:
      raise newException(SimGuardError, "sprite centre left its lane")
    let sx = (if sprite.vx < 0: -sprite.vx else: sprite.vx)
    let sy = (if sprite.vy < 0: -sprite.vy else: sprite.vy)
    if sx > preset.ballSpeedMax or sy > preset.ballSpeedMax + BoltSpeedFriendly:
      raise newException(SimGuardError, "sprite velocity above the cap")

proc stepLane*(
  lane: var Lane,
  cmd: uint8,
  preset: RomPreset,
  tick: int,
  parScore: int32
): seq[LaneEvent] =
  ## ONE lane's whole tick, in the design note's exact order. Takes no
  ## `SimServer`; reads and writes nothing but `lane`.
  result = @[]
  if lane.phase == lpOver:
    return

  # 3.1 lane phase -----------------------------------------------------------
  if lane.phase == lpDying or lane.phase == lpRespawning:
    if lane.phaseTimer > 0:
      dec lane.phaseTimer
    if lane.phaseTimer <= 0:
      if lane.phase == lpDying:
        lane.phase = lpRespawning
        lane.phaseTimer = RespawningTicks
      else:
        lane.phase = lpPlaying
        placeAvatar(lane, preset)
        restoreRoster(lane, preset)
    lane.scoreMicro =
      int64(PointsMicro) * int64(lane.points) +
      int64(LifeMicro) * int64(lane.lives)
    return

  let action = decodeAction(cmd)

  # 3.2 turn latch -----------------------------------------------------------
  if action.dir != 0:
    lane.pendingDir = uint8(action.dir)
    lane.pendingAge = 0
  elif lane.pendingDir != 0'u8:
    inc lane.pendingAge
    if lane.pendingAge > preset.latchTicks:
      lane.pendingDir = 0'u8
      lane.pendingAge = 0
  if lane.pendingDir != 0'u8:
    let want = int32(lane.pendingDir)
    if preset.avatarMode == amRailBottom:
      if want == 3 or want == 4:
        lane.facing = uint8(want)
        lane.pendingDir = 0'u8
      else:
        lane.pendingDir = 0'u8       ## up/down are no-ops on a rail.
    else:
      let cur = int32(lane.facing)
      let opposite =
        (cur == 1 and want == 2) or (cur == 2 and want == 1) or
        (cur == 3 and want == 4) or (cur == 4 and want == 3)
      if opposite:
        lane.facing = uint8(want)
        lane.pendingDir = 0'u8
      elif nearTileCentre(lane.ax) and nearTileCentre(lane.ay):
        let v = dirVector(want)
        var ncol = int(colOf(lane.ax) + v.dx)
        let nrow = int(rowOf(lane.ay) + v.dy)
        if nrow == tunnelRow():
          if ncol < 0: ncol = GridW - 1
          elif ncol >= GridW: ncol = 0
        if inGrid(ncol, nrow) and walkableFor(lane, ncol, nrow):
          lane.ax = snapToCentre(lane.ax)
          lane.ay = snapToCentre(lane.ay)
          lane.facing = uint8(want)
          lane.pendingDir = 0'u8

  # 3.3 avatar motion --------------------------------------------------------
  var speed = preset.avatarSpeed
  if action.act == 2 and preset.brakeEnabled:
    speed = speed div 2
  if preset.avatarMode == amRailBottom:
    let v = dirVector(int32(lane.facing))
    if v.dx != 0:
      lane.ax = clamp(lane.ax + v.dx * speed,
                      PaddleHalfU, LaneSpanU - PaddleHalfU)
  else:
    let v = dirVector(int32(lane.facing))
    if v.dx != 0 or v.dy != 0:
      let
        col = int(colOf(lane.ax))
        row = int(rowOf(lane.ay))
      var ncol = col + int(v.dx)
      let nrow = row + int(v.dy)
      var blocked = true
      if row == tunnelRow() and v.dy == 0:
        if ncol < 0: ncol = GridW - 1
        elif ncol >= GridW: ncol = 0
      if inGrid(ncol, nrow):
        blocked = not walkableFor(lane, ncol, nrow)
      var nx = lane.ax + v.dx * speed
      var ny = lane.ay + v.dy * speed
      if blocked:
        let cx = snapToCentre(lane.ax)
        let cy = snapToCentre(lane.ay)
        if v.dx > 0 and nx > cx: nx = cx
        if v.dx < 0 and nx < cx: nx = cx
        if v.dy > 0 and ny > cy: ny = cy
        if v.dy < 0 and ny < cy: ny = cy
      if row == tunnelRow():
        nx = wrapX(nx)
      else:
        nx = clamp(nx, HalfTileU, LaneSpanU - HalfTileU)
      lane.ax = nx
      lane.ay = clamp(ny, HalfTileU, LaneSpanU - HalfTileU)

  # 3.4 avatar-tile effects --------------------------------------------------
  block tileEffects:
    let
      col = int(colOf(lane.ax))
      row = int(rowOf(lane.ay))
      t = tileAt(lane, col, row)
    case t
    of tlPellet:
      setTile(lane, col, row, tlFloor)
      bankPoints(lane, PelletPoints, tick)
      result.add(LaneEvent(
        kind: lePickup, amount: PelletPoints,
        col: int32(col), row: int32(row), detail: "pellet"))
    of tlPower:
      setTile(lane, col, row, tlFloor)
      bankPoints(lane, PowerPoints, tick)
      lane.powerTicksLeft = preset.powerTicks
      lane.chain = 0
      for i in 0 ..< lane.sprites.len:
        if lane.sprites[i].kind == skChaser and
            lane.sprites[i].state != ssReturning:
          lane.sprites[i].state = ssFleeing
          lane.sprites[i].dir =
            case lane.sprites[i].dir
            of 1'u8: 2'u8
            of 2'u8: 1'u8
            of 3'u8: 4'u8
            of 4'u8: 3'u8
            else: 0'u8
      result.add(LaneEvent(
        kind: lePickup, amount: PowerPoints,
        col: int32(col), row: int32(row), detail: "power"))
    else:
      discard

  # 3.5 fire -----------------------------------------------------------------
  if lane.reload > 0:
    dec lane.reload
  if action.act == 1 and preset.fireEnabled and lane.reload <= 0 and
      countBolts(lane, skBoltFriendly) < MaxFriendlyBolts and
      lane.sprites.len < MaxSprites:
    lane.sprites.add(newBolt(true, lane.ax, lane.ay - BoxHalf))
    lane.reload = BoltReloadTicks
    inc lane.shotsFired

  # 3.6 / 3.7 sprite motion and contacts -------------------------------------
  case preset.rom
  of RomChomper:
    if lane.powerTicksLeft > 0:
      dec lane.powerTicksLeft
      if lane.powerTicksLeft == 0:
        for i in 0 ..< lane.sprites.len:
          if lane.sprites[i].kind == skChaser and
              lane.sprites[i].state == ssFleeing:
            lane.sprites[i].state = ssChasing
        lane.chain = 0
    stepChasers(lane, preset, tick, result)
    resolveChaserContacts(lane, preset, tick, result)
  of RomBrickfall:
    stepBall(lane, preset, tick, result)
  else:
    stepMarchers(lane, preset, tick, result)
    stepSaucer(lane)
    stepBolts(lane, preset, tick, result)
    if lane.phase == lpPlaying:
      for sprite in lane.sprites:
        if sprite.kind == skMarcher and sprite.alive and
            boxesOverlapXY(sprite.x, sprite.y, BoxHalf, BoxHalf,
                           lane.ax, lane.ay,
                           avatarHalfX(preset), avatarHalfY(preset)):
          loseLife(lane, tick, result, "marcher")
          break
    compactSprites(lane)

  # 3.9 wave / spawn schedule — EVERY rng draw in the game happens here ------
  if lane.phase == lpPlaying:
    case preset.rom
    of RomChomper:
      if lane.scatterHold > 0:
        dec lane.scatterHold
        if lane.scatterHold == 0:
          for i in 0 ..< lane.sprites.len:
            if lane.sprites[i].kind == skChaser and
                lane.sprites[i].state == ssScatter:
              lane.sprites[i].state = ssChasing
          lane.scatterTimer = drawInt(lane, ScatterMinTicks, ScatterMaxTicks)
      else:
        if lane.scatterTimer > 0:
          dec lane.scatterTimer
        if lane.scatterTimer <= 0:
          lane.scatterHold = ScatterHoldTicks
          for i in 0 ..< lane.sprites.len:
            if lane.sprites[i].kind == skChaser and
                lane.sprites[i].state == ssChasing:
              lane.sprites[i].state = ssScatter
    of RomBrickfall:
      discard
    else:
      if lane.saucerCooldown > 0:
        dec lane.saucerCooldown
      else:
        if drawInt(lane, 1'i32, 1000'i32) <= SaucerChancePermille:
          let fromLeft = drawInt(lane, 0'i32, 1'i32) == 0'i32
          if lane.sprites.len < MaxSprites:
            lane.sprites.add(newSaucer(fromLeft))
          lane.saucerCooldown = SaucerCooldownTicks
      if countBolts(lane, skBoltHostile) < MaxHostileBolts:
        if drawInt(lane, 1'i32, 1000'i32) <= preset.fireChancePermille:
          var columns: seq[int32]
          for sprite in lane.sprites:
            if sprite.kind == skMarcher and sprite.alive:
              let c = colOf(sprite.x)
              if c notin columns:
                columns.add(c)
          if columns.len > 0:
            columns.sort()
            let pick = columns[drawInt(lane, 0'i32, int32(columns.len - 1))]
            var
              lowestY = -1'i32
              lowestX = 0'i32
            for sprite in lane.sprites:
              if sprite.kind == skMarcher and sprite.alive and
                  colOf(sprite.x) == pick and sprite.y > lowestY:
                lowestY = sprite.y
                lowestX = sprite.x
            if lowestY >= 0 and lane.sprites.len < MaxSprites:
              lane.sprites.add(newBolt(false, lowestX, lowestY + BoxHalf))

  # 3.10 screen clear --------------------------------------------------------
  if lane.phase == lpPlaying and screenCleared(lane, preset):
    bankPoints(lane, preset.screenClearBonus, tick)
    inc lane.screensCleared
    inc lane.screen
    buildScreen(lane, preset, first = false)
    result.add(LaneEvent(
      kind: leScreenClear, amount: preset.screenClearBonus, col: lane.screen))

  # 3.11 record check --------------------------------------------------------
  if not lane.recordFlag and lane.points > parScore:
    lane.recordFlag = true
    result.add(LaneEvent(kind: leRecord, amount: lane.points, col: parScore))

  # 4 score fold -------------------------------------------------------------
  lane.scoreMicro =
    int64(PointsMicro) * int64(lane.points) +
    int64(LifeMicro) * int64(lane.lives)
  guardLane(lane, preset)

# ---------------------------------------------------------------------------
#  The cabinet
# ---------------------------------------------------------------------------

proc initSimServer*(config: GameConfig): SimServer =
  result = SimServer()
  result.config = config
  result.phase = Lobby
  result.gameStartTick = -1
  result.tickCount = 0
  result.startCountdown = max(1, config.startWaitTicks)
  result.gameOverHold = max(1, config.gameOverTicks)
  result.winner = -1
  result.endReason = ""
  result.endRule = ""
  result.gameEventLoggingEnabled = true
  for seat in 0 ..< 4:
    initLane(result.lanes[seat], config.preset, config.seed)
    result.seatPolicyKind[seat] = "scripted"
    result.seatMode[seat] = ""
    result.seatZone[seat] = "none"

proc effectiveMaxTicks*(sim: SimServer): int {.inline.} =
  sim.config.maxTicks

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc allLanesOver*(sim: SimServer): bool =
  for lane in sim.lanes:
    if lane.phase != lpOver:
      return false
  true

proc startGame*(sim: var SimServer) =
  ## Leaves the lobby. Every lane is rebuilt here so a lobby of any length
  ## produces the identical opening frame.
  for seat in 0 ..< 4:
    initLane(sim.lanes[seat], sim.config.preset, sim.config.seed)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.logGame("cabinet: credit inserted — rom " & sim.config.rom &
    ", seed " & $sim.config.seed)

proc computePlacements*(sim: var SimServer) =
  ## Higher score, then more lives left, then EARLIER `lastScoreTick`, then
  ## lower seat index. The index tiebreak makes the chain total, so
  ## `placements` is always a strict permutation of 1..4 and exactly one seat
  ## wins.
  var order = @[0, 1, 2, 3]
  let lanes = sim.lanes
  proc better(a, b: int): bool =
    let
      la = lanes[a]
      lb = lanes[b]
    if la.scoreMicro != lb.scoreMicro:
      return la.scoreMicro > lb.scoreMicro
    if la.lives != lb.lives:
      return la.lives > lb.lives
    let
      ta = (if la.lastScoreTick < 0: int32.high else: la.lastScoreTick)
      tb = (if lb.lastScoreTick < 0: int32.high else: lb.lastScoreTick)
    if ta != tb:
      return ta < tb
    a < b
  # A four-element insertion sort: total, stable, and trivially auditable.
  for i in 1 ..< order.len:
    let key = order[i]
    var j = i - 1
    while j >= 0 and better(key, order[j]):
      order[j + 1] = order[j]
      dec j
    order[j + 1] = key
  for rank, seat in order:
    sim.placements[seat] = rank + 1
  sim.winner = order[0]
  sim.isDraw = false

proc finishGame*(sim: var SimServer, reason, endRule: string) =
  ## Ends the episode once. Idempotent: a wall-clock stop that lands on the
  ## same tick as `full_time` must not score twice.
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = endRule
  sim.timeLimitReached = endRule == EndRuleFullTime
  sim.computePlacements()
  sim.gameOverHold = max(1, sim.config.gameOverTicks)
  sim.emitEvent(PhaseChange, detail = endRule)
  sim.logGame("cabinet: credit spent — " & reason & "/" & endRule &
    " at tick " & $sim.tickCount)

proc recordStop*(sim: var SimServer, tick: int) =
  ## The load-bearing wall-clock stop. Applied by THIS proc on record and on
  ## playback, because a wall-clock fact cannot be re-derived from sim state
  ## and hashing a state playback cannot reproduce mismatches every
  ## deadline-ended replay (particle-worlds 13c66d7, 2026-08-26).
  if sim.stopped:
    return
  sim.stopped = true
  sim.stoppedTick = tick

proc laneEventJson(sim: SimServer, lane: int, event: LaneEvent): JsonNode =
  case event.kind
  of lePickup:
    %*{"k": "pickup", "t": sim.tickCount, "lane": lane,
       "kind": event.detail, "pts": event.amount}
  of leChip:
    %*{"k": "chip", "t": sim.tickCount, "lane": lane,
       "row": event.row, "col": event.col, "pts": event.amount}
  of leBunker:
    %*{"k": "bunker", "t": sim.tickCount, "lane": lane,
       "col": event.col, "hp": event.amount}
  of leChain:
    %*{"k": "chain", "t": sim.tickCount, "lane": lane,
       "n": event.col, "pts": event.amount}
  of leSaucer:
    %*{"k": "saucer", "t": sim.tickCount, "lane": lane, "pts": event.amount}
  of leNearMiss:
    %*{"k": "near_miss", "t": sim.tickCount, "lane": lane, "id": event.amount}
  of leLifeLost:
    %*{"k": "life_lost", "t": sim.tickCount, "lane": lane,
       "livesLeft": event.amount, "by": event.detail}
  of leScreenClear:
    %*{"k": "screen_clear", "t": sim.tickCount, "lane": lane,
       "screen": event.col, "bonus": event.amount}
  of leRecord:
    %*{"k": "record", "t": sim.tickCount, "lane": lane,
       "points": event.amount, "par": event.col}
  of leLaneOver:
    %*{"k": "lane_over", "t": sim.tickCount, "lane": lane,
       "points": event.amount, "tick": event.col}
  of leNone:
    newJNull()

proc applyControlRecord*(sim: var SimServer, record: string) =
  ## Re-applies ONE replay control record. Everything here lands in
  ## NON-HASHED state — the feed, the stance chips, the per-seat counters —
  ## with exactly one exception: `stopped`, which is hashed and goes through
  ## the SAME `recordStop` the live server called, because a wall-clock fact
  ## cannot be re-derived from sim state and recording the hash of a state
  ## playback cannot reproduce mismatches every deadline-ended replay.
  if record.len == 0 or record[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  case node{"k"}.getStr()
  of "stopped":
    sim.recordStop(node{"tick"}.getInt())
  of "register":
    let seat = node{"seat"}.getInt()
    if seat >= 0 and seat <= 3:
      sim.seatPolicyKind[seat] = node{"kind"}.getStr()
    sim.pushFeedRecord(record)
  of "stance":
    let seat = node{"seat"}.getInt()
    if seat >= 0 and seat <= 3:
      sim.seatMode[seat] = node{"mode"}.getStr()
      sim.seatZone[seat] = node{"zone"}.getStr()
      sim.seatSay[seat] = node{"say"}.getStr()
      sim.seatSayUntil[seat] = sim.tickCount + 60
      if node{"source"}.getStr() == "llm":
        inc sim.llmTurns[seat]
      elif node{"source"}.getStr() == "fallback":
        inc sim.fallbackTurns[seat]
    sim.pushFeedRecord(record)
  of "fallback", "budget_guard", "result":
    sim.pushFeedRecord(record)
  else:
    discard

proc step*(sim: var SimServer, cmds: openArray[uint8]) =
  ## One tick of the whole cabinet. `cmds` is one ACTION BYTE per seat, in
  ## seat order — the same bytes the replay records and the wasm viewer
  ## replays.
  case sim.phase
  of Lobby:
    inc sim.lobbyTicks
    inc sim.tickCount
    if sim.players.len >= max(1, sim.config.minPlayers):
      if sim.startCountdown > 0:
        dec sim.startCountdown
      if sim.startCountdown <= 0:
        sim.startGame()
    return
  of GameOver:
    inc sim.tickCount
    if sim.gameOverHold > 0:
      dec sim.gameOverHold
    return
  of Playing:
    discard

  let parScore = sim.config.preset.parScore
  for seat in 0 ..< 4:
    let cmd = (if seat < cmds.len: cmds[seat] else: 0'u8)
    let events = stepLane(
      sim.lanes[seat], cmd, sim.config.preset, sim.tickCount, parScore)
    for event in events:
      let kind =
        case event.kind
        of lePickup: Pickup
        of leChip: Chip
        of leBunker: Bunker
        of leChain: Chain
        of leSaucer: Saucer
        of leNearMiss: NearMiss
        of leLifeLost: LifeLost
        of leScreenClear: ScreenClear
        of leRecord: Record
        of leLaneOver: LaneOver
        of leNone: PhaseChange
      sim.emitEvent(kind, lane = seat, amount = int(event.amount),
                    col = int(event.col), row = int(event.row),
                    detail = event.detail)
  inc sim.tickCount

  # 6 end checks, in this exact order --------------------------------------
  if sim.stopped:
    sim.finishGame(ReasonDeadline, EndRuleWallClock)
    return
  if sim.gameTicksElapsed() >= sim.config.minTicks and sim.allLanesOver():
    sim.finishGame(ReasonComplete, EndRuleAllLanesOver)
    return
  if sim.gameTicksElapsed() >= sim.config.maxTicks:
    sim.finishGame(ReasonComplete, EndRuleFullTime)

proc stepEventsFor*(
  sim: var SimServer, cmds: openArray[uint8]
): JsonNode =
  ## `step` plus the JSON the broadcast channel derives from it. Used by the
  ## tests and the offline tools; the live server derives its events from the
  ## broadcast tracker instead, so both paths tell the same story.
  result = newJArray()
  let before = sim.phase
  var perLane: array[4, seq[LaneEvent]]
  if sim.phase == Playing:
    let parScore = sim.config.preset.parScore
    for seat in 0 ..< 4:
      let cmd = (if seat < cmds.len: cmds[seat] else: 0'u8)
      perLane[seat] = stepLane(
        sim.lanes[seat], cmd, sim.config.preset, sim.tickCount, parScore)
    inc sim.tickCount
    if sim.stopped:
      sim.finishGame(ReasonDeadline, EndRuleWallClock)
    elif sim.gameTicksElapsed() >= sim.config.minTicks and sim.allLanesOver():
      sim.finishGame(ReasonComplete, EndRuleAllLanesOver)
    elif sim.gameTicksElapsed() >= sim.config.maxTicks:
      sim.finishGame(ReasonComplete, EndRuleFullTime)
  else:
    sim.step(cmds)
  for seat in 0 ..< 4:
    for event in perLane[seat]:
      let node = sim.laneEventJson(seat, event)
      if node.kind != JNull:
        result.add(node)
  if before != sim.phase:
    result.add(%*{"k": "phase", "t": sim.tickCount,
                  "ph": ($sim.phase).toLowerAscii})

proc laneIsOver*(sim: SimServer, seat: int): bool {.inline.} =
  seat >= 0 and seat < 4 and sim.lanes[seat].phase == lpOver

proc screenMap*(lane: Lane): array[GridH, string] =
  ## The 17-line ASCII screen a policy reads. Exactly 17 strings of 17
  ## characters, always.
  for row in 0 ..< GridH:
    var line = newString(GridW)
    for col in 0 ..< GridW:
      line[col] = tileGlyph(tileAt(lane, col, row))
    result[row] = line
  for sprite in lane.sprites:
    if not sprite.alive:
      continue
    let
      col = int(colOf(sprite.x))
      row = int(rowOf(sprite.y))
    if inGrid(col, row):
      result[row][col] = glyphFor(sprite)
  let
    acol = int(colOf(lane.ax))
    arow = int(rowOf(lane.ay))
  if inGrid(acol, arow):
    result[arow][acol] = '@'
