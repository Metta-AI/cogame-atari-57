## Machinery every layer of the sim shares: the per-tick `gameHash` chain,
## the tier-2 event sink, the lobby countdown and the small logging helpers.
##
## Kept from `coworld-ctf`'s `src/ctf/sim_state.nim`: the `mixHash` fold and
## its "hash STATE, never presentation" rule, the `collectEvents` guard that
## makes an unanalysed server pay nothing, and the lobby-countdown helpers.
## The fields folded in are the lane's, not the arena's.

import std/[json, strutils]
import sim_types

proc mixHash*(hash: var uint64, value: uint64) {.inline.} =
  ## One step of the fold. FNV-1a's prime over a 64-bit accumulator with an
  ## xorshift finaliser: integer only, identical on amd64 and wasm32.
  hash = hash xor value
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc mixHash*(hash: var uint64, value: int32) {.inline.} =
  mixHash(hash, cast[uint64](int64(value)))

proc mixHash*(hash: var uint64, value: int) {.inline.} =
  mixHash(hash, cast[uint64](int64(value)))

proc mixHash*(hash: var uint64, value: bool) {.inline.} =
  mixHash(hash, (if value: 1'u64 else: 0'u64))

proc mixHash*(hash: var uint64, value: uint8) {.inline.} =
  mixHash(hash, uint64(value))

proc mixHash*(hash: var uint64, value: int64) {.inline.} =
  mixHash(hash, cast[uint64](value))

proc laneHash*(hash: var uint64, lane: Lane) =
  ## Everything about one lane that a replay must reproduce. FX, notes,
  ## `say`, feed text, stances and policy labels are deliberately ABSENT:
  ## none of them is re-derived at playback, so hashing them would make every
  ## replay diverge on the first spoken line.
  mixHash(hash, ord(lane.phase))
  mixHash(hash, lane.phaseTimer)
  mixHash(hash, lane.lives)
  mixHash(hash, lane.points)
  mixHash(hash, lane.screen)
  mixHash(hash, lane.overTick)
  mixHash(hash, lane.lastScoreTick)
  mixHash(hash, lane.recordFlag)
  mixHash(hash, lane.ax)
  mixHash(hash, lane.ay)
  mixHash(hash, lane.facing)
  mixHash(hash, lane.pendingDir)
  mixHash(hash, lane.pendingAge)
  mixHash(hash, lane.reload)
  for i in 0 ..< GridCells:
    mixHash(hash, lane.tiles[i])
    mixHash(hash, lane.bunkerHp[i])
  mixHash(hash, lane.sprites.len)
  for sprite in lane.sprites:
    mixHash(hash, ord(sprite.kind))
    mixHash(hash, ord(sprite.state))
    mixHash(hash, sprite.alive)
    mixHash(hash, sprite.x)
    mixHash(hash, sprite.y)
    mixHash(hash, sprite.vx)
    mixHash(hash, sprite.vy)
    mixHash(hash, sprite.dir)
    mixHash(hash, sprite.timer)
    mixHash(hash, sprite.id)
  mixHash(hash, lane.powerTicksLeft)
  mixHash(hash, lane.chain)
  mixHash(hash, lane.bestChain)
  mixHash(hash, lane.speedPermille)
  mixHash(hash, lane.marchTicks)
  mixHash(hash, lane.marchTimer)
  mixHash(hash, lane.marchDir)
  mixHash(hash, lane.marchTopRow)
  mixHash(hash, lane.scatterTimer)
  mixHash(hash, lane.scatterHold)
  mixHash(hash, lane.saucerCooldown)
  mixHash(hash, lane.serveTimer)
  mixHash(hash, lane.deaths)
  mixHash(hash, lane.screensCleared)
  mixHash(hash, lane.shotsFired)
  mixHash(hash, lane.brickHits)
  mixHash(hash, lane.scoreMicro)
  mixHash(hash, lane.rngDraws)

proc gameHash*(sim: SimServer): uint64 =
  ## The integrity chain the wasm viewer re-checks every tick.
  result = 0xCBF29CE484222325'u64
  mixHash(result, sim.tickCount)
  mixHash(result, ord(sim.phase))
  mixHash(result, sim.stopped)
  mixHash(result, sim.stoppedTick)
  for lane in sim.lanes:
    laneHash(result, lane)

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  lane = 0,
  amount = 0,
  col = -1,
  row = -1,
  detail = "",
  content = ""
) =
  ## Appends one tier-2 event. Guarded by `collectEvents` so a live server
  ## nobody is analysing pays nothing at all.
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(
    tick: sim.tickCount,
    kind: kind,
    lane: lane,
    amount: amount,
    col: col,
    row: row,
    detail: detail,
    content: content
  ))

proc logGame*(sim: SimServer, message: string) =
  if sim.gameEventLoggingEnabled:
    echo message

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## What the chrome's "WAITING FOR PLAYERS" line counts down.
  if sim.phase != Lobby:
    return 0
  max(0, (sim.startCountdown + TargetFps - 1) div TargetFps)

proc pushFeedRecord*(sim: var SimServer, record: string) =
  ## The stance / fallback / result records the broadcast feed reads. Bounded
  ## so a long episode cannot grow this without limit; the chrome only ever
  ## draws the newest handful.
  sim.feedRecords.add(record)
  if sim.feedRecords.len > 64:
    sim.feedRecords.delete(0)

proc seatStanceSummary*(sim: SimServer, seat: int): string =
  ## `CLEAR`, `HUNT·SW`, … — the stance chip the viewer burns onto a lane's
  ## frame. Presentation only, never hashed.
  if seat < 0 or seat > 3:
    return ""
  let mode = sim.seatMode[seat]
  if mode.len == 0:
    return ""
  let zone = sim.seatZone[seat]
  if zone.len == 0 or zone == "none":
    toUpperAscii(mode)
  else:
    toUpperAscii(mode) & "\u00B7" & toUpperAscii(zone)

proc eventKindKey*(kind: SimEventKind): string =
  case kind
  of Pickup: "pickup"
  of Chip: "chip"
  of Bunker: "bunker"
  of Chain: "chain"
  of Saucer: "saucer"
  of NearMiss: "near_miss"
  of LifeLost: "life_lost"
  of ScreenClear: "screen_clear"
  of Record: "record"
  of LaneOver: "lane_over"
  of Stance: "stance"
  of PhaseChange: "phase"

proc jsonRow*(event: SimEvent): JsonNode =
  %*{
    "tick": event.tick,
    "kind": eventKindKey(event.kind),
    "lane": event.lane,
    "amount": event.amount,
    "col": event.col,
    "row": event.row,
    "detail": event.detail,
    "content": event.content
  }
