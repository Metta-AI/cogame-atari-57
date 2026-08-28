## RELEASE-ONLY. The bounded-orders / legality assertion on the scripted
## baselines, and the anti-regression pin on the whole difficulty tuning.
##
## If the baselines cannot clear a screen, the THREE BaselineParams numbers are
## wrong: re-run `tools/tune_baselines.nim`, commit the sweep's pick to
## `tools/ci/baseline_tuning.json`, and leave the ROM constants and the maps
## exactly where they are.

import std/[random, strformat]
import lane_helpers
import lane/[sim_types]

const
  ## Twenty seeds, fixed, so the pin is a property of the tuning and not of
  ## whichever seeds a rerun happened to draw.
  PinSeeds = [5_140_913, 7, 42, 909, 1234, 77_003, 31_337, 2, 90_210, 5,
              61, 808, 99, 1_000_003, 4_242, 51, 7_777, 123_456, 314_159,
              271_828]

proc testEmittedStancesAreLegal() =
  ## 500 pseudo-random world states x both baselines x all three ROMs: the
  ## emitted stance validates against the reply schema AND the compiled action
  ## byte is in 0..14 and decodes to a legal (dir, act) for that ROM.
  var rng = initRand(5_140_913)
  var checked = 0
  for rom in RomNames:
    let config = testConfig(rom, 5_140_913)
    let preset = config.preset
    for episode in 0 ..< 500:
      var game = seatedSim(config)
      for row in randomActions(rng, 5 + rng.rand(0 .. 200)):
        game.step(row)
      for kind in [blArcader, blHoover]:
        for seat in 0 ..< 4:
          let stance = scriptedStance(game, seat, kind)
          check(stance.riskMilli >= 0 and stance.riskMilli <= 1000,
                &"{rom}/{kind}: risk {stance.riskMilli} outside [0, 1000]")
          check(stance.leadTicks >= 0 and stance.leadTicks <= 48,
                &"{rom}/{kind}: lead_ticks {stance.leadTicks} outside [0, 48]")
          check(stance.note.len <= 4 * MaxNoteRunes,
                &"{rom}/{kind}: the note is over its cap")
          check(stance.say.len <= 4 * MaxSayRunes,
                &"{rom}/{kind}: the say is over its cap")
          check(stance.source == stScripted,
                &"{rom}/{kind}: a scripted stance is not marked scripted")
          var control = initControlLane()
          let cmd = laneCommand(control, game.lanes[seat], stance, preset,
                                game.tickCount)
          check(cmd <= 14'u8, &"{rom}/{kind}: illegal action byte {cmd}")
          let action = decodeAction(cmd)
          check(action.dir >= 0 and action.dir <= 4, "illegal dir")
          check(action.act >= 0 and action.act <= 2, "illegal act")
          if preset.avatarMode == amRailBottom:
            check(action.dir notin [1'i32, 2'i32],
                  &"{rom}: an up/down byte was emitted on a rail")
          if not preset.fireEnabled:
            check(action.act != 1,
                  &"{rom}: a fire byte was emitted with fireEnabled false")
          if not preset.brakeEnabled:
            check(action.act != 2,
                  &"{rom}: a brake byte was emitted with brakeEnabled false")
          inc checked
  report(&"{checked} baseline stances are legal and compile to a legal byte")

proc testArcaderPlaysARealArcadeRun() =
  ## THE ANTI-REGRESSION PIN. Four `arcader`s must clear screens and bank real
  ## points; if this fails, the tuning moved.
  var
    seedsWithScreen: array[3, int]
    meanPoints: array[3, int]
  for romIndex, rom in RomNames:
    var total = 0
    for seed in PinSeeds:
      let run = runScripted(testConfig(rom, seed))
      var points = 0
      var screens = 0
      for seat in 0 ..< 4:
        points += int(run.finalPoints[seat])
        screens += int(run.screens[seat])
      total += points div 4
      if screens > 0:
        inc seedsWithScreen[romIndex]
    meanPoints[romIndex] = total div PinSeeds.len
    report(&"{rom}: mean {meanPoints[romIndex]} points, a screen cleared on " &
           &"{seedsWithScreen[romIndex]}/{PinSeeds.len} seeds")
  # chomper is the cartridge the tuning is FOR: it must clear almost always.
  check(seedsWithScreen[0] >= 16,
        &"chomper cleared a screen on only {seedsWithScreen[0]}/20 seeds")
  check(meanPoints[0] >= 3000, &"chomper mean points {meanPoints[0]} < 3000")
  # brickfall's wall is 1650 points and 2880 ticks of ball travel is not quite
  # enough to finish it, so the pin is on POINTS, not on a clear.
  check(meanPoints[1] >= 900, &"brickfall mean points {meanPoints[1]} < 900")
  # gallery is the hardest of the three; a wave is cleared on a real minority
  # of seeds and that is the pin.
  check(seedsWithScreen[2] >= 3,
        &"gallery cleared a wave on only {seedsWithScreen[2]}/20 seeds")
  check(meanPoints[2] >= 300, &"gallery mean points {meanPoints[2]} < 300")
  var overall = 0
  for value in meanPoints:
    overall += value
  check(overall div 3 >= 1400,
        &"the three-ROM mean is {overall div 3} points, under 1400")
  report(&"four arcaders bank {overall div 3} mean points across the three roms")

proc testHooverIsWeakerAndDiesMore() =
  ## The ladder needs a SPREAD: `hoover` never dodges, so it must score less
  ## and die more, and an `arcader` must usually win a mixed board.
  var
    arcaderPoints = 0
    hooverPoints = 0
    arcaderDeaths = 0
    hooverDeaths = 0
    arcaderWins = 0
  for rom in [RomChomper, RomGallery]:
    for seed in PinSeeds:
      let run = runScripted(testConfig(rom, seed),
                            [blArcader, blArcader, blHoover, blHoover])
      arcaderPoints += int(run.finalPoints[0] + run.finalPoints[1]) div 2
      hooverPoints += int(run.finalPoints[2] + run.finalPoints[3]) div 2
      arcaderDeaths += int(run.deaths[0] + run.deaths[1])
      hooverDeaths += int(run.deaths[2] + run.deaths[3])
      if run.finalPoints[0] >= run.finalPoints[2] and
         run.finalPoints[0] >= run.finalPoints[3]:
        inc arcaderWins
  check(arcaderPoints > hooverPoints,
        &"arcader banked {arcaderPoints}, hoover {hooverPoints} — the two " &
        "baselines are not distinguishable")
  check(hooverDeaths >= arcaderDeaths,
        &"hoover died {hooverDeaths} times, arcader {arcaderDeaths} — the " &
        "weak baseline is not dying more")
  check(arcaderWins >= 2 * PinSeeds.len * 3 div 4,
        &"an arcader seat led only {arcaderWins}/{2 * PinSeeds.len} mixed boards")
  report(&"arcader {arcaderPoints} vs hoover {hooverPoints} points, " &
         &"{arcaderDeaths} vs {hooverDeaths} deaths, {arcaderWins} boards led")

when isMainModule:
  echo "test_baselines"
  testEmittedStancesAreLegal()
  testArcaderPlaysARealArcadeRun()
  testHooverIsWeakerAndDiesMore()
  echo "test_baselines OK"
