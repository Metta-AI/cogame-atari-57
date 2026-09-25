## Game-owned decisions over one bounded batch of ordinary player responses.

import std/[json, monotimes, os, sequtils, strformat, times]
import lane_helpers
import lane/[sim_types, decide, stances]

const GoodAction = """{"mode":"hunt","zone":"sw","risk":0.55,
  "lead_ticks":16,"note":"take the power pellet","say":"going for it"}"""

var batchCalls: seq[seq[BatchCall]]
var behavior = "good"

proc fakeBatch(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
    {.gcsafe.} =
  {.cast(gcsafe).}:
    batchCalls.add(calls)
    if behavior == "timeout":
      sleep(min(1000, timeoutSeconds * 1000))
    for call in calls:
      var reply = BatchReply(seat: call.seat)
      case behavior
      of "good":
        reply.ok = true
        reply.action = GoodAction
      of "malformed":
        reply.ok = true
        reply.action = "no stance"
      of "throttled", "no_credentials", "timeout":
        reply.cause = behavior
        reply.error = behavior
      else:
        raise newException(ValueError, "unknown fake behavior")
      result.add(reply)

proc llmEngine(game: SimServer): DecisionEngine =
  result = initDecisionEngine(game)
  result.batch = fakeBatch
  for seat in 0 ..< 4:
    result.seats[seat].isLlm = true
    result.seats[seat].registered = true
    result.seats[seat].label = "test"

proc resetFake(next: string) =
  behavior = next
  batchCalls.setLen(0)

proc testOneParallelBatch() =
  resetFake("good")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  discard engine.turn(game, 0, 24, 0)
  check(batchCalls.len == 1 and batchCalls[0].len == 4,
    "four seats were not issued in one batch")
  for seat in 0 ..< 4:
    check(batchCalls[0][seat].seat == seat, "seat order changed")
    check(parseJson(batchCalls[0][seat].view){"you"}{"alias"}.getStr().len > 0,
      "the player received no private view")
    check(engine.haveStance[seat] and engine.stances[seat].source == stLlm and
      engine.stances[seat].mode == mdHunt, "a player stance was not installed")
  report("four private decisions were issued in one batch")

proc testOverLanesAreDropped() =
  resetFake("good")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  game.lanes[1].phase = lpOver
  game.lanes[3].phase = lpOver
  var engine = llmEngine(game)
  discard engine.turn(game, 1, 24, 0)
  check(batchCalls.len == 1 and batchCalls[0].len == 2,
    "finished lanes reached the player batch")
  check(engine.stances[1].source == stScripted,
    "a finished lane still used an external stance")
  report("finished lanes are omitted")

proc testInterBatchFloor() =
  resetFake("good")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 300
  var game = seatedSim(config)
  var engine = llmEngine(game)
  discard engine.turn(game, 0, 24, 0)
  let started = getMonoTime()
  discard engine.turn(game, 1, 24, 0)
  check((getMonoTime() - started).inMilliseconds >= 250,
    "successive batches ignored the rate floor")
  report("the inter-batch rate floor remains")

proc testPerTurnBudgetWithAHungClient() =
  resetFake("timeout")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  config.attempt1Ms = 1000
  config.retryMs = 1000
  config.turnBudgetMs = 3000
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let started = getMonoTime()
  let records = engine.turn(game, 0, 24, 0)
  check((getMonoTime() - started).inMilliseconds < 3500,
    "a player timeout exceeded the turn budget")
  for seat in 0 ..< 4:
    check(engine.stances[seat].source == stFallback,
      "a timed-out player did not fall back")
  check(records.len >= 4, "fallback records were missing")
  report("bounded player timeouts fall back")

proc testThrottleSkipsTheRetry() =
  resetFake("throttled")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let records = engine.turn(game, 0, 24, 0)
  check(batchCalls.len == 1, "a throttled player was retried")
  check(records.anyIt(parseJson(it){"cause"}.getStr() == "throttled"),
    "throttle cause was not recorded")
  report("throttling skips a retry")

proc testRetryOnceThenFallBack() =
  resetFake("malformed")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let records = engine.turn(game, 0, 24, 0)
  check(batchCalls.len == 2 and batchCalls[1].len == 4,
    "unusable replies did not receive exactly one retry")
  for seat in 0 ..< 4:
    check(engine.stances[seat].source == stFallback,
      "an unusable reply did not fall back")
  check(records.len >= 8, "attempt records were missing")
  report("one retry then game-owned fallback")

proc testBudgetGuard() =
  resetFake("good")
  var config = testConfig(RomChomper, 5_140_913)
  config.wallClockBudgetSeconds = 60
  config.turnBudgetMs = 16_000
  config.turnSpacingMs = 12_000
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let records = engine.turn(game, 20, 24, 40)
  check(engine.llmOff, "the budget guard did not fire")
  check(batchCalls.len == 0, "the guard still called players")
  check(records.anyIt(parseJson(it){"k"}.getStr() == "budget_guard"),
    "the guard record is missing")
  report("budget guard keeps lanes commanded")

proc testNoCredentialsFallsBackInstantly() =
  resetFake("no_credentials")
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let started = getMonoTime()
  let records = engine.turn(game, 0, 24, 0)
  check((getMonoTime() - started).inMilliseconds < 2000,
    "missing credentials held the turn")
  check(batchCalls.len == 1, "missing credentials were retried")
  check(records.anyIt(parseJson(it){"cause"}.getStr() == "no_credentials"),
    "the player cause did not reach the replay")
  report("missing player credentials yield typed fallbacks")

proc testMinTicksHoldsTheEpisodeOpen() =
  ## The episode does not end on "all four lanes over" before `minTicks`: a
  ## replay shorter than the viewer smoke's soak reads as frozen.
  var config = testConfig(RomChomper, 5_140_913)
  config.minTicks = 900
  var game = seatedSim(config)
  for seat in 0 ..< 4:
    game.lanes[seat].phase = lpOver
    game.lanes[seat].overTick = 0
  for _ in 0 ..< 500:
    game.step(newSeq[uint8](4))
    check(game.phase == Playing,
          &"the episode ended at tick {game.tickCount}, before minTicks 900")
  while game.phase == Playing and game.tickCount < 2000:
    game.step(newSeq[uint8](4))
  check(game.endRule == EndRuleAllLanesOver,
        &"expected all_lanes_over, got {game.endRule}")
  check(game.tickCount >= config.minTicks,
        "the episode ended before minTicks after all")
  report("minTicks holds the episode open with every lane over")

proc testWallClockStopIsRecorded() =
  var config = testConfig(RomChomper, 5_140_913)
  var game = seatedSim(config)
  for _ in 0 ..< 300:
    game.step(newSeq[uint8](4))
  game.recordStop(game.tickCount)
  game.step(newSeq[uint8](4))
  check(game.stopped, "the stop was not recorded in hashed state")
  check(game.endReason == ReasonDeadline and game.endRule == EndRuleWallClock,
        &"the stop yielded {game.endReason}/{game.endRule}")
  let record = parseJson(stoppedRecord(300))
  check(record{"k"}.getStr() == "stopped" and
        record{"reason"}.getStr() == EndRuleWallClock,
        "the stopped record has the wrong shape")
  report("the wall-clock stop is hashed state and yields deadline/wall_clock")

when isMainModule:
  echo "test_engine"
  testOneParallelBatch()
  testOverLanesAreDropped()
  testInterBatchFloor()
  testPerTurnBudgetWithAHungClient()
  testThrottleSkipsTheRetry()
  testRetryOnceThenFallBack()
  testBudgetGuard()
  testNoCredentialsFallsBackInstantly()
  testMinTicksHoldsTheEpisodeOpen()
  testWallClockStopIsRecorded()
  echo "test_engine OK"
