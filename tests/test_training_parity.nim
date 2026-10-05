## The bridge must consume the hosted prompt and exact seeded four-seat engine.
include "../src/lane/training_bridge"
import lane/llm as native_prompt

for cartridge in ["chomper", "brickfall", "gallery"]:
  rom = cartridge
  let first = reset(%*{"seed": "7", "players": 4})
  doAssert game.config.seed == 7, "the bridge changed the submitted seed"
  doAssert game.config.minPlayers == defaultGameConfig().minPlayers
  doAssert game.players.len == 4, "the bridge omitted registered seats"
  doAssert first["messages"][0]["content"].getStr() == native_prompt.SystemPrompt
  var config = defaultGameConfig()
  config.update($(%*{"rom": cartridge, "seed": 7}))
  var ordinary = initSimServer(config)
  ordinary.gameEventLoggingEnabled = false
  for seat in 0 ..< 4:
    discard ordinary.addPlayer("P" & $(seat + 1), seat, "", trusted = true)
  ordinary.startGame()
  var physicalControls: array[4, ControlLane]
  for seat in 0 ..< 4: physicalControls[seat] = initControlLane()
  doAssert game.gameHash() == ordinary.gameHash()
  while game.phase == Playing:
    for seat in 0 ..< 4:
      let issued = currentDecision()
      doAssert issued["messages"][1]["content"].getStr() == ordinary.laneViewJson(
        seat, ordinary.gameTicksElapsed() div ordinary.config.turnTicks,
        ordinary.config.maxTicks div ordinary.config.turnTicks,
        chosenStances[seat], haveStance[seat])
      let proposal = teacher()["response"].getStr()
      doAssert parseJson(proposal) == stanceJson(arcaderStance(ordinary, seat)),
        "the issued-view teacher differs from the shipped baseline"
      let accepted = step(%*{"decision_id": decisionId, "response": proposal})
      doAssert accepted["kind"].getStr() == "accepted"
    for tick in 0 ..< ordinary.config.turnTicks:
      var commands = newSeq[uint8](4)
      for seat in 0 ..< 4:
        commands[seat] = laneCommand(physicalControls[seat], ordinary.lanes[seat],
          chosenStances[seat], ordinary.config.preset, ordinary.tickCount)
      ordinary.step(commands)
      if ordinary.phase != Playing: break
    doAssert game.gameHash() == ordinary.gameHash(), "physical replay diverged"
  doAssert game.playerResultsJson() == ordinary.playerResultsJson()
  echo cartridge, " hosted prompt/seed/four-seat physical parity passed"


for cartridge in ["chomper", "brickfall", "gallery"]:
  rom = cartridge
  discard reset(%*{"seed": "7", "players": 4})
  let completion = "Here is my stance:\n```json\n" & teacher()["response"].getStr() & "\n```"
  let expected = parseLaneStance(extractJsonObject(completion), DefaultStance, false)
  let applied = step(%*{"decision_id": 0, "response": completion})
  doAssert applied["kind"].getStr() == "accepted", "native parser accepts this prose-wrapped stance"
  doAssert applied["action"] == stanceJson(expected)
  echo cartridge, " ordinary completion parser parity passed"


numericMode = true
for cartridge in ["chomper", "brickfall", "gallery"]:
  rom = cartridge
  for invalid in ["{\"choice\":\"0\"}", "{\"choice\":0.0}", "{\"choice\":-1}",
                  "{\"choice\":51}", "{}", "[]"]:
    discard reset(%*{"seed": "7", "players": 4})
    doAssert step(%*{"decision_id": 0, "response": invalid})["kind"].getStr() == "rejected"
    doAssert actingSeat == 0 and decisionId == 0
  doAssert step(%*{"decision_id": 0, "response": "{\"choice\":0}"})["kind"].getStr() == "accepted"
  echo cartridge, " invalid numeric replies stay unaccepted"
