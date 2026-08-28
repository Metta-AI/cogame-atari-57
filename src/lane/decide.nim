## The decision layer: the per-turn loop that asks every live lane what its
## stance is for the next 120 ticks, and always has an answer.
##
## `coworld-ctf`'s `src/ctf/decide.nim`, retargeted from two squads to four
## sealed lanes. Kept whole: the turn loop, `SeatPolicy`, the ONE parallel
## batch per turn, the two bounded deadlines, the inter-batch rate floor, the
## budget guard, `repairMissingFields` (a missing field keeps last turn's
## value, else `arcader`'s) and the `records` queue.
##
## Cadence: one turn every `turnTicks` (120 ticks = 5.0 s of sim time), 24
## turns per episode. At each turn the server builds the request bodies for
## EVERY seat whose lane is not `Over` and issues them as ONE parallel batch —
## the cabinet is a simultaneous-decision game, so querying seats one after
## another would quadruple the wall clock for no gain.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `arcader` stance and a `fallback` record names the cause. No
## failure mode leaves a lane uncommanded: the autopilot always has a stance —
## this turn's, else last turn's, else `arcader`'s.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, stances, baselines, observation, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `arcader`, and is LOGGED LOUDLY
    ## (server edit 6), because a silently-lost register packet is otherwise
    ## indistinguishable from an LLM that chose badly.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    stances*: seq[LaneStance]
    haveStance*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](4)
  result.stances = newSeq[LaneStance](4)
  result.haveStance = newSeq[bool](4)
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blArcader
    result.seats[i].label = "arcader"
    result.stances[i] = DefaultStance

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): LaneStance =
  scriptedStance(sim, seat, kind)

proc arcaderFor*(engine: DecisionEngine, sim: SimServer, seat: int): LaneStance =
  ## The published `arcader` stance — the certification player, the per-turn
  ## fallback, and the default for a seat that registers with neither env var.
  arcaderStance(sim, seat)

proc repairMissingFields*(
  engine: DecisionEngine, sim: SimServer, seat: int, stance: var LaneStance
) =
  ## Design §Reply schema: a missing or unusable field keeps LAST turn's
  ## value, else `arcader`'s. The parser already applied the per-field
  ## repairs; this fills anything it could not.
  if stance.leadTicks < 0 or stance.leadTicks > 48:
    stance.leadTicks =
      if engine.haveStance[seat]: engine.stances[seat].leadTicks
      else: arcaderFor(engine, sim, seat).leadTicks
  if stance.riskMilli < 0 or stance.riskMilli > 1000:
    stance.riskMilli =
      if engine.haveStance[seat]: engine.stances[seat].riskMilli
      else: arcaderFor(engine, sim, seat).riskMilli

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the whole results document, written once
  ## into the replay chat stream at episode end. It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and a spectator holding the bytes cannot read that.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerEpisode: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's stance. Returns the
  ## replay chat records this turn produced. NEVER raises: every failure path
  ## ends in a legal stance.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  # If two more full turns (batch spacing included) would not fit inside the
  # engine's own wall-clock stop, switch the LLM off for the rest of the
  # episode and finish on the scripted layer — microseconds per turn — so the
  # episode ends complete/* rather than deadline.
  if not engine.llmOff:
    let turnSeconds =
      (sim.config.turnBudgetMs + sim.config.turnSpacingMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "atari-57: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? -------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if sim.laneIsOver(seat):
      # A finished lane is dropped from every later batch: there is nothing
      # left to decide and the autopilot commands 0 regardless.
      var stance = engine.scriptedFor(sim, seat, blArcader)
      stance.source = stScripted
      engine.stances[seat] = stance
      engine.haveStance[seat] = true
    elif engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      # scripted policy, and recording it is what makes the two countable.
      var stance = engine.arcaderFor(sim, seat)
      stance.source = stFallback
      engine.stances[seat] = stance
      engine.haveStance[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing arcader"))
      echo "atari-57 llm: seat ", seat, " falling back to arcader (", cause,
        ") on turn ", turnIndex
    else:
      var stance = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
      stance.source = stScripted
      engine.stances[seat] = stance
      engine.haveStance[seat] = true

  # --- the rate floor ------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and four seats at
  # a fast turn sit well over it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at 4 requests / 12 s =
  # 20 rpm. The cert fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches -----------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = laneViewJson(
        sim, seat, turnIndex, turnsPerEpisode,
        engine.stances[seat], engine.haveStance[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS and whose conversion FLOORS — which is why every deadline in
    # this game is a whole number of seconds (9 000 / 5 000 inside 16 000).
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var stance = parseLaneStance(
          extractJsonObject(text), engine.stances[seat],
          engine.haveStance[seat])
        stance.source = stLlm
        stance.latencyMs = latency
        engine.repairMissingFields(sim, seat, stance)
        engine.stances[seat] = stance
        engine.haveStance[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is: reporting a 429 as
          ## `parse_error` is what once made a hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(turnIndex, seat, attempt + 1, cause,
                                  error.msg))
        echo "atari-57 llm: seat ", seat, " attempt ", attempt + 1,
          " failed, will retry if a retry is left: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land.
      echo "atari-57 llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays arcader for this turn ---------------------
  for seat in open:
    var stance = engine.arcaderFor(sim, seat)
    stance.source = stFallback
    engine.stances[seat] = stance
    engine.haveStance[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the arcader stance"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "atari-57 llm: seat ", seat, " falling back to arcader (", cause,
      ") on turn ", turnIndex
