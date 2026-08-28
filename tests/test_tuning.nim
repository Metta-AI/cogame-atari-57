## The three `BaselineParams` numbers are a PARAMETER rather than a literal
## because they were chosen by a grid sweep, not guessed. This asserts the
## shipped defaults still equal the sweep's recorded pick — so a hand-edit to
## the tuning either comes with a re-run of the sweep, or fails here.

import std/[json, strformat]
import lane_helpers
import lane/[baselines]

proc testShippedDefaultsMatchTheSweep() =
  let recorded = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
  let pick = recorded{"pick"}
  check(not pick.isNil, "tools/ci/baseline_tuning.json records no pick")
  let shipped = DefaultBaselineParams
  let sweptPanic = pick{"panicTicks"}.getInt()
  check(sweptPanic == int(shipped.panicTicks),
        &"panicTicks: shipped {shipped.panicTicks}, sweep picked {sweptPanic}")
  check(pick{"riskMilli"}.getInt() == int(shipped.riskMilli),
        &"riskMilli: shipped {shipped.riskMilli}")
  check(pick{"leadTicks"}.getInt() == int(shipped.leadTicks),
        &"leadTicks: shipped {shipped.leadTicks}")
  let cells = recorded{"grid"}.len
  check(cells >= 24, &"the recorded sweep only covered {cells} cells")
  var better = 0
  for cell in recorded{"grid"}:
    if cell{"screensCleared"}.getInt() > pick{"screensCleared"}.getInt():
      inc better
  check(better == 0, &"{better} swept cells beat the recorded pick")
  report(&"the shipped defaults are the sweep's pick " &
         &"(panic {shipped.panicTicks}, risk {shipped.riskMilli}, " &
         &"lead {shipped.leadTicks})")

when isMainModule:
  echo "test_tuning"
  testShippedDefaultsMatchTheSweep()
  echo "test_tuning OK"
