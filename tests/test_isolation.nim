## THE LANE INVARIANT. Four sealed lanes is the whole design; if any of these
## fails, a seat can reach another seat and the coworld is a different game.

import std/[json, random, strformat, strutils]
import lane_helpers
import lane/[sim_types, observation]

proc serializeLane(lane: Lane): string =
  ## Everything about one lane that a replay reproduces, as bytes, so "the
  ## other lanes did not move" is an exact statement rather than a spot check.
  result = $ord(lane.phase) & "|" & $lane.phaseTimer & "|" & $lane.lives &
    "|" & $lane.points & "|" & $lane.screen & "|" & $lane.overTick &
    "|" & $lane.lastScoreTick & "|" & $lane.ax & "|" & $lane.ay &
    "|" & $lane.facing & "|" & $lane.powerTicksLeft & "|" & $lane.chain &
    "|" & $lane.speedPermille & "|" & $lane.marchTicks & "|" & $lane.rngDraws &
    "|" & $lane.scoreMicro
  for i in 0 ..< GridCells:
    result.add($lane.tiles[i])
    result.add($lane.bunkerHp[i])
  for sprite in lane.sprites:
    result.add(&"|{ord(sprite.kind)},{ord(sprite.state)},{sprite.alive}," &
      &"{sprite.x},{sprite.y},{sprite.vx},{sprite.vy},{sprite.dir},{sprite.timer}")

proc testNeighbourStreamCannotReachYou() =
  ## (a) Replacing lane j's ENTIRE action-byte stream with a different stream
  ## leaves every other lane's per-tick state byte-identical.
  var rng = initRand(4242)
  for episode in 0 ..< 200:
    let
      rom = RomNames[episode mod RomNames.len]
      config = testConfig(rom, 1000 + episode)
    var base = randomActions(rng, 600)
    let victim = episode mod 4
    var edited = base
    for tick in 0 ..< edited.len:
      edited[tick][victim] = uint8(rng.rand(0 .. 14))

    var a = seatedSim(config)
    var b = seatedSim(config)
    for tick in 0 ..< base.len:
      a.step(base[tick])
      b.step(edited[tick])
      if tick mod 50 != 0 and tick != base.len - 1:
        continue
      for seat in 0 ..< 4:
        if seat == victim:
          continue
        check(serializeLane(a.lanes[seat]) == serializeLane(b.lanes[seat]),
              &"episode {episode} ({rom}): rewriting lane {victim}'s stream " &
              &"moved lane {seat} at tick {tick}")
  report("200 episodes: a neighbour's whole action stream cannot move you")

proc testOneLaneReproducesFourLane() =
  ## (b) Lane i run ALONE reproduces its four-lane trajectory exactly. This is
  ## what makes `stepLane` a pure function in practice and not just in
  ## signature.
  var rng = initRand(77)
  for episode in 0 ..< 30:
    let
      rom = RomNames[episode mod RomNames.len]
      config = testConfig(rom, 500 + episode)
      actions = randomActions(rng, 400)
    var four = seatedSim(config)
    for row in actions:
      four.step(row)
    for seat in 0 ..< 4:
      var solo: Lane
      initLane(solo, config.preset, config.seed)
      for tick in 0 ..< actions.len:
        discard stepLane(solo, actions[tick][seat], config.preset, tick,
                         config.preset.parScore)
      check(serializeLane(solo) == serializeLane(four.lanes[seat]),
            &"episode {episode} ({rom}): lane {seat} alone differs from its " &
            "four-lane trajectory")
  report("30 episodes: a lane run alone reproduces its four-lane trajectory")

proc testSameStreamSameOutcome() =
  ## (c) The FAIRNESS PROOF: four lanes fed the identical action-byte stream
  ## finish with identical points, lives, screens, sprite positions and draws.
  ## Same seed really does mean same challenge.
  var rng = initRand(31337)
  for rom in RomNames:
    for seed in [5_140_913, 7, 42]:
      let config = testConfig(rom, seed)
      var game = seatedSim(config)
      let actions = randomActions(rng, 900)
      for row in actions:
        var shared = newSeq[uint8](4)
        for seat in 0 ..< 4:
          shared[seat] = row[0]
        game.step(shared)
      for seat in 1 ..< 4:
        check(serializeLane(game.lanes[seat]) == serializeLane(game.lanes[0]),
              &"{rom} seed {seed}: lane {seat} diverged from lane 0 on one " &
              "shared action stream")
  report("one shared stream ⇒ four identical lanes, on every rom and seed")

proc testSourceGuards() =
  ## (d) `stepLane` takes no `SimServer`, and the sim module does not import
  ## the scoreboard composer. The invariant is enforced at the signature, not
  ## by hoping nobody reaches for it.
  let simSource = readRepoFile("src/lane/sim.nim")
  let signature = simSource[simSource.find("proc stepLane*(") ..
                            simSource.find("): seq[LaneEvent] =")]
  check(not signature.contains("SimServer"),
        "stepLane's signature can see a SimServer")
  check(not signature.contains("sim:"), "stepLane takes a sim argument")
  for line in simSource.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("import") or trimmed.startsWith("export"):
      check(not trimmed.contains("observation"),
            "src/lane/sim.nim imports the scoreboard composer")
  let controlSource = readRepoFile("src/lane/control.nim")
  let laneCmd = controlSource[controlSource.find("proc laneCommand*(") ..
                              controlSource.find("): uint8 =",
                                controlSource.find("proc laneCommand*("))]
  check(not laneCmd.contains("SimServer"),
        "laneCommand's inputs are not limited to one lane")
  report("stepLane takes no SimServer; sim.nim never imports observation")

proc testComposedMessageCarriesNoRivalDetail() =
  ## (e) The composed LLM user message for seat s carries NO other lane's
  ## tiles, sprites, avatar, targets, threats, stance, note, say or prompt —
  ## only the four {alias, score, lives, screen} scoreboard rows.
  var rng = initRand(90210)
  for episode in 0 ..< 200:
    let
      rom = RomNames[episode mod RomNames.len]
      config = testConfig(rom, 3000 + episode)
    var game = seatedSim(config)
    for row in randomActions(rng, 40 + episode mod 60):
      game.step(row)
    for seat in 0 ..< 4:
      let view = parseJson(
        laneViewJson(game, seat, 3, 24, DefaultStance, false))
      check(view{"you"}{"alias"}.getStr() == laneAlias(seat),
            "the view names the wrong lane")
      let board = view{"scoreboard"}
      check(board.len == 4, "the scoreboard is not four rows")
      for row in board:
        check(row.len == 4,
              "a scoreboard row carries more than {alias, score, lives, screen}")
        for key in ["alias", "score", "lives", "screen"]:
          check(row.hasKey(key), &"the scoreboard row is missing {key}")
      # Its own screen is fully present: 17 rows of 17 characters.
      let screen = view{"screen_map"}
      check(screen.len == GridH, "screen_map is not 17 rows")
      for line in screen:
        check(line.getStr().len == GridW, "a screen_map row is not 17 chars")
      # And nothing anywhere in the object names a rival's state.
      for key in ["rivals", "opponents", "lanes", "others", "seed", "rng"]:
        check(not view.hasKey(key), &"the view carries a `{key}` key")
  report("200 states: the composed view carries one lane and four score rows")

when isMainModule:
  echo "test_isolation"
  testNeighbourStreamCannotReachYou()
  testOneLaneReproducesFourLane()
  testSameStreamSameOutcome()
  testSourceGuards()
  testComposedMessageCarriesNoRivalDetail()
  echo "test_isolation OK"
