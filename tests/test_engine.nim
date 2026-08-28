## The decision turn, against a REAL local HTTP endpoint standing in for the
## Bedrock sidecar. The one property that matters most is that all four seats'
## calls go out as ONE PARALLEL BATCH: a game that queries seats one after
## another quadruples the wall clock for no gain and blows the play budget.

import std/[json, locks, monotimes, os, strformat, strutils, times]
import mummy, mummy/routers
import lane_helpers
import lane/[sim_types, decide, stances, llm]

type Window = object
  startMs, endMs: int64

var
  fakeLock: Lock
  windows: seq[Window]
  fakeDelayMs = 250
  fakeStatus = 200
  fakeBody = """{"mode":"hunt","zone":"sw","risk":0.55,"lead_ticks":16,
                 "note":"take the power pellet","say":"going for it"}"""
  episodeStart: MonoTime

proc nowMs(): int64 = (getMonoTime() - episodeStart).inMilliseconds

proc fakeHandler(request: Request) {.gcsafe.} =
  {.cast(gcsafe).}:
    let started = nowMs()
    sleep(fakeDelayMs)
    let finished = nowMs()
    withLock fakeLock:
      windows.add(Window(startMs: started, endMs: finished))
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    if fakeStatus != 200:
      request.respond(fakeStatus, headers, """{"message":"nope"}""")
      return
    request.respond(200, headers, $(%*{
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": fakeBody}]
    }))

# ONE fake sidecar for the whole file, started once and never closed: mummy
# owns its own worker pool and tearing it down mid-process is not what this
# test is about. Behaviour is varied through the globals above.
const FakePort = 8791
var
  fakeServer: Server
  fakeThread: Thread[int]

proc serveFake(port: int) {.thread.} =
  {.cast(gcsafe).}:
    fakeServer.serve(Port(port), "127.0.0.1")

proc startFake() =
  initLock(fakeLock)
  episodeStart = getMonoTime()
  var router: Router
  router.post("/**", fakeHandler)
  fakeServer = newServer(router, workerThreads = 8)
  createThread(fakeThread, serveFake, FakePort)
  fakeServer.waitUntilReady()

proc withSidecar() =
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", &"http://127.0.0.1:{FakePort}")
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")

proc withoutSidecar() =
  delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
  delEnv("AWS_BEARER_TOKEN_BEDROCK")
  delEnv("ANTHROPIC_API_KEY")
  delEnv("ANTHROPIC_API_KEY_URI")

proc resetFake() =
  fakeDelayMs = 250
  fakeStatus = 200
  fakeBody = """{"mode":"hunt","zone":"sw","risk":0.55,"lead_ticks":16,
                 "note":"take the power pellet","say":"going for it"}"""
  {.gcsafe.}:
    withLock fakeLock:
      windows.setLen(0)

proc requestCount(): int =
  {.gcsafe.}:
    withLock fakeLock:
      result = windows.len

proc llmEngine(game: SimServer): DecisionEngine =
  result = initDecisionEngine(game)
  for seat in 0 ..< 4:
    result.seats[seat].isLlm = true
    result.seats[seat].registered = true
    result.seats[seat].prompt = "play well"
    result.seats[seat].label = "test"

proc testOneParallelBatch() =
  ## The fake records each request's in-flight window; all four must
  ## INTERSECT. Sequential calls would produce four disjoint windows.
  withSidecar()
  resetFake()
  {.gcsafe.}:
    withLock fakeLock:
      windows.setLen(0)
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  check(engine.client.transport == ltBedrock,
        "the engine did not pick up the local endpoint")
  discard engine.turn(game, 0, 24, 0)
  var captured: seq[Window]
  {.gcsafe.}:
    withLock fakeLock:
      captured = windows
  check(captured.len == 4, &"{captured.len} requests went out, not 4")
  var
    firstStart = captured[0].startMs
    lastEnd = captured[0].endMs
  for w in captured:
    firstStart = min(firstStart, w.startMs)
    lastEnd = max(lastEnd, w.endMs)
  let span = lastEnd - firstStart
  # Sequential would be four delays end to end; one batch is far less. (libcurl
  # holds new transfers to an unknown origin back until the first connection is
  # up, so the batch reads as 1 + 3 rather than 4 at once — which is exactly
  # what the hosted sidecar does too.)
  check(span < int64(3 * fakeDelayMs),
        &"the batch spanned {span} ms against a {fakeDelayMs} ms per-call " &
        &"delay — four SEQUENTIAL calls would span ~{4 * fakeDelayMs} ms")
  var overlapping = 0
  for w in captured:
    var intersects = 0
    for other in captured:
      if w.startMs < other.endMs and other.startMs < w.endMs:
        inc intersects
    if intersects >= 3:
      inc overlapping
  check(overlapping >= 3,
        &"only {overlapping} of 4 requests were in flight alongside two " &
        "others — the seats were queried SEQUENTIALLY")
  for seat in 0 ..< 4:
    check(engine.haveStance[seat], &"seat {seat} got no stance")
    check(engine.stances[seat].source == stLlm,
          &"seat {seat}'s stance is not from the LLM")
    check(engine.stances[seat].mode == mdHunt, "the reply was not parsed")
  report("all four seats' calls go out in ONE parallel batch")

proc testOverLanesAreDropped() =
  withSidecar()
  resetFake()
  {.gcsafe.}:
    withLock fakeLock:
      windows.setLen(0)
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  game.lanes[1].phase = lpOver
  game.lanes[3].phase = lpOver
  var engine = llmEngine(game)
  discard engine.turn(game, 1, 24, 0)
  let captured = requestCount()
  check(captured == 2, &"{captured} requests went out for two live lanes")
  check(engine.stances[1].source == stScripted,
        "a finished lane was still asked for a stance")
  report("a finished lane is dropped from every later batch")

proc testInterBatchFloor() =
  ## The Bedrock sidecar caps 30 requests/minute PER EPISODE. Consecutive
  ## batches must start at least `turnSpacingMs` apart.
  withSidecar()
  resetFake()
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 600
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let t0 = getMonoTime()
  discard engine.turn(game, 0, 24, 0)
  let afterFirst = getMonoTime()
  discard engine.turn(game, 1, 24, 0)
  let afterSecond = getMonoTime()
  let gap = (afterSecond - afterFirst).inMilliseconds.int
  check(gap >= config.turnSpacingMs - fakeDelayMs - 50,
        &"consecutive batches were only {gap} ms apart, under the " &
        &"{config.turnSpacingMs} ms floor")
  discard t0
  report(&"consecutive batches are held {config.turnSpacingMs} ms apart")

proc testPerTurnBudgetWithAHungClient() =
  ## A hung provider must not hold the game: the whole turn is wrapped in a
  ## monotonic `turnBudgetMs`, and every seat still gets a legal stance.
  withSidecar()
  resetFake()
  fakeDelayMs = 4000
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  config.attempt1Ms = 1000
  config.retryMs = 1000
  config.turnBudgetMs = 3000
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let started = getMonoTime()
  let records = engine.turn(game, 0, 24, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check(elapsed <= config.turnBudgetMs + 2500,
        &"a hung provider held the turn for {elapsed} ms against a " &
        &"{config.turnBudgetMs} ms budget")
  for seat in 0 ..< 4:
    check(engine.haveStance[seat], &"seat {seat} was left with no stance")
    check(engine.stances[seat].source == stFallback,
          &"seat {seat} did not fall back")
  var causes: seq[string]
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      causes.add(node{"cause"}.getStr())
  check(causes.len > 0, "a hung provider produced no fallback record")
  for cause in causes:
    check(cause in ["timeout", "transport_error", "parse_error", "throttled"],
          &"unexpected fallback cause {cause}")
  report(&"a hung provider is bounded ({elapsed} ms) and every seat falls back")

proc testThrottleSkipsTheRetry() =
  ## A 429 with no other candidate model fails FAST: a retry inside the same
  ## turn cannot succeed, and spending the budget on it is what turned one
  ## throttle into a whole episode of scripted play (raid round 2).
  withSidecar()
  resetFake()
  fakeStatus = 429
  {.gcsafe.}:
    withLock fakeLock:
      windows.setLen(0)
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let records = engine.turn(game, 0, 24, 0)
  let captured = requestCount()
  check(captured == 4,
        &"{captured} requests went out — a throttle must not be retried")
  var sawThrottle = false
  for record in records:
    if parseJson(record){"cause"}.getStr() == "throttled":
      sawThrottle = true
  check(sawThrottle, "the throttle was not named as the fallback cause")
  report("a 429 with no other candidate skips the retry entirely")

proc testRetryOnceThenFallBack() =
  ## Unparseable once ⇒ exactly one retry; unparseable twice ⇒ the `arcader`
  ## stance and a `fallback` record.
  withSidecar()
  resetFake()
  fakeBody = "I would rather not."
  {.gcsafe.}:
    withLock fakeLock:
      windows.setLen(0)
  var config = testConfig(RomChomper, 5_140_913)
  config.turnSpacingMs = 0
  var game = seatedSim(config)
  var engine = llmEngine(game)
  let records = engine.turn(game, 0, 24, 0)
  let captured = requestCount()
  check(captured == 8, &"{captured} requests — expected 4 + exactly one retry")
  for seat in 0 ..< 4:
    check(engine.stances[seat].source == stFallback,
          &"seat {seat} did not fall back after two failures")
  var attempts: seq[int]
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      attempts.add(node{"attempt"}.getInt())
  check(1 in attempts and 2 in attempts,
        "both attempts were not recorded as fallbacks")
  report("one retry, then the arcader stance and a fallback record")

proc testBudgetGuard() =
  ## The guard settles EARLY rather than overrunning: with two more full turns
  ## unable to fit, the LLM is switched off for the rest of the episode and
  ## the run finishes on the scripted layer.
  var config = testConfig(RomChomper, 5_140_913)
  config.wallClockBudgetSeconds = 60
  config.turnBudgetMs = 16_000
  config.turnSpacingMs = 12_000
  var game = seatedSim(config)
  var engine = llmEngine(game)
  engine.client.disabled = true          ## no network in this one
  let records = engine.turn(game, 20, 24, 40)
  check(engine.llmOff, "the budget guard did not fire")
  var sawGuard = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      sawGuard = true
  check(sawGuard, "no budget_guard record was written")
  for seat in 0 ..< 4:
    check(engine.haveStance[seat], "the guard left a seat uncommanded")
  report("the budget guard fires, records itself and keeps every lane commanded")

proc testNoCredentialsFallsBackInstantly() =
  ## With no credentials the client disables itself and every turn falls back
  ## INSTANTLY with no network wait — which is what lets offline certification
  ## finish in seconds.
  withoutSidecar()
  let config = testConfig(RomChomper, 5_140_913)
  var game = seatedSim(config)
  var engine = llmEngine(game)
  check(engine.client.disabled, "a credential-free client is not disabled")
  let started = getMonoTime()
  let records = engine.turn(game, 0, 24, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check(elapsed < 2000, &"a credential-free turn took {elapsed} ms")
  var causes: seq[string]
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      causes.add(node{"cause"}.getStr())
  check(causes.len == 4, &"{causes.len} fallback records for four LLM seats")
  for cause in causes:
    check(cause == "no_credentials", &"cause {cause}, not no_credentials")
  report("no credentials ⇒ four instant, RECORDED fallbacks")

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
  startFake()
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
  # The fake sidecar owns a worker pool this process never needs to unwind.
  quit(0)
