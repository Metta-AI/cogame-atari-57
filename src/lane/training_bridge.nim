## Headless Atari 57 lanes for Metta post-training.
## The game simulation and player observation are the hosted implementations.

import std/[hashes, json, os]
import sim, observation, baselines, stances, control, roster

const SystemPrompt = "Play one Atari 57 lane. Reply with one JSON stance: " &
  "{\"mode\":\"clear|hunt|strike|safe|bank\"," &
  "\"zone\":\"none|nw|ne|sw|se|centre|left|right|top|bottom\"," &
  "\"risk\":0.5,\"lead_ticks\":14,\"fire\":\"auto|hold|never\"}. " &
  "Your lane is isolated; the scoreboard is public."

const
  NumericFeatures = 435
  NumericActions = 1 + 5 * 10
  Zones = ["none", "nw", "ne", "sw", "se", "centre", "left", "right",
    "top", "bottom"]

var
  game: SimServer
  controls: array[4, ControlLane]
  chosenStances: array[4, LaneStance]
  haveStance: array[4, bool]
  decisionId: int
  actingSeat: int
  rom = "chomper"
  numericMode = false

proc features(view: JsonNode): JsonNode =
  result = newJArray()
  for name in ["chomper", "brickfall", "gallery"]:
    result.add(%(if view["rom"].getStr() == name: 1 else: 0))
  for key in ["turn", "of"]: result.add(view[key])
  result.add(view["clock"]["left_s"])
  let you = view["you"]
  for key in ["lives", "points", "score", "screen"]: result.add(you[key])
  for key in ["col", "row", "x", "y", "speed_tiles_s"]:
    result.add(you["avatar"][key])
  for key in ["power_ticks_left", "chain", "best_chain", "par"]:
    result.add(you[key])
  result.add(%(if you["record"].getBool(): 1 else: 0))
  for player in view["scoreboard"]:
    for key in ["score", "lives", "screen"]: result.add(player[key])
  for zone in ["nw", "ne", "sw", "se", "centre"]:
    for key in ["value", "min_threat_eta"]:
      result.add(view["zones"][zone][key])
  for line in view["screen_map"]:
    for ch in line.getStr(): result.add(%ord(ch))
  for index in 0 ..< 12:
    if index < view["targets"].len:
      let target = view["targets"][index]
      for key in ["col", "row", "value", "dist_ticks"]:
        result.add(target[key])
      result.add(%(if target["safe"].getBool(): 1 else: 0))
      var zoneIndex = 0
      for position, zone in Zones:
        if target["zone"].getStr() == zone: zoneIndex = position
      result.add(%zoneIndex)
    else:
      for _ in 0 ..< 6: result.add(%0)
  for index in 0 ..< 8:
    if index < view["threats"].len:
      let threat = view["threats"][index]
      for key in ["col", "row", "eta_ticks", "dist_tiles"]:
        result.add(threat[key])
    else:
      for _ in 0 ..< 4: result.add(%0)
  doAssert result.len == NumericFeatures

proc candidates(): JsonNode =
  result = newJArray()
  for choice in 0 ..< NumericActions:
    result.add(%*{"choice": choice})


proc stanceJson(stance: LaneStance): JsonNode =
  %*{"mode": $stance.mode, "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0,
    "lead_ticks": stance.leadTicks, "fire": $stance.fire,
    "note": stance.note, "say": stance.say}

proc candidateStance(choice: int, seat: int): JsonNode =
  doAssert choice in 0 ..< NumericActions
  if choice == 0:
    return stanceJson(arcaderStance(game, seat))
  let code = choice - 1
  let mode = Mode(code div Zones.len)
  let zone = Zones[code mod Zones.len]
  %*{"mode": $mode, "zone": zone,
    "risk": (if mode in [mdSafe, mdBank]: 0.2 else: 0.55),
    "lead_ticks": 12, "fire": "auto", "note": "numeric stance", "say": ""}

proc currentDecision(): JsonNode =
  let turn = game.gameTicksElapsed() div game.config.turnTicks
  result = %*{
    "kind": "decision", "game": "atari-57",
    "decision_id": decisionId, "seat": actingSeat,
    "engine_seat": actingSeat, "inbox": [], "speech_messages": [],
    "typed_question": newJNull(),
    "turn": turn,
    "messages": [
      {"role": "system", "content": SystemPrompt},
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
  if numericMode:
    result["semantic_view"] = parseJson(result["messages"][1]["content"].getStr())
    result["action_schema"] = %*{"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0,
        "maximum": NumericActions - 1}}, "required": ["choice"]}

proc reset(command: JsonNode): JsonNode =
  if command["players"].getInt() != 4:
    raise newException(ValueError, "Atari 57 has exactly four isolated lanes")
  var config = defaultGameConfig()
  config.update($(%*{"rom": rom,
    "seed": int(hash(command["seed"].getStr()) and hash(high(int))),
    "minPlayers": 1}))
  game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  discard game.addPlayer("P1", 0, "", trusted = true)
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
                   else: $stanceJson(arcaderStance(game, actingSeat)))}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  var submitted, reply: JsonNode
  var stance: LaneStance
  try:
    submitted = parseJson(command["response"].getStr())
    reply =
      if numericMode: candidateStance(submitted["choice"].getInt(), actingSeat)
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
