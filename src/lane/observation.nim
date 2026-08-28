## The per-seat board view: the threat field, the target set, the five zone
## summaries, the cross-lane scoreboard strip, and the JSON object that is
## the tail of every LLM user message.
##
## New in this coworld (paintbot composed its seat view inside `decide.nim`
## from the arena's fog). It lives in its own module for one reason: the
## autopilot and the observation must compute the target set with the SAME
## routine, so a policy is never guessing at a quantity the engine already
## knows (the escrow 0.1.3 lesson). `control.nim` imports this module and
## calls `laneTargets` / `threatField` directly.
##
## THE ONLY CROSS-LANE READ IN THE WHOLE PROGRAM happens here, in
## `scoreboardJson`, and it carries exactly four fields per rival: alias,
## score, lives, screen. It is composed OUTSIDE `stepLane` and is never read
## back by the sim, which is what `tests/test_isolation.nim` asserts.

import std/[algorithm, json, math]
import sim, stances

type
  Threat* = object
    id*: string
    kind*: string
    state*: string
    col*, row*: int32
    etaTicks*: int32
    distTiles*: float

  Target* = object
    kind*: string
    col*, row*: int32
    value*: int32
    distTicks*: int32
    zone*: string
    safe*: bool

const
  FarEta* = 9_999'i32

proc ticksPerTile(sprite: LaneSprite, permille: int32): int32 =
  ## How long one hostile needs to cross one tile, in ticks. Integer, and
  ## never zero.
  let speed =
    case sprite.kind
    of skChaser: max(1'i32, chaserSpeed(sprite, permille))
    of skBall: max(1'i32, scaleVelocity(BallFanNominal, permille))
    of skBoltHostile: BoltSpeedHostile
    of skMarcher: max(1'i32, TileU div max(1'i32, 20'i32))
    else: 1_000'i32
  max(1'i32, TileU div speed)

proc threatField*(lane: Lane, preset: RomPreset): array[GridCells, int32] =
  ## `threatEta[tile]` = the fewest ticks in which some hostile can occupy
  ## that tile. A breadth-first walk over the lane's walkable tiles from every
  ## hostile sprite, **bounded at `BfsNodeCap` nodes per source** — the
  ## degrade-never-hang rule applies to the autopilot too.
  for i in 0 ..< GridCells:
    result[i] = FarEta
  var
    queue: array[GridCells, int32]
    dist: array[GridCells, int32]
  for sprite in lane.sprites:
    if not isHostile(sprite):
      continue
    let
      startCol = int(colOf(sprite.x))
      startRow = int(rowOf(sprite.y))
    if not inGrid(startCol, startRow):
      continue
    for i in 0 ..< GridCells:
      dist[i] = -1
    var
      head = 0
      tail = 0
      visited = 0
    let startIdx = tileIndex(startCol, startRow)
    dist[startIdx] = 0
    queue[tail] = int32(startIdx)
    inc tail
    let perTile = ticksPerTile(sprite, lane.speedPermille)
    while head < tail and visited < BfsNodeCap:
      let idx = int(queue[head])
      inc head
      inc visited
      let
        col = idx mod GridW
        row = idx div GridW
        eta = dist[idx] * perTile
      if eta < result[idx]:
        result[idx] = eta
      for d in 1'i32 .. 4'i32:
        let v = dirVector(d)
        var ncol = col + int(v.dx)
        let nrow = row + int(v.dy)
        if row == tunnelRow() and v.dy == 0:
          if ncol < 0: ncol = GridW - 1
          elif ncol >= GridW: ncol = 0
        if not inGrid(ncol, nrow):
          continue
        if not isWalkable(tileAt(lane, ncol, nrow)):
          continue
        let nidx = tileIndex(ncol, nrow)
        if dist[nidx] >= 0:
          continue
        dist[nidx] = dist[idx] + 1
        if tail < GridCells:
          queue[tail] = int32(nidx)
          inc tail

proc walkDistances*(lane: Lane, fromCol, fromRow: int): array[GridCells, int32] =
  ## Tile-steps from one tile to every reachable tile, bounded the same way.
  ## `-1` means unreachable (or past the node cap).
  for i in 0 ..< GridCells:
    result[i] = -1
  if not inGrid(fromCol, fromRow):
    return
  var
    queue: array[GridCells, int32]
    head = 0
    tail = 0
    visited = 0
  let startIdx = tileIndex(fromCol, fromRow)
  result[startIdx] = 0
  queue[tail] = int32(startIdx)
  inc tail
  while head < tail and visited < BfsNodeCap:
    let idx = int(queue[head])
    inc head
    inc visited
    let
      col = idx mod GridW
      row = idx div GridW
    for d in 1'i32 .. 4'i32:
      let v = dirVector(d)
      var ncol = col + int(v.dx)
      let nrow = row + int(v.dy)
      if row == tunnelRow() and v.dy == 0:
        if ncol < 0: ncol = GridW - 1
        elif ncol >= GridW: ncol = 0
      if not inGrid(ncol, nrow):
        continue
      if not isWalkable(tileAt(lane, ncol, nrow)):
        continue
      let nidx = tileIndex(ncol, nrow)
      if result[nidx] >= 0:
        continue
      result[nidx] = result[idx] + 1
      if tail < GridCells:
        queue[tail] = int32(nidx)
        inc tail

proc laneThreats*(lane: Lane, preset: RomPreset): seq[Threat] =
  ## Every hostile sprite in the lane, sorted by `eta_ticks` ascending.
  let field = threatField(lane, preset)
  for sprite in lane.sprites:
    if not isHostile(sprite):
      continue
    let
      col = colOf(sprite.x)
      row = rowOf(sprite.y)
      dx = float(lane.ax - sprite.x) / float(TileU)
      dy = float(lane.ay - sprite.y) / float(TileU)
    var eta = FarEta
    let acol = int(colOf(lane.ax))
    let arow = int(rowOf(lane.ay))
    if inGrid(acol, arow):
      eta = field[tileIndex(acol, arow)]
    result.add(Threat(
      id: spriteLabel(sprite),
      kind: spriteKindText(sprite),
      state: spriteStateText(sprite),
      col: col,
      row: row,
      etaTicks: eta,
      distTiles: round(sqrt(dx * dx + dy * dy) * 100.0) / 100.0
    ))
  result.sort(proc (a, b: Threat): int = cmp(a.etaTicks, b.etaTicks))

proc avatarTicksPerTile(preset: RomPreset): int32 {.inline.} =
  max(1'i32, TileU div max(1'i32, preset.avatarSpeed))

proc laneTargets*(lane: Lane, preset: RomPreset): seq[Target] =
  ## Every scoring thing currently on the screen, each with
  ## `(value, distTicks, zone, safe)`. **This is exactly the array the
  ## observation publishes as `targets` and exactly the array the autopilot
  ## weights**, which is what stops a policy and the executor disagreeing
  ## about what is reachable.
  let
    acol = int(colOf(lane.ax))
    arow = int(rowOf(lane.ay))
    steps = walkDistances(lane, acol, arow)
    perTile = avatarTicksPerTile(preset)
    threats = threatField(lane, preset)

  template push(tKind: string, tCol, tRow: int, tValue: int32) =
    block pushTarget:
      if not inGrid(tCol, tRow):
        break pushTarget
      let idx = tileIndex(tCol, tRow)
      let walked = steps[idx]
      result.add(Target(
        kind: tKind,
        col: int32(tCol), row: int32(tRow),
        value: tValue,
        distTicks: (if walked < 0: FarEta else: walked * perTile),
        zone: zoneOfTile(tCol, tRow),
        safe: threats[idx] >= 48'i32
      ))

  case preset.rom
  of RomChomper:
    # Pellets are clustered by tile so the list stays inside its 12-entry cap
    # while still naming every part of the maze that is worth walking to.
    var clusters: seq[tuple[col, row: int, value: int32]]
    for row in 0 ..< GridH:
      for col in 0 ..< GridW:
        let t = tileAt(lane, col, row)
        if t == tlPower:
          push("power", col, row, PowerPoints)
        elif t == tlPellet:
          var merged = false
          for i in 0 ..< clusters.len:
            if abs(clusters[i].col - col) <= 2 and abs(clusters[i].row - row) <= 2:
              clusters[i].value += PelletPoints
              merged = true
              break
          if not merged:
            clusters.add((col, row, PelletPoints))
    for cluster in clusters:
      push("pellet_cluster", cluster.col, cluster.row, cluster.value)
    for sprite in lane.sprites:
      if sprite.kind == skChaser and sprite.alive and sprite.state == ssFleeing:
        push("fleeing_hunter", int(colOf(sprite.x)), int(rowOf(sprite.y)),
             chainPoints(lane.chain))
  of RomBrickfall:
    var rowValue: array[GridH, int32]
    var rowCol: array[GridH, int]
    for row in 0 ..< GridH:
      rowCol[row] = -1
    for row in 0 ..< GridH:
      for col in 0 ..< GridW:
        if tileAt(lane, col, row) == tlBrick:
          rowValue[row] += brickRowPoints(row)
          if rowCol[row] < 0:
            rowCol[row] = col
    for row in 0 ..< GridH:
      if rowValue[row] > 0:
        result.add(Target(
          kind: "brick_row",
          col: int32(rowCol[row]), row: int32(row),
          value: rowValue[row],
          distTicks: int32(abs(rowCol[row] - acol) * int(perTile)),
          zone: zoneOfTile(rowCol[row], row),
          safe: true))
  else:
    for sprite in lane.sprites:
      if not sprite.alive:
        continue
      let
        col = int(colOf(sprite.x))
        row = int(rowOf(sprite.y))
      if sprite.kind == skMarcher:
        result.add(Target(
          kind: "marcher",
          col: int32(col), row: int32(row),
          value: marcherRowPoints(row, int(lane.marchTopRow)),
          distTicks: int32(abs(col - acol) * int(perTile)),
          zone: zoneOfTile(col, row),
          safe: true))
      elif sprite.kind == skSaucer:
        result.add(Target(
          kind: "saucer",
          col: int32(col), row: int32(row),
          value: SaucerPoints,
          distTicks: int32(abs(col - acol) * int(perTile)),
          zone: zoneOfTile(col, row),
          safe: true))

  result.sort(proc (a, b: Target): int =
    let
      wa = float(a.value) / float(max(1'i32, a.distTicks))
      wb = float(b.value) / float(max(1'i32, b.distTicks))
    if wa > wb: -1 elif wa < wb: 1 else: cmp(a.col * 100 + a.row, b.col * 100 + b.row))
  if result.len > MaxTargets:
    result.setLen(MaxTargets)

proc zoneSummaries*(lane: Lane, preset: RomPreset): JsonNode =
  ## The five fixed regions with their total target value and the soonest a
  ## hostile can be in them.
  let
    targets = laneTargets(lane, preset)
    field = threatField(lane, preset)
  var
    value: array[5, int32]
    minEta: array[5, int32]
  const names = ["nw", "ne", "sw", "se", "centre"]
  for i in 0 ..< 5:
    minEta[i] = FarEta
  for target in targets:
    for i, name in names:
      if target.zone == name:
        value[i] += target.value
  for row in 0 ..< GridH:
    for col in 0 ..< GridW:
      let zone = zoneOfTile(col, row)
      for i, name in names:
        if zone == name:
          minEta[i] = min(minEta[i], field[tileIndex(col, row)])
  result = newJObject()
  for i, name in names:
    result[name] = %*{
      "value": value[i],
      "min_threat_eta": (if minEta[i] >= FarEta: -1 else: minEta[i])
    }

proc scoreboardJson*(sim: SimServer): JsonNode =
  ## The ENTIRE cross-lane surface: four rows of `{alias, score, lives,
  ## screen}` and nothing else. Composed here, outside `stepLane`, and never
  ## read back by the sim.
  result = newJArray()
  for seat in 0 ..< 4:
    result.add(%*{
      "alias": laneAlias(seat),
      "score": sim.laneScore(seat),
      "lives": int(sim.lanes[seat].lives),
      "screen": int(sim.lanes[seat].screen)
    })

proc legendJson(): JsonNode =
  %*{
    "#": "wall", ".": "pellet", ",": "eaten floor", "o": "power pellet",
    "@": "you", "H": "hunter chasing", "h": "hunter fleeing",
    "r": "hunter returning", "=": "brick", "B": "ball", "_": "paddle",
    "A": "marcher", "S": "saucer", "X": "bunker", "^": "your bolt",
    "v": "enemy bolt", " ": "tunnel mouth"
  }

proc laneStateText(lane: Lane): string =
  case lane.phase
  of lpPlaying: "running"
  of lpDying: "dying"
  of lpRespawning: "respawning"
  of lpOver: "over"

proc laneViewJson*(
  sim: SimServer,
  seat, turnIndex, turnsPerEpisode: int,
  lastStance: LaneStance,
  haveLast: bool
): string =
  ## Everything this seat may legitimately know: its OWN whole screen, plus
  ## the four-row scoreboard. No other lane's tiles, sprites, avatar,
  ## targets, threats, stance, note, say or prompt is in here, and no real
  ## policy name ever is.
  let
    lane = sim.lanes[seat]
    preset = sim.config.preset
    threats = laneThreats(lane, preset)
    targets = laneTargets(lane, preset)
    playedTicks = sim.gameTicksElapsed()
    leftTicks = max(0, sim.config.maxTicks - playedTicks)

  var screen = newJArray()
  for row in screenMap(lane):
    screen.add(%row)

  var threatsJson = newJArray()
  for threat in threats:
    threatsJson.add(%*{
      "id": threat.id, "kind": threat.kind, "state": threat.state,
      "col": threat.col, "row": threat.row,
      "eta_ticks": (if threat.etaTicks >= FarEta: -1 else: threat.etaTicks),
      "dist_tiles": threat.distTiles
    })

  var targetsJson = newJArray()
  for target in targets:
    targetsJson.add(%*{
      "kind": target.kind, "col": target.col, "row": target.row,
      "value": target.value,
      "dist_ticks": (if target.distTicks >= FarEta: -1 else: target.distTicks),
      "zone": target.zone, "safe": target.safe
    })

  var you = %*{
    "alias": laneAlias(seat),
    "lives": int(lane.lives),
    "points": int(lane.points),
    "score": sim.laneScore(seat),
    "screen": int(lane.screen),
    "state": laneStateText(lane),
    "avatar": {
      "col": int(colOf(lane.ax)),
      "row": int(rowOf(lane.ay)),
      "x": round(float(lane.ax) / float(TileU) * 100.0) / 100.0,
      "y": round(float(lane.ay) / float(TileU) * 100.0) / 100.0,
      "facing": facingText(lane.facing),
      "speed_tiles_s": round(
        float(preset.avatarSpeed) * float(TargetFps) / float(TileU) * 100.0) / 100.0
    },
    "power_ticks_left": int(lane.powerTicksLeft),
    "chain": int(lane.chain),
    "best_chain": int(lane.bestChain),
    "record": lane.recordFlag,
    "par": int(preset.parScore)
  }
  if preset.avatarMode == amRailBottom:
    you["paddle_col"] = %int(colOf(lane.ax))
  if preset.fireEnabled:
    var live = 0
    for sprite in lane.sprites:
      if sprite.kind == skBoltFriendly and sprite.alive:
        inc live
    you["bolts_ready"] = %max(0, MaxFriendlyBolts - live)

  var chainTable = newJArray()
  for value in ChainPoints:
    chainTable.add(%value)

  var node = %*{
    "turn": turnIndex,
    "of": turnsPerEpisode,
    "clock": {
      "tick": playedTicks,
      "of": sim.config.maxTicks,
      "left_s": round(float(leftTicks) / float(TargetFps) * 10.0) / 10.0
    },
    "rom": preset.rom,
    "you": you,
    "screen_map": screen,
    "legend": legendJson(),
    "threats": threatsJson,
    "targets": targetsJson,
    "zones": zoneSummaries(lane, preset),
    "scoreboard": scoreboardJson(sim),
    "rules": {
      "lives_per_lane": int(preset.livesPerLane),
      "grid": [GridW, GridH],
      "par_score": int(preset.parScore),
      "points": {
        "pellet": PelletPoints,
        "power": PowerPoints,
        "chain": chainTable,
        "screen_clear": int(preset.screenClearBonus)
      },
      "score": "points / 100 + lives left; nothing is ever subtracted",
      "note": "your lane is sealed: nothing you do can affect any other " &
        "lane, and nothing they do can affect yours"
    }
  }
  if haveLast:
    node["your_last_stance"] = %*{
      "mode": $lastStance.mode,
      "zone": $lastStance.zone,
      "risk": lastStance.risk(),
      "lead_ticks": lastStance.leadTicks,
      "fire": $lastStance.fire
    }
  else:
    node["your_last_stance"] = newJNull()
  $node
