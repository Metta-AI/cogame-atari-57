## The baseline tuning harness.
##
## The three `BaselineParams` numbers are a PARAMETER rather than a literal
## because they were chosen by this sweep, not guessed — exactly as
## `coworld-ctf`'s `tools/tune_baselines.nim` chooses `holdline`'s. It plays
## four `arcader`s over a bounded grid of the three tunables across every ROM
## and a fixed seed set, prints the table, and writes the winning cell to
## `tools/ci/baseline_tuning.json`. `tests/test_tuning.nim` re-asserts that
## the shipped `DefaultBaselineParams` still equals what is recorded there.
##
##   nim c -d:release -r tools/tune_baselines.nim            # sweep and print
##   nim c -d:release -r tools/tune_baselines.nim --check    # verify only
##   nim c -d:release -r tools/tune_baselines.nim --write    # re-record
##
## The ROM constants in the design note are NOT swept and are not tunable by
## this harness: if the baselines cannot clear a screen, these three numbers
## move, not the game.

import std/[json, os, strformat, strutils]
import lane/[sim, stances, control, baselines]

const
  TuningPath = "tools/ci/baseline_tuning.json"
  SweepSeeds = [5_140_913, 7, 42, 909, 1234, 77_003]
  PanicGrid = [20'i32, 28, 36, 44]
  RiskGrid = [300'i32, 500, 700]
  LeadGrid = [10'i32, 14, 20]

type Outcome = object
  points: int
  screens: int
  deaths: int

proc playEpisode(rom: string, seed: int, params: BaselineParams): Outcome =
  var config = defaultGameConfig()
  config.update($(%*{"rom": rom, "seed": seed, "minPlayers": 1}))
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  discard game.addPlayer("P1", 0, "", trusted = true)
  game.startGame()
  var
    ctl: array[4, ControlLane]
    stances: array[4, LaneStance]
    cmds = newSeq[uint8](4)
  for i in 0 ..< 4:
    ctl[i] = initControlLane()
  while game.phase == Playing:
    if game.gameTicksElapsed() mod config.turnTicks == 0:
      for seat in 0 ..< 4:
        stances[seat] = arcaderStance(game, seat, params)
    for seat in 0 ..< 4:
      cmds[seat] = laneCommand(
        ctl[seat], game.lanes[seat], stances[seat], config.preset,
        game.tickCount)
    game.step(cmds)
  for seat in 0 ..< 4:
    result.points += int(game.lanes[seat].points)
    result.screens += int(game.lanes[seat].screensCleared)
    result.deaths += int(game.lanes[seat].deaths)
  result.points = result.points div 4
  result.screens = result.screens div 4

proc scoreParams(params: BaselineParams): tuple[points, screens: int] =
  for rom in RomNames:
    for seed in SweepSeeds:
      let outcome = playEpisode(rom, seed, params)
      result.points += outcome.points
      result.screens += outcome.screens
  result.points = result.points div (RomNames.len * SweepSeeds.len)

proc paramsJson(params: BaselineParams, points, screens: int): JsonNode =
  %*{
    "panicTicks": params.panicTicks,
    "riskMilli": params.riskMilli,
    "leadTicks": params.leadTicks,
    "meanPoints": points,
    "screensCleared": screens,
    "seeds": SweepSeeds.len,
    "roms": RomNames.len
  }

when isMainModule:
  let args = commandLineParams()
  if "--check" in args:
    if not fileExists(TuningPath):
      quit("missing " & TuningPath, 1)
    let recorded = parseFile(TuningPath)
    let shipped = DefaultBaselineParams
    if recorded{"pick"}{"panicTicks"}.getInt() != int(shipped.panicTicks) or
        recorded{"pick"}{"riskMilli"}.getInt() != int(shipped.riskMilli) or
        recorded{"pick"}{"leadTicks"}.getInt() != int(shipped.leadTicks):
      quit("shipped DefaultBaselineParams disagrees with " & TuningPath, 1)
    echo "baseline tuning matches the recorded sweep pick"
    quit(0)

  var
    grid = newJArray()
    best = DefaultBaselineParams
    bestPoints = -1
    bestScreens = -1
  for panic in PanicGrid:
    for risk in RiskGrid:
      for lead in LeadGrid:
        let params = BaselineParams(
          panicTicks: panic, riskMilli: risk, leadTicks: lead)
        let outcome = scoreParams(params)
        grid.add(paramsJson(params, outcome.points, outcome.screens))
        echo &"panic={panic} risk={risk} lead={lead} " &
          &"meanPoints={outcome.points} screens={outcome.screens}"
        if outcome.screens > bestScreens or
            (outcome.screens == bestScreens and outcome.points > bestPoints):
          bestScreens = outcome.screens
          bestPoints = outcome.points
          best = params
  echo &"pick: panic={best.panicTicks} risk={best.riskMilli} " &
    &"lead={best.leadTicks} meanPoints={bestPoints} screens={bestScreens}"
  if "--write" in args:
    writeFile(TuningPath, $(%*{
      "pick": paramsJson(best, bestPoints, bestScreens),
      "grid": grid
    }) & "\n")
    echo "wrote ", TuningPath
