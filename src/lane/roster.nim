## Join, auth, and the results document.
##
## Kept from `coworld-ctf`'s `src/ctf/roster.nim`: the strictly
## slot-sequential join rule (`nextPlayerSlot` / `resolvePlayerSlot` /
## `addPlayer`), the trusted-join escape hatch the server uses to seat a
## no-show's lane, and `playerResultsJson` as the ONE writer of the results
## document. The keys are the cabinet's.

import std/json
import sim_types, sim_config

proc seatCount*(sim: SimServer): int {.inline.} =
  max(1, min(MaxPlayers, sim.config.numAgents))

proc nextPlayerSlot*(sim: SimServer): int =
  ## Joins are strictly slot-sequential, so the seat a lobby is stuck waiting
  ## on is exactly this.
  sim.players.len

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.seatCount()

proc resolvePlayerSlot*(
  sim: SimServer, address, token: string, requestedSlot: int
): int =
  ## Which seat a pending connection wants. An explicit slot wins; a token
  ## that matches a configured roster entry resolves to that entry; anything
  ## else takes the next open seat.
  if requestedSlot >= 0 and requestedSlot < sim.seatCount():
    return requestedSlot
  if token.len > 0:
    for i, player in sim.config.players:
      if player.token.len > 0 and player.token == token:
        return i
  sim.players.len

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot: int,
  token: string,
  trusted = false
): int =
  ## Seats one connection. Raises `LaneError` when the seat is illegal — the
  ## caller closes the socket rather than half-seating anybody.
  let slot =
    if requestedSlot >= 0: requestedSlot
    else: sim.players.len
  if slot != sim.players.len:
    raise newException(
      LaneError, "player slot " & $slot & " is not the next open seat")
  if slot >= sim.seatCount():
    raise newException(LaneError, "cabinet is full")
  if not trusted and not sim.config.playerJoinAllowed(address, slot, token):
    raise newException(LaneError, "player credentials do not match slot")
  sim.players.add(Player(
    address: address,
    token: token,
    slot: int32(slot),
    joinOrder: int32(slot),
    lane: int32(slot),
    connected: true,
    reward: 0
  ))
  if slot <= sim.seatNames.high and sim.seatNames[slot].len == 0:
    sim.seatNames[slot] = address
  sim.players.len - 1

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## A seat that drops does NOT lose its lane: the lane keeps playing on the
  ## scripted layer and the seat revives on reconnect. Only the roster row's
  ## `connected` flag moves, so no later lane is ever renumbered mid-replay.
  if index < 0 or index >= sim.players.len:
    return
  sim.players[index].connected = false

proc recordGameAbandon*(sim: var SimServer, index: int) =
  if index >= 0 and index < sim.players.len:
    sim.players[index].connected = false

proc playerName*(sim: SimServer, seat: int): string =
  ## The REAL policy name of one seat — spectator side only.
  if seat >= 0 and seat < sim.players.len and sim.players[seat].address.len > 0:
    return sim.players[seat].address
  if seat >= 0 and seat <= sim.seatNames.high and sim.seatNames[seat].len > 0:
    return sim.seatNames[seat]
  "Baseline (" & $(seat + 1) & ")"

proc laneScore*(sim: SimServer, lane: int): float =
  ## `points / 100 + livesLeft`, as a double with three decimals of meaning.
  ## Both terms are non-negative, so the minimum is 0.000 and higher is
  ## always better.
  if lane < 0 or lane > 3:
    return 0.0
  float(sim.lanes[lane].scoreMicro) / 1_000_000.0

proc playerResultsJson*(sim: SimServer): string =
  ## The results document, written to `COGAME_RESULTS_URI` and embedded in
  ## the replay's `result` record. It must equal the manifest's
  ## `results_schema` key for key: that schema is `additionalProperties:
  ## false` and the certifier rejects any unknown field, so adding a key here
  ## means editing `coworld_manifest_template.json` in the same commit.
  var
    names = newJArray()
    aliases = newJArray()
    lanes = newJArray()
    policyKinds = newJArray()
    scores = newJArray()
    win = newJArray()
    placements = newJArray()
    points = newJArray()
    livesLeft = newJArray()
    deaths = newJArray()
    screensCleared = newJArray()
    bestChain = newJArray()
    shotsFired = newJArray()
    records = newJArray()
    lastScoreTick = newJArray()
    ticksAlive = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in 0 ..< 4:
    let lane = sim.lanes[seat]
    names.add(%sim.playerName(seat))
    aliases.add(%laneAlias(seat))
    lanes.add(%seat)
    policyKinds.add(%(if sim.seatPolicyKind[seat].len > 0:
                        sim.seatPolicyKind[seat] else: "scripted"))
    scores.add(%sim.laneScore(seat))
    placements.add(%sim.placements[seat])
    win.add(%(sim.placements[seat] == 1))
    points.add(%int(lane.points))
    livesLeft.add(%int(lane.lives))
    deaths.add(%int(lane.deaths))
    screensCleared.add(%int(lane.screensCleared))
    bestChain.add(%int(lane.bestChain))
    shotsFired.add(%int(lane.shotsFired))
    records.add(%lane.recordFlag)
    lastScoreTick.add(%int(lane.lastScoreTick))
    ticksAlive.add(%(if lane.overTick >= 0: int(lane.overTick)
                     else: sim.tickCount))
    llmTurns.add(%sim.llmTurns[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
  let node = %*{
    "names": names,
    "aliases": aliases,
    "lanes": lanes,
    "policyKinds": policyKinds,
    "scores": scores,
    "win": win,
    "placements": placements,
    "rom": sim.config.rom,
    "parScore": int(sim.config.preset.parScore),
    "points": points,
    "livesLeft": livesLeft,
    "deaths": deaths,
    "screensCleared": screensCleared,
    "bestChain": bestChain,
    "shotsFired": shotsFired,
    "records": records,
    "lastScoreTick": lastScoreTick,
    "ticksAlive": ticksAlive,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "finalTick": sim.tickCount,
    "reason": (if sim.endReason.len > 0: sim.endReason else: ReasonComplete),
    "endRule": (if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime),
    "seed": sim.config.seed
  }
  $node

proc resultsKeys*(): seq[string] =
  ## The 24 keys, in document order — what `tests/test_manifest.nim` checks
  ## `results_schema` against.
  @["names", "aliases", "lanes", "policyKinds", "scores", "win", "placements",
    "rom", "parScore", "points", "livesLeft", "deaths", "screensCleared",
    "bestChain", "shotsFired", "records", "lastScoreTick", "ticksAlive",
    "llmTurns", "fallbackTurns", "finalTick", "reason", "endRule", "seed"]

proc rewardPacket*(sim: SimServer): string =
  ## The optional `/reward` stream. One line per seat; the score is the same
  ## number the results document reports.
  for seat in 0 ..< min(4, sim.players.len):
    result.add("reward ")
    result.add(laneAlias(seat))
    result.add(' ')
    result.add($int(sim.lanes[seat].points))
    result.add('\n')
