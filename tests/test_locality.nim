## The two name spaces and the information invariants, from BOTH sides: what a
## seat must see, and what it must never see.

import std/[json, random, strformat, strutils]
import lane_helpers
import lane/[sim_types, observation, broadcast, llm, roster]

const RealNames = ["daveey", "daveey-1", "atari-57-highroller",
                   "atari-57-onecredit"]

proc testViewCarriesItsOwnLaneWhole() =
  ## The POSITIVE half: seat s's composed message contains EVERY tile, sprite
  ## and counter of ITS OWN lane. A view that hides half your own screen is as
  ## broken as one that leaks a rival's.
  var rng = initRand(1234)
  for episode in 0 ..< 200:
    let
      rom = RomNames[episode mod RomNames.len]
      config = testConfig(rom, 6000 + episode)
    var game = seatedSim(config)
    for row in randomActions(rng, 30 + episode mod 90):
      game.step(row)
    let seat = episode mod 4
    let view = parseJson(laneViewJson(game, seat, 5, 24, DefaultStance, false))
    let lane = game.lanes[seat]

    let screen = view{"screen_map"}
    check(screen.len == GridH, "screen_map is not 17 rows")
    for row in 0 ..< GridH:
      let line = screen[row].getStr()
      check(line.len == GridW, "a screen_map row is not 17 characters")
      for col in 0 ..< GridW:
        # Every tile is present: either its own glyph, or a sprite/avatar
        # standing on it, which is exactly what a CRT shows.
        let glyph = line[col]
        check(glyph in {'#', '.', ',', 'o', '=', 'X', ' ', '@', 'H', 'h', 'r',
                        'B', 'A', 'S', '^', 'v', '_'},
              &"unknown screen glyph {glyph}")
    check(view{"you"}{"points"}.getInt() == int(lane.points),
          "the view hides the lane's own points")
    check(view{"you"}{"lives"}.getInt() == int(lane.lives),
          "the view hides the lane's own lives")
    check(view{"you"}{"screen"}.getInt() == int(lane.screen),
          "the view hides the lane's own screen number")
    check(view{"you"}{"power_ticks_left"}.getInt() == int(lane.powerTicksLeft),
          "the view hides the lane's own power window")
    check(view{"you"}{"chain"}.getInt() == int(lane.chain),
          "the view hides the lane's own chain")
    var liveHostiles = 0
    for sprite in lane.sprites:
      if isHostile(sprite):
        inc liveHostiles
    let listed = view{"threats"}.len
    check(listed == liveHostiles,
          &"the view lists {listed} threats, the lane has {liveHostiles}")
  report("200 states: a seat's own lane is wholly present in its view")

proc testViewLeaksNothing() =
  ## The NEGATIVE half. Everything on this list has cost a coworld a round.
  var rng = initRand(4321)
  for episode in 0 ..< 200:
    let
      rom = RomNames[episode mod RomNames.len]
      config = testConfig(rom, 7000 + episode)
    var game = seatedSim(config)
    for seat in 0 ..< 4:
      game.seatNames[seat] = RealNames[seat]
      game.players[seat].address = RealNames[seat]
      game.seatPolicyKind[seat] = (if seat < 2: "llm" else: "scripted")
    for row in randomActions(rng, 40):
      game.step(row)
    for seat in 0 ..< 4:
      let message = userMessage(
        "my secret strategy: always bank",
        laneViewJson(game, seat, 5, 24, DefaultStance, false))
      # The seat's OWN prompt is in its own user message by construction (that
      # is what an operator block IS); nobody else's ever is.
      for other in 0 ..< 4:
        if other == seat:
          continue
        check(not message.contains(RealNames[other]),
              &"seat {seat}'s message names seat {other}'s policy")
      for token in [$config.seed, "rngDraws", "rngA", "rngB", "wallClock",
                    "elapsed_s", "turnBudget", "fallback", "policyKind",
                    "latency"]:
        check(not message.contains(token),
              &"seat {seat}'s message leaks `{token}`")
      for seatName in RealNames:
        if seatName == RealNames[seat]:
          continue
        check(not message.contains(seatName), "a real policy name leaked")
  report("200 states: no rival name, seed, RNG, wall clock or fallback state")

proc testAliasesInGameRealNamesSpectatorSide() =
  let config = testConfig(RomChomper, 5_140_913)
  var game = seatedSim(config)
  for seat in 0 ..< 4:
    game.seatNames[seat] = RealNames[seat]
    game.players[seat].address = RealNames[seat]
  for _ in 0 ..< 120:
    game.step(newSeq[uint8](4))
  # In game: aliases only.
  for seat in 0 ..< 4:
    let view = laneViewJson(game, seat, 1, 24, DefaultStance, false)
    check(view.contains(laneAlias(seat)),
          &"seat {seat}'s view does not carry its own alias")
    for name in RealNames:
      check(not view.contains(name),
            &"seat {seat}'s view carries the real name {name}")
  # Spectator side: real names, in the roster, the results and the endcard.
  game.finishGame(ReasonComplete, EndRuleFullTime)
  let chromeFrame = game.buildStateJson(
    newJArray(), true, 1, 2880, false, true, -1, -1)
  for name in RealNames:
    check(chromeFrame.contains(name),
          &"the chrome roster does not carry the real name {name}")
  let results = game.playerResultsJson()
  for name in RealNames:
    check(results.contains(name), &"results.names is missing {name}")
  let parsed = parseJson(results)
  let aliases = parsed{"aliases"}
  for i in 0 ..< aliases.len:
    check(aliases[i].getStr() == laneAlias(i),
          "results.aliases are not the four colours")
  report("aliases in game, real names in the roster, results and endcard")

proc testControlInputsAreStructurallyLimited() =
  ## `laneCommand`'s inputs are ONE lane's state, that lane's stance and the
  ## tick — it cannot reach a `SimServer`, a rival lane or the RNG even if
  ## somebody later wanted it to.
  let source = readRepoFile("src/lane/control.nim")
  let start = source.find("proc laneCommand*(")
  check(start >= 0, "laneCommand is gone")
  let signature = source[start .. source.find("): uint8 =", start)]
  for token in ["SimServer", "sim:", "lanes", "drawInt", "rng"]:
    check(not signature.contains(token),
          &"laneCommand's signature can see `{token}`")
  check(signature.contains("lane: Lane"), "laneCommand does not take one lane")
  check(signature.contains("stance: LaneStance"),
        "laneCommand does not take a stance")
  check(signature.contains("tick: int"), "laneCommand does not take the tick")
  report("laneCommand sees one lane, one stance and the tick")

when isMainModule:
  echo "test_locality"
  testViewCarriesItsOwnLaneWhole()
  testViewLeaksNothing()
  testAliasesInGameRealNamesSpectatorSide()
  testControlInputsAreStructurallyLimited()
  echo "test_locality OK"
