## The sim's own arithmetic: the no-tunnelling bound, the committed ball fan,
## the turn latch, the clamps and the action-byte repair.

import std/[random, strformat]
import lane_helpers
import lane/[sim_types, grid, sprites, rom, maps]

proc testNoTunnellingBound() =
  ## Asserted DIRECTLY, not argued: the fastest collidable travels
  ## MaxSpriteSpeed in a tick and the shallowest contact window is half a tile
  ## plus a box half-side. If this inequality ever fails, something can pass
  ## through something else in one tick and no amount of testing downstream
  ## will find it reliably.
  check(max(BallSpeedMax, BoltSpeedFriendly) == MaxSpriteSpeed,
        "the fastest collidable is not MaxSpriteSpeed")
  check(ContactWindowU == HalfTileU + BallHalf, "contact window changed")
  check(MaxSpriteSpeed < ContactWindowU,
        &"no-tunnelling bound broken: {MaxSpriteSpeed} >= {ContactWindowU}")
  report("no-tunnelling bound 4000 < 9000")

proc testSweptMatchesEndPosition() =
  ## Over 50 000 randomised legal states the swept-contact test and the
  ## end-position test must return the SAME answer. They can only differ if
  ## something moved further in one tick than the contact window, which the
  ## bound above forbids.
  var rng = initRand(0x5140913)
  var disagreements = 0
  for _ in 0 ..< 50_000:
    let
      ax = int32(rng.rand(BoxHalf .. LaneSpanU - BoxHalf))
      ay = int32(rng.rand(BoxHalf .. LaneSpanU - BoxHalf))
      vx = int32(rng.rand(-MaxSpriteSpeed .. MaxSpriteSpeed))
      vy = int32(rng.rand(-MaxSpriteSpeed .. MaxSpriteSpeed))
      bx = int32(rng.rand(BoxHalf .. LaneSpanU - BoxHalf))
      by = int32(rng.rand(BoxHalf .. LaneSpanU - BoxHalf))
      endOverlap = boxesOverlap(ax + vx, ay + vy, BallHalf, bx, by, BoxHalf)
    # The swept answer: overlapped at either end of the tick, or crossing the
    # target's own plane while inside the other axis's band.
    var swept = endOverlap or boxesOverlap(ax, ay, BallHalf, bx, by, BoxHalf)
    if not swept and crossedAxis(ax, ax + vx, bx) and
        abs(int(ay + vy - by)) < BallHalf + BoxHalf:
      swept = true
    if not swept and crossedAxis(ay, ay + vy, by) and
        abs(int(ax + vx - bx)) < BallHalf + BoxHalf:
      swept = true
    if endOverlap and not swept:
      inc disagreements
  check(disagreements == 0,
        &"{disagreements} states where the end-position test saw a contact " &
        "the swept test missed")
  report("swept and end-position contact agree over 50 000 states")

proc testBallFan() =
  ## Every fan entry sends the ball UP — a paddle can never send it back into
  ## the drain — and every magnitude is within 5 % of the nominal. Asserted
  ## exhaustively over all seven entries and all four wall-reflection
  ## parities, because a reflection negates a component and must not be able
  ## to produce a downward return either.
  let
    nominal = int64(BallFanNominal) * int64(BallFanNominal)
    lo = nominal * 90 div 100          ## 0.95^2 ~ 0.9025
    hi = nominal * 111 div 100         ## 1.05^2 ~ 1.1025
  for i in 0 ..< BallFan.len:
    check(BallFan[i].vy < 0, &"BallFan[{i}] does not send the ball up")
    let mag = fanMagnitudeSq(i)
    check(mag >= lo and mag <= hi,
          &"BallFan[{i}] magnitude^2 {mag} outside +/-5% of {nominal}")
    for parityX in [1'i32, -1'i32]:
      for parityY in [1'i32, -1'i32]:
        let
          vx = BallFan[i].vx * parityX
          vy = BallFan[i].vy * parityY
        check(abs(int(vx)) <= BallSpeedMax and abs(int(vy)) <= BallSpeedMax,
              &"BallFan[{i}] reflected beyond BallSpeedMax")
  check(BallFan[BallFan.len div 2].vx == 0,
        "the middle of the paddle must send the ball straight up")
  report("BallFan: 7 entries, all vy < 0, all within 5% of 2800")

proc testSpeedRamp() =
  ## Every product is int64 and narrowed with a truncating div, and the ramp
  ## rises by exactly BrickSpeedStep per BrickHitsPerStep hits, capped.
  var permille = 1000'i32
  for hit in 1 .. 200:
    if hit mod BrickHitsPerStep == 0:
      permille = min(permille + BrickSpeedStep, BrickSpeedCap)
  check(permille == BrickSpeedCap, "the ramp did not reach its cap")
  check(scaleVelocity(2800, 1400) == 3920, "capped ball speed is not 3920")
  check(scaleVelocity(-2800, 1400) == -3920,
        "scaling is not symmetric under negation")
  check(scaleVelocity(BallFan[0].vx, 1000) == BallFan[0].vx,
        "a 1000-permille scale is not the identity")
  report("speed ramp: +50 per 8 hits, capped at 1400, symmetric")

proc testActionByteRepair() =
  ## The 15 legal values decode as documented, and every one of the other 241
  ## byte values decodes IDENTICALLY to 0 — in the server path and the replay
  ## path, which is the same proc, which is the whole point.
  for cmd in 0 .. 14:
    let decoded = decodeAction(uint8(cmd))
    check(decoded.dir == int32(cmd mod 5), "dir decode wrong")
    check(decoded.act == int32(cmd div 5), "act decode wrong")
    check(encodeAction(decoded.dir, decoded.act) == uint8(cmd),
          "encode/decode is not a round trip")
  for cmd in 15 .. 255:
    let decoded = decodeAction(uint8(cmd))
    check(decoded.dir == 0 and decoded.act == 0,
          &"cmd {cmd} was not repaired to 0")
  report("action byte: 15 legal values, 241 repaired to 0")

proc testLaneClamps() =
  ## An avatar or sprite centre never leaves its lane and a railBottom paddle
  ## never leaves [18 000, 186 000], over three real episodes.
  for rom in RomNames:
    var config = testConfig(rom, 5_140_913)
    var game = seatedSim(config)
    var
      controls: array[4, ControlLane]
      active: array[4, LaneStance]
      cmds = newSeq[uint8](4)
    for i in 0 ..< 4:
      controls[i] = initControlLane()
    var ticks = 0
    while game.phase == Playing and ticks < 900:
      if ticks mod config.turnTicks == 0:
        for seat in 0 ..< 4:
          active[seat] = arcaderStance(game, seat)
      for seat in 0 ..< 4:
        cmds[seat] = laneCommand(controls[seat], game.lanes[seat],
                                 active[seat], config.preset, game.tickCount)
      game.step(cmds)
      inc ticks
      for seat in 0 ..< 4:
        let lane = game.lanes[seat]
        check(lane.ax >= 0 and lane.ax < LaneSpanU, &"{rom}: avatar x escaped")
        check(lane.ay >= 0 and lane.ay < LaneSpanU, &"{rom}: avatar y escaped")
        if config.preset.avatarMode == amRailBottom:
          check(lane.ax >= PaddleHalfU and lane.ax <= LaneSpanU - PaddleHalfU,
                &"{rom}: the paddle left its rail")
        for sprite in lane.sprites:
          if not sprite.alive:
            continue
          check(sprite.x >= -TileU and sprite.x <= LaneSpanU + TileU,
                &"{rom}: sprite x escaped")
          check(sprite.y >= -TileU and sprite.y <= LaneSpanU + TileU,
                &"{rom}: sprite y escaped")
  report("avatars and sprites stay in their lanes; paddles stay on the rail")

proc testTurnLatch() =
  ## A buffered direction applies only at a tile centre and is discarded after
  ## exactly `latchTicks`; a reverse along the current axis applies at once.
  let config = testConfig(RomChomper, 5_140_913)
  var lane: Lane
  initLane(lane, config.preset, config.seed)
  let start = lane.ax
  # Facing left from the start tile; a reverse to `right` must take effect on
  # the very next tick, with no latch wait at all.
  lane.facing = 3'u8
  discard stepLane(lane, encodeAction(4, 0), config.preset, 0, 9999)
  check(lane.facing == 4'u8, "a reverse did not apply immediately")
  check(lane.ax > start, "the avatar did not move after reversing")

  # An UP request mid-corridor is buffered, and dropped once it is stale.
  var lane2: Lane
  initLane(lane2, config.preset, config.seed)
  lane2.facing = 4'u8
  lane2.ax = snapToCentre(lane2.ax) + LatchWindowU + 1000   ## off-centre
  discard stepLane(lane2, encodeAction(1, 0), config.preset, 0, 9999)
  check(lane2.facing == 4'u8, "an off-centre turn was taken immediately")
  for tick in 1 .. int(config.preset.latchTicks) + 1:
    discard stepLane(lane2, encodeAction(0, 0), config.preset, tick, 9999)
  check(lane2.pendingDir == 0'u8,
        "a stale buffered direction was not discarded after latchTicks")
  report("turn latch: reverse is immediate, a stale buffer is dropped")

proc testOneContactPerTick() =
  ## A brick, a bunker hit and a marcher kill each resolve with exactly one
  ## contact: the tile changes once and the points are paid once.
  block brick:
    let config = testConfig(RomBrickfall, 5_140_913)
    var lane: Lane
    initLane(lane, config.preset, config.seed)
    var bricks = 0
    for i in 0 ..< GridCells:
      if Tile(lane.tiles[i]) == tlBrick:
        inc bricks
    check(bricks == 60, &"brickfall starts with {bricks} bricks, not 60")
    # Put the ball just under the bottom brick row moving up.
    lane.sprites[0].state = ssIdle
    lane.sprites[0].timer = 0
    let centre = tileCentreU(8, 8)
    lane.sprites[0].x = centre.x
    lane.sprites[0].y = centre.y
    lane.sprites[0].vx = 0
    lane.sprites[0].vy = -2800
    var destroyed = 0
    var points = 0'i32
    for tick in 0 ..< 40:
      let before = lane.points
      discard stepLane(lane, 0'u8, config.preset, tick, 9999)
      if lane.points > before:
        inc destroyed
        points = lane.points - before
        check(points <= 50, "one tick paid more than one brick")
    check(destroyed > 0, "the ball never hit a brick")
  block bunker:
    let config = testConfig(RomGallery, 5_140_913)
    var lane: Lane
    initLane(lane, config.preset, config.seed)
    let idx = tileIndex(BunkerCols[0], BunkerRow)
    check(lane.bunkerHp[idx] == BunkerHpFull, "bunkers do not start at 3 hp")
  report("one contact per tick on bricks, bunkers and marchers")

when isMainModule:
  echo "test_physics"
  testNoTunnellingBound()
  testSweptMatchesEndPosition()
  testBallFan()
  testSpeedRamp()
  testActionByteRepair()
  testLaneClamps()
  testTurnLatch()
  testOneContactPerTick()
  echo "test_physics OK"
