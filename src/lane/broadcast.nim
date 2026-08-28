## The broadcast channel: the state-delta -> event derivation the feed, the
## banners and the scrubber beats read, and the one JSON frame the chrome
## consumes.
##
## Kept from `coworld-ctf`'s `src/ctf/broadcast.nim`: the `BroadcastTracker`
## shape (snapshot / resync / stepEvents), the rule that events are DERIVED
## from state deltas so they cost no replay bytes and are identical live and
## in replay, and the state JSON's key names — `t, mt, ph, lob, pl, sp, mx,
## st, lp, sk, ff, en, mm, bs, pov, teams, roster, events, lead, beats,
## lulls, over, hold` — so the byte-identical `chrome_common.js` renders lane
## values with no edit at all.
##
## The `teams` keys are exactly `red`, `blue`, `green`, `yellow`, because
## `chrome_common.js:55` pins `TEAM_ORDER = ['red','blue','green','yellow']`
## and orders index 0/2 left of the clock and 1/3 right — so the four plates
## come out RED + GREEN | clock | BLUE + YELLOW with no edit.

import std/[json, strutils]
import sim, global

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    points: array[4, int32]
    lives: array[4, int32]
    screens: array[4, int32]
    chain: array[4, int32]
    over: array[4, bool]
    record: array[4, bool]
    power: array[4, int32]
    feedIndex: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  for seat in 0 ..< 4:
    let lane = sim.lanes[seat]
    tracker.points[seat] = lane.points
    tracker.lives[seat] = lane.lives
    tracker.screens[seat] = lane.screensCleared
    tracker.chain[seat] = lane.bestChain
    tracker.over[seat] = lane.phase == lpOver
    tracker.record[seat] = lane.recordFlag
    tracker.power[seat] = lane.powerTicksLeft
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.feedIndex = sim.feedRecords.len
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip, so no phantom
  ## beats fire on the frame after a jump.
  tracker.snapshot(sim)

proc stepEvents*(sim: SimServer, tracker: var BroadcastTracker, into: JsonNode) =
  ## Derives this step's broadcast events from the state delta. Beats — the
  ## kinds that land on the scrubber — are `life_lost`, `screen_clear`,
  ## `record`, `lane_over` and `over`. `pickup`, `chip`, `chain` and
  ## `near_miss` fire hundreds of times and would bury the scrubber, so they
  ## are events but never beats.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  for seat in 0 ..< 4:
    let
      lane = sim.lanes[seat]
      team = laneTeamKey(seat)
    if lane.points > tracker.points[seat]:
      into.add(%*{
        "k": "pickup", "t": sim.tickCount, "lane": seat, "team": team,
        "pts": int(lane.points - tracker.points[seat])})
    if lane.bestChain > tracker.chain[seat]:
      into.add(%*{
        "k": "chain", "t": sim.tickCount, "lane": seat, "team": team,
        "n": int(lane.bestChain)})
    if lane.lives < tracker.lives[seat]:
      into.add(%*{
        "k": "life_lost", "t": sim.tickCount, "lane": seat, "team": team,
        "livesLeft": int(lane.lives)})
    if lane.screensCleared > tracker.screens[seat]:
      into.add(%*{
        "k": "screen_clear", "t": sim.tickCount, "lane": seat, "team": team,
        "screen": int(lane.screen),
        "bonus": int(sim.config.preset.screenClearBonus)})
    if lane.recordFlag and not tracker.record[seat]:
      into.add(%*{
        "k": "record", "t": sim.tickCount, "lane": seat, "team": team,
        "points": int(lane.points),
        "par": int(sim.config.preset.parScore)})
    if (lane.phase == lpOver) and not tracker.over[seat]:
      into.add(%*{
        "k": "lane_over", "t": sim.tickCount, "lane": seat, "team": team,
        "points": int(lane.points)})
  # A stance's `say` is spectator-only and rides the feed, never the sim.
  var index = tracker.feedIndex
  while index < sim.feedRecords.len:
    let record = sim.feedRecords[index]
    inc index
    var node: JsonNode
    try:
      node = parseJson(record)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    if node{"k"}.getStr() == "stance":
      into.add(%*{
        "k": "say", "t": sim.tickCount,
        "lane": node{"lane"}.getInt(),
        "team": laneTeamKey(node{"lane"}.getInt()),
        "alias": node{"alias"}.getStr(),
        "mode": node{"mode"}.getStr(),
        "zone": node{"zone"}.getStr(),
        "source": node{"source"}.getStr(),
        "note": node{"note"}.getStr(),
        "say": node{"say"}.getStr()})
  if tracker.prevPhase != sim.phase:
    into.add(%*{
      "k": "phase", "t": sim.tickCount, "ph": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      into.add(%*{"k": "over", "t": sim.tickCount,
                  "winner": laneTeamKey(max(0, sim.winner))})
  tracker.snapshot(sim)

proc teamStateJson(sim: SimServer, seat: int): JsonNode =
  let lane = sim.lanes[seat]
  var policies = newJArray()
  policies.add(%sim.playerName(seat))
  %*{
    "score": sim.laneScore(seat),
    "points": int(lane.points),
    "lives": int(lane.lives),
    "livesPerLane": int(sim.config.preset.livesPerLane),
    "screen": int(lane.screen),
    "record": lane.recordFlag,
    "over": lane.phase == lpOver,
    "policies": policies,
    "mode": sim.seatMode[seat],
    "zone": sim.seatZone[seat],
    "placement": sim.placements[seat]
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## Spectator side ONLY: this is the one place a REAL policy name appears in
  ## the chrome stream. Nothing a seat receives carries it.
  result = newJArray()
  for seat in 0 ..< 4:
    let lane = sim.lanes[seat]
    result.add(%*{
      "s": seat,
      "name": sim.playerName(seat),
      "pol": sim.playerName(seat),
      "team": laneTeamKey(seat),
      "alias": laneAlias(seat),
      "lane": seat,
      "kind": sim.seatPolicyKind[seat],
      "points": int(lane.points),
      "score": sim.laneScore(seat),
      "lives": int(lane.lives),
      "alive": lane.phase != lpOver,
      "screen": int(lane.screen),
      "deaths": int(lane.deaths),
      "bestChain": int(lane.bestChain),
      "screensCleared": int(lane.screensCleared),
      "record": lane.recordFlag,
      "llmTurns": sim.llmTurns[seat],
      "fallbackTurns": sim.fallbackTurns[seat]
    })

proc laneBoardJson(sim: SimServer, seat: int): JsonNode =
  let lane = sim.lanes[seat]
  var tiles = ""
  for row in 0 ..< GridH:
    for col in 0 ..< GridW:
      tiles.add(tileGlyph(tileAt(lane, col, row)))
  var sprites = newJArray()
  for sprite in lane.sprites:
    if not sprite.alive:
      continue
    sprites.add(%*{
      "id": spriteLabel(sprite),
      "kind": spriteKindText(sprite),
      "state": spriteStateText(sprite),
      "x": float(sprite.x) / float(TileU),
      "y": float(sprite.y) / float(TileU)
    })
  %*{
    "s": seat,
    "team": laneTeamKey(seat),
    "alias": laneAlias(seat),
    "state": (case lane.phase
              of lpPlaying: "running"
              of lpDying: "dying"
              of lpRespawning: "respawning"
              of lpOver: "over"),
    "avatar": {
      "x": float(lane.ax) / float(TileU),
      "y": float(lane.ay) / float(TileU),
      "facing": facingText(lane.facing)
    },
    "tiles": tiles,
    "sprites": sprites,
    "power": int(lane.powerTicksLeft),
    "chain": int(lane.chain),
    "points": int(lane.points),
    "lives": int(lane.lives),
    "screen": int(lane.screen),
    "mode": sim.seatMode[seat],
    "zone": sim.seatZone[seat]
  }

proc stancesJson(sim: SimServer): JsonNode =
  ## The newest handful of stance records — where a spectator sees the LLM
  ## playing. Bounded so a long episode never grows the frame.
  var recent: seq[JsonNode]
  for record in sim.feedRecords:
    var node: JsonNode
    try:
      node = parseJson(record)
    except CatchableError:
      continue
    if node.kind == JObject and node{"k"}.getStr() == "stance":
      recent.add(node)
  result = newJArray()
  let first = max(0, recent.len - 8)
  for i in first ..< recent.len:
    result.add(recent[i])

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  includeFpMap: bool = false,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil,
  achievementBadges: JsonNode = nil
): string =
  ## One chrome frame. Board-derived STATE is always present, so a frame
  ## reached by a SEEK still hydrates the scorebug and the end-card with no
  ## events at all.
  var teams = newJObject()
  for seat in 0 ..< 4:
    teams[laneTeamKey(seat)] = teamStateJson(sim, seat)

  var lanesJson = newJArray()
  for seat in 0 ..< 4:
    lanesJson.add(laneBoardJson(sim, seat))

  var bubbles = newJArray()
  for seat in 0 ..< 4:
    if sim.seatSay[seat].len > 0 and sim.seatSayUntil[seat] > sim.tickCount:
      bubbles.add(%*{
        "lane": seat, "say": sim.seatSay[seat],
        "until": sim.seatSayUntil[seat]})

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": povSlot,
    "teams": teams,
    "roster": rosterJson(sim),
    "events": (if events.isNil: newJArray() else: events),
    "turn": (if sim.config.turnTicks > 0:
               sim.gameTicksElapsed() div sim.config.turnTicks else: 0),
    "turns": sim.config.turnsPerEpisode(),
    "turnTicks": sim.config.turnTicks,
    "a57": {
      "rom": sim.config.rom,
      "par": int(sim.config.preset.parScore),
      "grid": [GridW, GridH],
      "livesPerLane": int(sim.config.preset.livesPerLane),
      "lanes": lanesJson,
      "bubbles": bubbles
    },
    "stances": stancesJson(sim)
  }

  if leadSeries.len > 0:
    var teamNames = newJArray()
    for seat in 0 ..< 4:
      teamNames.add(%laneTeamKey(seat))
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}
  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents
  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  if sim.phase == GameOver:
    var overTeams = newJObject()
    for seat in 0 ..< 4:
      overTeams[laneTeamKey(seat)] = %*{
        "placement": sim.placements[seat],
        "score": sim.laneScore(seat),
        "points": int(sim.lanes[seat].points),
        "lives": int(sim.lanes[seat].lives),
        "screens": int(sim.lanes[seat].screensCleared),
        "deaths": int(sim.lanes[seat].deaths),
        "bestChain": int(sim.lanes[seat].bestChain),
        "record": sim.lanes[seat].recordFlag,
        "llmTurns": sim.llmTurns[seat],
        "fallbackTurns": sim.fallbackTurns[seat],
        "name": sim.playerName(seat)
      }
    state["over"] = %*{
      "winner": laneTeamKey(max(0, sim.winner)),
      "draw": sim.isDraw,
      "timeLimit": sim.timeLimitReached,
      "endRule": sim.endRule,
      "reason": sim.endReason,
      "ticks": sim.tickCount,
      "rom": sim.config.rom,
      "par": int(sim.config.preset.parScore),
      "teams": overTeams
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
