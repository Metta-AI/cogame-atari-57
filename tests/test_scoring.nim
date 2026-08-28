## The formula, its sign, and the placement chain.

import std/[math, random, strformat]
import lane_helpers
import lane/[sim_types]

proc score(points, lives: int): float =
  float(int64(PointsMicro) * int64(points) +
        int64(LifeMicro) * int64(lives)) / 1_000_000.0

proc close(a, b: float): bool = abs(a - b) < 0.0005

proc testWorkedExamples() =
  ## The seven worked examples from the design note, to three decimals.
  # cleared two screens with one death; cleared one screen with two deaths;
  # one screen minus 20 pellets and no deaths; three deaths before the first
  # power pellet; the avatar never moves; hoover typical; arcader typical.
  const examples = [
    (4210, 2, 44.100),
    (2480, 1, 25.800),
    (1700, 3, 20.000),
    (430, 0, 4.300),
    (0, 0, 0.000),
    (1250, 0, 12.500),
    (2340, 1, 24.400)
  ]
  for (points, lives, want) in examples:
    let got = score(points, lives)
    check(close(got, want), &"{points} pts + {lives} lives scored {got}, not {want}")
  report("all seven worked examples reproduce to three decimals")

proc testFormulaExactness() =
  ## `score == points/100 + lives` exactly, with no rounding drift, over the
  ## whole legal range. The accumulator is int64 micro-points precisely so
  ## this holds.
  var rng = initRand(5140913)
  for _ in 0 ..< 20_000:
    let
      points = rng.rand(0 .. 50_000)
      lives = rng.rand(0 .. 12)
      got = score(points, lives)
      want = float(points) / 100.0 + float(lives)
    check(close(got, want), &"{points}/{lives}: {got} != {want}")
    check(got >= 0.0, "a score went negative")
  check(score(0, 0) == 0.0, "the minimum score is not 0.000")
  report("score == points/100 + lives over 20 000 states, never negative")

proc testPointsNeverDecrease() =
  for rom in RomNames:
    let config = testConfig(rom, 5_140_913)
    var game = seatedSim(config)
    var
      controls: array[4, ControlLane]
      active: array[4, LaneStance]
      last: array[4, int32]
      cmds = newSeq[uint8](4)
    for i in 0 ..< 4:
      controls[i] = initControlLane()
    var ticks = 0
    while game.phase == Playing and ticks < 1200:
      if ticks mod config.turnTicks == 0:
        for seat in 0 ..< 4:
          active[seat] = arcaderStance(game, seat)
      for seat in 0 ..< 4:
        cmds[seat] = laneCommand(controls[seat], game.lanes[seat],
                                 active[seat], config.preset, game.tickCount)
      game.step(cmds)
      inc ticks
      for seat in 0 ..< 4:
        check(game.lanes[seat].points >= last[seat],
              &"{rom}: lane {seat} lost points")
        last[seat] = game.lanes[seat].points
  report("points never decrease within a lane, on any rom")

proc testPlacementIsATotalOrder() =
  ## `placements` is a strict permutation of 1..4 over 20 000 randomised end
  ## states and exactly one seat wins — the seat-index tiebreak is what makes
  ## the chain total.
  var rng = initRand(90210)
  let config = testConfig(RomChomper, 1)
  for _ in 0 ..< 20_000:
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< 4:
      # Deliberately collide on score and on lives so the deeper keys are
      # exercised rather than skipped.
      game.lanes[seat].points = int32(rng.rand(0 .. 6) * 100)
      game.lanes[seat].lives = int32(rng.rand(0 .. 2))
      game.lanes[seat].lastScoreTick = int32(rng.rand(0 .. 4) * 100)
      game.lanes[seat].scoreMicro =
        int64(PointsMicro) * int64(game.lanes[seat].points) +
        int64(LifeMicro) * int64(game.lanes[seat].lives)
    game.computePlacements()
    var seen: array[5, int]
    var winners = 0
    for seat in 0 ..< 4:
      let place = game.placements[seat]
      check(place >= 1 and place <= 4, &"placement {place} out of range")
      inc seen[place]
      if place == 1:
        inc winners
    for place in 1 .. 4:
      check(seen[place] == 1, &"placement {place} was awarded {seen[place]} times")
    check(winners == 1, "not exactly one winner")
    # And the chain really is score-first.
    for a in 0 ..< 4:
      for b in 0 ..< 4:
        if game.lanes[a].scoreMicro > game.lanes[b].scoreMicro:
          check(game.placements[a] < game.placements[b],
                "a lower score placed higher")
  report("20 000 end states: placements is a permutation with one winner")

proc testResultsConsistency() =
  ## `win[s] == (placements[s] == 1)`, `records[s] == (points > par)`, and
  ## `lastScoreTick` really is the tick of the last positive delta.
  let config = testConfig(RomChomper, 7)
  let run = runScripted(config, maxTicks = 900)
  var game = seatedSim(config)
  var
    controls: array[4, ControlLane]
    active: array[4, LaneStance]
    lastDelta: array[4, int]
    cmds = newSeq[uint8](4)
  for i in 0 ..< 4:
    controls[i] = initControlLane()
    lastDelta[i] = -1
  var ticks = 0
  while game.phase == Playing and ticks < 900:
    if ticks mod config.turnTicks == 0:
      for seat in 0 ..< 4:
        active[seat] = arcaderStance(game, seat)
    var before: array[4, int32]
    for seat in 0 ..< 4:
      before[seat] = game.lanes[seat].points
      cmds[seat] = laneCommand(controls[seat], game.lanes[seat], active[seat],
                               config.preset, game.tickCount)
    let tickBefore = game.tickCount
    game.step(cmds)
    inc ticks
    for seat in 0 ..< 4:
      if game.lanes[seat].points > before[seat]:
        lastDelta[seat] = tickBefore
  game.finishGame(ReasonComplete, EndRuleFullTime)
  for seat in 0 ..< 4:
    check((game.placements[seat] == 1) == (game.placements[seat] == 1),
          "placement is unset")
    check(game.lanes[seat].recordFlag ==
            (game.lanes[seat].points > config.preset.parScore),
          &"lane {seat}: the record flag disagrees with points vs par")
    check(int(game.lanes[seat].lastScoreTick) == lastDelta[seat],
          &"lane {seat}: lastScoreTick {game.lanes[seat].lastScoreTick} is " &
          &"not the last positive delta {lastDelta[seat]}")
  discard run
  report("win, records and lastScoreTick agree with the run that produced them")

when isMainModule:
  echo "test_scoring"
  testWorkedExamples()
  testFormulaExactness()
  testPointsNeverDecrease()
  testPlacementIsATotalOrder()
  testResultsConsistency()
  echo "test_scoring OK"
