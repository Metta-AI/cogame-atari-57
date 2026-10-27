## Authoritative private lane decisions and the actual encoded controls per tick.
import std/[base64, json, options]
import bitworld/decision_trajectory
import decide, sim, prompts

type
  LaneExecution = object
    startTick: int
    initialHash: uint64
    masks: string
    hashes: seq[string]
  MatchCapture* = ref object
    trajectory*: DecisionTrajectory
    pending: bool
    decisions: seq[TurnDecision]
    physical: array[4, LaneExecution]

proc newMatchCapture*(episodeId, version, revision: string, seed: int, rom: string): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(episodeId, "atari-57-" & rom & "-" & $seed,
    "atari-57", version, revision))

proc flushTurn*(capture: MatchCapture, endTick: int, terminal = false) =
  if not capture.pending: return
  for seat, physical in capture.physical:
    let issued = capture.decisions[seat]
    if issued.observation == nil or issued.observation.kind == JNull: continue
    doAssert physical.masks.len == endTick - physical.startTick
    doAssert physical.hashes.len == physical.masks.len
    var observation = copy(issued.observation)
    observation["execution"] = %*{"start_tick": physical.startTick, "end_tick": endTick,
      "tick_hz": TargetFps, "control_encoding": "atari-one-u8",
      "seat_input_masks_b64": encode(physical.masks), "initial_hash": $physical.initialHash,
      "post_tick_hashes": physical.hashes}
    capture.trajectory.recordDecision($physical.startTick & "-" & $seat, $seat,
      observation, issued.attempts, issued.selectedAttemptId, issued.executedAction,
      issued.status, terminal, if issued.status == asFallback: some("engine-arcader") else: none(string))
  capture.pending = false

proc beginTurn*(capture: MatchCapture, engine: DecisionEngine, sim: SimServer,
    selection: PromptSelection) =
  capture.flushTurn(sim.tickCount)
  capture.pending = true
  capture.decisions = engine.decisions
  for seat in 0 ..< 4:
    capture.physical[seat] = LaneExecution(startTick: sim.tickCount, initialHash: sim.gameHash())
    if capture.decisions[seat].observation.kind == JNull: continue
    var metadata = newJArray()
    for attempt in capture.decisions[seat].attempts:
      if attempt.prompt.kind == JArray and attempt.prompt.len == 2:
        metadata.add(%*{"attempt_id": attempt.attemptId, "prompt_template": selection.promptMetadata(
          attempt.prompt[0]["content"].getStr(), attempt.prompt[1]["content"].getStr())})
    capture.decisions[seat].observation["prompt_attempts"] = metadata

proc recordTick*(capture: MatchCapture, masks: seq[uint8], sim: SimServer) =
  if capture.pending:
    for seat in 0 ..< 4:
      capture.physical[seat].masks.add(char(masks[seat]))
      capture.physical[seat].hashes.add($sim.gameHash())

proc finishMatch*(capture: MatchCapture, sim: SimServer) =
  capture.flushTurn(sim.tickCount, true)
  let results = parseJson(sim.playerResultsJson())
  results["engine_version"] = %GameVersion
  let status = case results["reason"].getStr()
    of ReasonComplete: esCompleted
    of ReasonDeadline: esTruncated
    else: esFailed
  capture.trajectory.finish(status, results, newJNull())
