## Headless Atari 57 lanes for Metta post-training.
## The game simulation and player observation are the hosted implementations.

import std/[hashes, json, os]
import sim, observation, baselines, stances, control, roster

const SystemPrompt = "Play one Atari 57 lane. Reply with one JSON stance: " &
  "{\"mode\":\"clear|hunt|strike|safe|bank\"," &
  "\"zone\":\"none|nw|ne|sw|se|centre|left|right|top|bottom\"," &
  "\"risk\":0.5,\"lead_ticks\":14,\"fire\":\"auto|hold|never\"}. " &
  "Your lane is isolated; the scoreboard is public."

var
  game: SimServer
  controls: array[4, ControlLane]
  chosenStances: array[4, LaneStance]
  haveStance: array[4, bool]
  decisionId: int
  actingSeat: int
  rom = "chomper"

proc stanceJson(stance: LaneStance): JsonNode =
  %*{"mode": $stance.mode, "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0,
    "lead_ticks": stance.leadTicks, "fire": $stance.fire,
    "note": stance.note, "say": stance.say}

proc currentDecision(): JsonNode =
  let turn = game.gameTicksElapsed() div game.config.turnTicks
  %*{
    "kind": "decision", "decision_id": decisionId, "seat": actingSeat,
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
  %*{"response": $stanceJson(arcaderStance(game, actingSeat))}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  var stance: LaneStance
  try:
    stance = parseLaneStance(extractJsonObject(command["response"].getStr()),
      chosenStances[actingSeat], haveStance[actingSeat])
  except JsonParsingError, StanceError:
    return %*{"kind": "rejected", "reason": "reply must be a usable JSON stance"}
  chosenStances[actingSeat] = stance
  haveStance[actingSeat] = true
  let action = stanceJson(stance)
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
  if paramCount() > 1:
    raise newException(ValueError, "Pass at most one ROM")
  if paramCount() == 1:
    rom = paramStr(1)
  if rom notin ["chomper", "brickfall", "gallery"]:
    raise newException(ValueError, "ROM must be chomper, brickfall, or gallery")
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "teacher": teacher()
      of "step": step(command)
      else: raise newException(ValueError, "Unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
