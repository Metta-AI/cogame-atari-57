## The autopilot: one deterministic function that turns a standing stance into
## a per-tick action byte, at 24 Hz, for every ROM and every policy kind.
##
## Replaces `coworld-ctf`'s `src/ctf/control.nim` (nav grid, flow fields, aim)
## with ~1 bounded BFS and no cached fields. What is INHERITED is the
## architecture: the autopilot sits OUTSIDE the determinism boundary exactly
## as ctf's control layer does — the byte it produces is what the replay
## records and what the wasm viewer replays, so this code may use floats and
## is never re-run at playback.
##
## Both LLM stances and scripted-baseline stances are compiled by THIS code,
## which is what makes the two policy kinds strictly comparable and a
## baseline legal by construction.
##
## Its inputs are structurally limited to ONE lane's state, that lane's own
## stance and the tick (`tests/test_isolation.nim` asserts the signature
## cannot see more). The only memory it keeps is its own commit window.

import std/[math]
import sim, stances, observation

type
  ControlLane* = object
    ## One lane's commit window. Not hashed, not serialized into keyframes,
    ## and never read by the sim.
    haveCommit*: bool
    commitCol*, commitRow*: int32
    commitUntil*: int

proc initControlLane*(): ControlLane =
  ControlLane(haveCommit: false, commitCol: -1, commitRow: -1, commitUntil: -1)

proc dangerThreshold(stance: LaneStance): int32 =
  ## A candidate move is rejected outright if it enters a tile whose
  ## `threatEta` is below this. `risk = 0` never lets a threat within four
  ## tiles; `risk = 1` ignores threats entirely.
  int32((1.0 - stance.risk()) * 96.0 + 4.0)

proc weightOf(
  target: Target, stance: LaneStance, threatEta: int32, preset: RomPreset
): float =
  ## The stance's own weighting of one target.
  let
    value = float(target.value)
    dist = float(max(1'i32, target.distTicks))
  var w =
    case stance.mode
    of mdClear: value / dist
    of mdHunt, mdStrike: pow(value, 1.5) / dist
    of mdSafe, mdBank:
      value / dist * min(1.0, float(min(threatEta, FarEta)) / 48.0)
  if stance.mode == mdStrike:
    # `strike` is the cash-in stance: the chain in chomper, the top two brick
    # rows in brickfall, the densest flank in gallery.
    case preset.rom
    of RomChomper:
      if target.kind == "fleeing_hunter": w *= 3.0
    of RomBrickfall:
      if target.row <= 4: w *= 3.0
    else:
      if target.kind == "saucer" or target.row <= 3: w *= 3.0
  if stance.zone != znNone and not zoneMatches($stance.zone, target.zone):
    w *= 0.35
  w

proc bestTarget(
  lane: Lane, preset: RomPreset, stance: LaneStance,
  targets: seq[Target], field: array[GridCells, int32]
): tuple[found: bool, col, row: int32] =
  result = (false, 0'i32, 0'i32)
  var best = -1.0
  for target in targets:
    if not inGrid(int(target.col), int(target.row)):
      continue
    let idx = tileIndex(int(target.col), int(target.row))
    if stance.mode == mdBank and field[idx] < 24'i32:
      continue                    ## `bank` refuses every trade.
    let w = weightOf(target, stance, field[idx], preset)
    if w > best:
      best = w
      result = (true, target.col, target.row)

proc predictBallCross*(lane: Lane, preset: RomPreset): tuple[found: bool, x: int32] =
  ## Where the ball will cross the paddle row, in MICRO-UNITS, by stepping a
  ## copy of it forward with the same integer reflection rules the sim uses.
  ## Micro-units rather than a column because the whole point of the paddle
  ## is WHICH SEVENTH of it the ball strikes, and a tile-resolution answer
  ## cannot express that — a ball and a clamped paddle can sit in a stable
  ## straight-up-and-down loop forever if the aim is quantised to tiles.
  ## Bounded at 240 iterations: no unbounded loop lives anywhere here.
  result = (false, lane.ax)
  if lane.sprites.len == 0 or lane.sprites[0].kind != skBall:
    return
  var ball = lane.sprites[0]
  if ball.state == ssServing:
    return (true, ball.x)
  var
    x = ball.x
    y = ball.y
    vx = scaleVelocity(ball.vx, lane.speedPermille)
    vy = scaleVelocity(ball.vy, lane.speedPermille)
  let targetY = lane.ay
  for _ in 0 ..< 240:
    x += vx
    y += vy
    if x < BallHalf:
      x = BallHalf
      vx = -vx
    elif x > LaneSpanU - BallHalf:
      x = LaneSpanU - BallHalf
      vx = -vx
    if y < BallHalf:
      y = BallHalf
      vy = -vy
    if vy > 0 and y >= targetY:
      return (true, x)
  result = (true, x)

proc railCommand(
  ctl: var ControlLane, lane: Lane, stance: LaneStance, preset: RomPreset,
  tick: int, targets: seq[Target], field: array[GridCells, int32]
): uint8 =
  ## `railBottom`: the whole route is the sign of the difference between the
  ## paddle centre and a desired column.
  var desiredU = lane.ax
  let best = bestTarget(lane, preset, stance, targets, field)
  if preset.rom == RomBrickfall:
    let predicted = predictBallCross(lane, preset)
    if predicted.found:
      # Aim the return by choosing WHICH SEVENTH of the paddle the ball must
      # strike, then placing the paddle so that seventh lands under it. The
      # ends fan the ball steeply sideways; the middle sends it straight up.
      var wanted = BallFan.len div 2
      if best.found:
        let
          targetX = best.col * TileU + HalfTileU
          delta = targetX - predicted.x
        var spread = delta div (2 * TileU)
        if spread == 0 and delta != 0:
          spread = (if delta > 0: 1'i32 else: -1'i32)
        wanted += int(clamp(spread, -3'i32, 3'i32))
      wanted = clamp(wanted, 0, BallFan.high)
      # Index 3 is dead vertical, and a dead-vertical return near a side wall
      # is a STALL: the ball goes straight up, comes straight back down on the
      # same column, and the paddle — clamped at its own travel limit — can
      # only reproduce the same impact seventh forever. So the paddle picks
      # the nearest seventh it can actually REACH that is not the middle one.
      var chosen = -1
      for step in 0 .. BallFan.high:
        for sign in [1, -1]:
          let cand = wanted + step * sign
          if cand < 0 or cand > BallFan.high or cand == BallFan.len div 2:
            continue
          let offset = int32(
            (int64(2 * cand + 1) * int64(2 * PaddleHalfU)) div 14'i64)
          let u = clamp(predicted.x - offset + PaddleHalfU,
                        PaddleHalfU, LaneSpanU - PaddleHalfU)
          let achieved = clamp(
            int((int64(predicted.x - (u - PaddleHalfU)) * int64(BallFan.len)) div
              int64(2 * PaddleHalfU)), 0, BallFan.high)
          if achieved != BallFan.len div 2:
            desiredU = u
            chosen = cand
            break
          if step == 0:
            break
        if chosen >= 0:
          break
      if chosen < 0:
        let offset = int32(
          (int64(2 * wanted + 1) * int64(2 * PaddleHalfU)) div 14'i64)
        desiredU = predicted.x - offset + PaddleHalfU
    else:
      desiredU = LaneSpanU div 2
  else:
    if best.found:
      desiredU = best.col * TileU + HalfTileU
    # The danger gate, applied in EVERY mode: a hostile bolt already falling
    # down this column is the one thing on a gallery screen that kills you,
    # and a paddle that only dodges in `safe` dies with a full magazine. How
    # early it fires is what `risk` buys: 0 steps aside a whole second out,
    # 1 stands in the beam.
    let dodgeEta = int32((1.0 - stance.risk()) * 40.0 + 24.0)
    for sprite in lane.sprites:
      if sprite.kind != skBoltHostile or not sprite.alive:
        continue
      if abs(int(sprite.x - lane.ax)) > PaddleHalfU + TileU:
        continue
      let eta = (lane.ay - sprite.y) div max(1'i32, sprite.vy)
      if eta < 0 or eta > dodgeEta:
        continue
      let room = LaneSpanU - PaddleHalfU - lane.ax
      desiredU =
        if room > lane.ax - PaddleHalfU:
          lane.ax + PaddleHalfU + TileU
        else:
          lane.ax - PaddleHalfU - TileU
      break
  desiredU = clamp(desiredU, PaddleHalfU, LaneSpanU - PaddleHalfU)
  let current = lane.ax
  var dir = 0'i32
  if desiredU > current + (preset.avatarSpeed div 2): dir = 4
  elif desiredU < current - (preset.avatarSpeed div 2): dir = 3
  let desired = colOf(desiredU)
  var act = 0'i32
  if preset.fireEnabled:
    case stance.fire
    of fmAuto:
      act = 1
    of fmHold:
      if best.found and abs(int(best.col - current)) <= 0:
        act = 1
    of fmNever:
      act = 0
  ctl.haveCommit = best.found
  ctl.commitCol = (if best.found: best.col else: -1)
  ctl.commitRow = (if best.found: best.row else: -1)
  ctl.commitUntil = tick + int(min(stance.leadTicks, 48'i32))
  encodeAction(dir, act)

proc freeGridCommand(
  ctl: var ControlLane, lane: Lane, stance: LaneStance, preset: RomPreset,
  tick: int, targets: seq[Target], field: array[GridCells, int32]
): uint8 =
  ## `freeGrid`: pick a target, walk its first step, and refuse any step into
  ## a tile a threat can reach too soon.
  let
    acol = int(colOf(lane.ax))
    arow = int(rowOf(lane.ay))
  var goal = (found: false, col: 0'i32, row: 0'i32)
  # The commit window: hold the chosen route for `lead_ticks` unless the
  # danger gate rejects it, in which case it is re-planned immediately.
  if ctl.haveCommit and tick < ctl.commitUntil and
      inGrid(int(ctl.commitCol), int(ctl.commitRow)):
    let idx = tileIndex(int(ctl.commitCol), int(ctl.commitRow))
    let stillWorth =
      case preset.rom
      of RomChomper:
        tileAt(lane, int(ctl.commitCol), int(ctl.commitRow)) in
          {tlPellet, tlPower}
      else: true
    if stillWorth and field[idx] >= dangerThreshold(stance):
      goal = (true, ctl.commitCol, ctl.commitRow)
  if not goal.found:
    goal = bestTarget(lane, preset, stance, targets, field)
    if goal.found:
      ctl.haveCommit = true
      ctl.commitCol = goal.col
      ctl.commitRow = goal.row
      ctl.commitUntil = tick + int(max(1'i32, min(stance.leadTicks, 48'i32)))
    else:
      ctl.haveCommit = false

  let toGoal =
    if goal.found: walkDistances(lane, int(goal.col), int(goal.row))
    else: walkDistances(lane, acol, arow)
  let threshold = dangerThreshold(stance)
  var
    bestDir = 0'i32
    bestScore = -1.0e18
  for d in 0'i32 .. 4'i32:
    let v = dirVector(d)
    var ncol = acol + int(v.dx)
    let nrow = arow + int(v.dy)
    if arow == tunnelRow() and v.dy == 0:
      if ncol < 0: ncol = GridW - 1
      elif ncol >= GridW: ncol = 0
    if d != 0:
      if not inGrid(ncol, nrow) or not isWalkable(tileAt(lane, ncol, nrow)):
        continue
    let idx = tileIndex(
      (if d == 0: acol else: ncol), (if d == 0: arow else: nrow))
    let eta = field[idx]
    var score = 0.0
    # Closer to the goal is better; the tunnel-aware BFS already knows the
    # true walk distance, so this needs no geometry.
    let steps = toGoal[idx]
    score = (if steps < 0: -1000.0 else: -float(steps))
    if eta < threshold:
      score -= 1.0e6 - float(eta)     ## rejected, but still ORDERED, so the
                                      ## least-dangerous move survives when
                                      ## every move is rejected.
    if d == 0:
      score -= 0.5                    ## standing still is never preferred.
    if score > bestScore:
      bestScore = score
      bestDir = d

  var act = 0'i32
  if preset.brakeEnabled and
      (stance.mode == mdSafe or stance.mode == mdBank):
    var nearest = FarEta
    if inGrid(acol, arow):
      nearest = field[tileIndex(acol, arow)]
    if nearest >= 8'i32 and nearest <= 24'i32:
      act = 2                         ## let the hunter commit first.
  encodeAction(bestDir, act)

proc laneCommand*(
  ctl: var ControlLane,
  lane: Lane,
  stance: LaneStance,
  preset: RomPreset,
  tick: int
): uint8 =
  ## The one action byte for one lane on one tick. `0` whenever the lane is
  ## not `Playing`, so a dying, respawning or finished lane is never
  ## commanded.
  if lane.phase != lpPlaying:
    return 0'u8
  let
    field = threatField(lane, preset)
    targets = laneTargets(lane, preset)
  if preset.avatarMode == amRailBottom:
    railCommand(ctl, lane, stance, preset, tick, targets, field)
  else:
    freeGridCommand(ctl, lane, stance, preset, tick, targets, field)
