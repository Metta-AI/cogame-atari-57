## RELEASE-ONLY. The whole episode — 2880 ticks x 4 lanes of physics plus
## 11 520 autopilot evaluations — inside a bound that a CI runner comfortably
## meets. The design target is under 5 s; the bound is 60 s, so this fails on a
## real regression and not on a busy runner.

import std/[monotimes, strformat, times]
import lane_helpers
import lane/[sim_types]

proc testFullEpisodeIsFast() =
  let config = testConfig(RomChomper, 5_140_913)
  check(config.maxTicks == 2880, "the perf run is not a full episode")
  var game = seatedSim(config)
  var
    controls: array[4, ControlLane]
    active: array[4, LaneStance]
    cmds = newSeq[uint8](4)
    autopilotCalls = 0
  for i in 0 ..< 4:
    controls[i] = initControlLane()
  let started = getMonoTime()
  while game.phase == Playing:
    if game.gameTicksElapsed() mod config.turnTicks == 0:
      for seat in 0 ..< 4:
        active[seat] = arcaderStance(game, seat)
    for seat in 0 ..< 4:
      cmds[seat] = laneCommand(controls[seat], game.lanes[seat], active[seat],
                               config.preset, game.tickCount)
      inc autopilotCalls
    game.step(cmds)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check(autopilotCalls >= 4 * 2000,
        &"only {autopilotCalls} autopilot evaluations — the run was short")
  check(elapsed < 60_000,
        &"a full episode took {elapsed} ms against a 60 000 ms bound")
  report(&"{game.tickCount} ticks x 4 lanes + {autopilotCalls} autopilot " &
         &"evaluations in {elapsed} ms")

proc testEveryRomIsFast() =
  for rom in RomNames:
    let config = testConfig(rom, 42)
    let started = getMonoTime()
    let run = runScripted(config)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check(elapsed < 60_000,
          &"{rom} took {elapsed} ms against a 60 000 ms bound")
    report(&"{rom}: {run.hashes.len} ticks in {elapsed} ms")

when isMainModule:
  echo "test_perf"
  testFullEpisodeIsFast()
  testEveryRomIsFast()
  echo "test_perf OK"
