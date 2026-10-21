## The ordinary private-view decoder must reproduce the existing bridge's baseline.
import std/json
import lane/[sim, observation, baselines, stances, control, numeric_codec]

var compared = 0
for rom in ["chomper", "brickfall", "gallery"]:
  for seed in [7, 19, 31]:
    var config = defaultGameConfig()
    config.update($(%*{"rom":rom, "seed":seed, "minPlayers":1}))
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    discard game.addPlayer("test", 0, "", trusted = true)
    game.startGame()
    var controls: array[4, ControlLane]
    for seat in 0 ..< 4: controls[seat] = initControlLane()
    while game.phase == Playing:
      var choices: array[4, LaneStance]
      for seat in 0 ..< 4:
        let original = arcaderStance(game, seat)
        let view = parseJson(game.laneViewJson(seat,
          game.gameTicksElapsed() div game.config.turnTicks,
          game.config.maxTicks div game.config.turnTicks, DefaultStance, false))
        doAssert features(view).len == NumericFeatures
        for choice in 0 ..< NumericActions:
          let decoded = parseLaneStance(candidateStance(view, choice), DefaultStance, false)
          if choice == 0:
            doAssert decoded.mode == original.mode
            doAssert decoded.zone == original.zone
            doAssert decoded.riskMilli == original.riskMilli
            doAssert decoded.leadTicks == original.leadTicks
            doAssert decoded.fire == original.fire
            doAssert decoded.note == original.note
            doAssert decoded.say == original.say
        choices[seat] = original
        inc compared
      for tick in 0 ..< game.config.turnTicks:
        var inputs = newSeq[uint8](4)
        for seat in 0 ..< 4:
          inputs[seat] = laneCommand(controls[seat], game.lanes[seat], choices[seat], game.config.preset, game.tickCount)
        game.step(inputs)
        if game.phase != Playing: break
    # Finished lanes are also ordinary private observations.
    for seat in 0 ..< 4:
      let view = parseJson(game.laneViewJson(seat, 0, 1, DefaultStance, false))
      let decoded = parseLaneStance(candidateStance(view, 0), DefaultStance, false)
      let original = arcaderStance(game, seat)
      doAssert decoded.mode == original.mode
      doAssert decoded.fire == original.fire
      doAssert decoded.riskMilli == original.riskMilli
      inc compared
echo "Matched ", compared, " private-view baselines and every numeric stance across three ROMs and three seeds."
