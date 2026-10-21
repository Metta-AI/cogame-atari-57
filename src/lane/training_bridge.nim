## Headless Atari 57 lanes using the hosted engine and private observations.
import std/[json, os, strutils]
import sim, observation, baselines, stances, control, roster, numeric_codec, prompts

const NumericSystemPrompt = CanonicalSystemPrompt[0 ..< CanonicalSystemPrompt.find("Reply with a single JSON object")] & """
Choose one of the numeric controller actions below. Reply only with
{"choice": INTEGER}, where INTEGER is from 0 through 50.
Choice 0 runs the shipped arcader baseline using only your current private view.
For choices 1 through 50, let code = choice - 1. The mode is selected by code
DIV 10: 0 clear (nearest scoring target), 1 hunt (highest-value target),
2 strike (cash in), 3 safe (score while avoiding threats), 4 bank (avoid trades).
The zone is selected by code MOD 10: 0 none, 1 nw, 2 ne, 3 sw, 4 se,
5 centre, 6 left, 7 right, 8 top, 9 bottom.
These actions fix risk to 0.2 for safe/bank and 0.55 otherwise, lead_ticks to
12 and fire to auto. They cover a subset of the ordinary stance controller.
"""

var
  game: SimServer
  controls: array[4, ControlLane]
  chosenStances: array[4, LaneStance]
  haveStance: array[4, bool]
  decisionId: int
  actingSeat: int
  rom = "chomper"
  numericMode = false
  selection: PromptSelection

proc candidates(): JsonNode =
  result = newJArray()
  for choice in 0 ..< NumericActions:
    result.add(%*{"choice": choice})


proc stanceJson(stance: LaneStance): JsonNode =
  %*{"mode": $stance.mode, "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0,
    "lead_ticks": stance.leadTicks, "fire": $stance.fire,
    "note": stance.note, "say": stance.say}

proc currentDecision(): JsonNode =
  let turn = game.gameTicksElapsed() div game.config.turnTicks
  result = %*{
    "kind": "decision", "game": "atari-57",
    "decision_id": decisionId, "seat": actingSeat,
    "engine_seat": actingSeat, "inbox": [], "speech_messages": [],
    "typed_question": newJNull(),
    "turn": turn,
    "messages": [
      {"role": "system", "content": (if numericMode: NumericSystemPrompt else: selection.systemPrompt())},
      {"role": "user", "content": game.laneViewJson(
        actingSeat, turn, game.config.maxTicks div game.config.turnTicks,
        chosenStances[actingSeat], haveStance[actingSeat])},
    ],
    "action_schema": {
      "type": "object",
      "properties": {
        "mode": {"enum": ["clear", "hunt", "strike", "safe", "bank"]},
        "zone": {"enum": ["none", "nw", "ne", "sw", "se", "centre",
          "left", "right", "top", "bottom"]},
        "risk": {"type": "number", "minimum": 0, "maximum": 1},
        "lead_ticks": {"type": "integer", "minimum": 0, "maximum": 48},
        "fire": {"enum": ["auto", "hold", "never"]},
      },
    },
  }
  if not numericMode:
    result["inference_mode"] = %"text_action"
    result["semantic_view"] = parseJson(result["messages"][1]["content"].getStr())
    result["semantic_view"]["prompt_template"] = selection.promptMetadata(
      result["messages"][0]["content"].getStr(), result["messages"][1]["content"].getStr())
    result["action_schema"]["properties"]["note"] = %*{"type": "string", "maxLength": 160}
    result["action_schema"]["properties"]["say"] = %*{"type": "string", "maxLength": 48}
  if numericMode:
    result["messages"][0]["content"] = %NumericSystemPrompt
    result["semantic_view"] = parseJson(result["messages"][1]["content"].getStr())
    result["action_schema"] = %*{"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0,
        "maximum": NumericActions - 1}}, "required": ["choice"]}

proc reset(command: JsonNode): JsonNode =
  if command["players"].getInt() != 4:
    raise newException(ValueError, "Atari 57 has exactly four isolated lanes")
  selection = promptSelection(command)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
      (not command.hasKey("split") or command["split"].getStr() != "validation"):
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  if numericMode and selection.variant != pvCanonical:
    raise newException(ValueError, "prompt variants require the text bridge")
  var config = defaultGameConfig()
  config.update($(%*{"rom": rom,
    "seed": parseInt(command["seed"].getStr())}))
  game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< 4:
    discard game.addPlayer("P" & $(seat + 1), seat, "", trusted = true)
  game.startGame()
  for seat in 0 ..< 4:
    controls[seat] = initControlLane()
    chosenStances[seat] = DefaultStance
    haveStance[seat] = false
  decisionId = 0
  actingSeat = 0
  currentDecision()

proc teacher(): JsonNode =
  %*{"response": (if numericMode: $(%*{"choice": 0})
                   else: $stanceJson(arcaderStance(parseJson(currentDecision()["messages"][1]["content"].getStr()))))}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  var submitted, reply: JsonNode
  var stance: LaneStance
  try:
    submitted =
      if numericMode: parseJson(command["response"].getStr())
      else: extractJsonObject(command["response"].getStr())
    if numericMode and (submitted.kind != JObject or not submitted.hasKey("choice") or
        submitted["choice"].kind != JInt or submitted["choice"].getInt() < 0 or
        submitted["choice"].getInt() >= NumericActions):
      return %*{"kind": "rejected", "reason": "reply must contain an integer choice from 0 through 50"}
    reply =
      if numericMode: candidateStance(parseJson(currentDecision()["messages"][1]["content"].getStr()), submitted["choice"].getInt())
      else: submitted
    stance = parseLaneStance(reply,
      chosenStances[actingSeat], haveStance[actingSeat])
  except JsonParsingError, StanceError:
    return %*{"kind": "rejected", "reason": "reply must be a usable JSON stance"}
  chosenStances[actingSeat] = stance
  haveStance[actingSeat] = true
  let action = if numericMode: submitted else: stanceJson(stance)
  if actingSeat < 3:
    inc actingSeat
  else:
    var cmds = newSeq[uint8](4)
    for tick in 0 ..< game.config.turnTicks:
      for seat in 0 ..< 4:
        cmds[seat] = laneCommand(controls[seat], game.lanes[seat],
          chosenStances[seat], game.config.preset, game.tickCount)
      game.step(cmds)
      if game.phase != Playing:
        break
    actingSeat = 0
  inc decisionId
  if game.phase != Playing:
    var scores = newJObject()
    for seat in 0 ..< 4:
      scores[$seat] = %game.laneScore(seat)
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

when isMainModule:
  if paramCount() > 2:
    raise newException(ValueError, "Pass a ROM and optional --numeric")
  if paramCount() >= 1:
    rom = paramStr(1)
  if paramCount() == 2:
    doAssert paramStr(2) == "--numeric"
    numericMode = true
  if rom notin ["chomper", "brickfall", "gallery"]:
    raise newException(ValueError, "ROM must be chomper, brickfall, or gallery")
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "teacher": teacher()
      of "encode":
        doAssert numericMode
        %*{"decision_id": decisionId,
          "values": features(parseJson(currentDecision()["messages"][1]["content"].getStr())),
          "actions": candidates()}
      of "step": step(command)
      else: raise newException(ValueError, "Unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
