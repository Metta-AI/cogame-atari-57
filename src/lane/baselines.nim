## The two published scripted baselines.
##
## Both emit the SAME stance object an LLM does, on the same 120-tick
## cadence, so their output is legal by construction and directly comparable,
## and both are pure functions of the observation a seat would receive. That
## is what makes the bounded-orders assertion in `tests/test_baselines.nim`
## meaningful.
##
## Inherited from `coworld-ctf`'s `src/ctf/baselines.nim`: the shape (a
## `Baseline` enum, a `parseBaseline` that resolves anything unrecognised to
## the DEFAULT rather than sitting the seat out, and a `BaselineParams`
## object rather than literals, because these three numbers were CHOSEN by a
## grid sweep — `tools/tune_baselines.nim` — not guessed).
##
## `arcader` is load-bearing in four places: the certification player, the
## per-turn fallback when a seat's LLM call fails twice, the driver of a
## no-show's lane, and the default for a seat that registers with neither
## `PLAYER_PROMPT` nor `PLAYER_SCRIPTED`.

import std/[json, strutils]
import sim, stances, observation

type
  Baseline* = enum
    blArcader = "arcader"
    blHoover = "hoover"

  BaselineParams* = object
    ## The three tunables. `tools/tune_baselines.nim` sweeps them over a
    ## bounded grid, `tools/ci/baseline_tuning.json` records the sweep's pick
    ## and `tests/test_tuning.nim` asserts the shipped defaults still equal
    ## it. The ROM constants are NOT swept: if the baselines cannot clear a
    ## screen, these three numbers move, not the game.
    panicTicks*: int32     ## bail when the nearest threat is this close.
    riskMilli*: int32      ## the default risk an unpressured turn takes.
    leadTicks*: int32      ## how long a chosen route is committed to.

const DefaultBaselineParams* = BaselineParams(
  ## The grid harness's pick, not a guess. `tools/tune_baselines.nim` plays
  ## four `arcader`s over 4 x 3 x 3 cells of these three numbers across all
  ## three ROMs and six seeds; this cell banks 1842 mean points and clears a
  ## screen in 8 of its 18 episodes, where the design note's first guess
  ## (panic 28, lead 14) banks 1822 and the timid cells (risk 300) clear
  ## NOTHING at all. `tools/ci/baseline_tuning.json` records the whole grid
  ## and `tests/test_tuning.nim` re-asserts these three numbers against it.
  panicTicks: 20,
  riskMilli: 500,
  leadTicks: 10
)

const ArcaderSayings* = [
  "clearing",
  "chain time",
  "backing off",
  "power up",
  "screen's mine"
]

proc parseBaseline*(text: string): Baseline =
  ## `PLAYER_SCRIPTED` values. Anything unrecognised is `arcader`: a seat that
  ## says nothing useful still plays the published default rather than
  ## sitting out.
  case text.strip().toLowerAscii()
  of "hoover", "hoov", "greedy": blHoover
  else: blArcader

type
  BaselineTarget = object
    kind: string
    distTicks, value: int
    zone: Zone
  BaselineView = object
    over: bool
    lives, powerTicksLeft, nearestEta: int
    targets: seq[BaselineTarget]

proc baselineView(view: JsonNode): BaselineView =
  ## The wire uses -1 for an unreachable ETA; restore the controller sentinel.
  let you = view["you"]
  result.over = you["state"].getStr() == "over"
  result.lives = you["lives"].getInt()
  result.powerTicksLeft = you["power_ticks_left"].getInt()
  result.nearestEta = FarEta
  if view["threats"].len > 0:
    let eta = view["threats"][0]["eta_ticks"].getInt()
    result.nearestEta = if eta == -1: FarEta.int else: eta
  for target in view["targets"]:
    let distance = target["dist_ticks"].getInt()
    result.targets.add(BaselineTarget(kind: target["kind"].getStr(),
      distTicks: (if distance == -1: FarEta.int else: distance),
      value: target["value"].getInt(), zone: parseZone(target["zone"].getStr())))

proc arcaderStance(
  view: BaselineView, params = DefaultBaselineParams
): LaneStance =
  ## One chooser shared by the hosted baseline and its private-view teacher.
  result = DefaultStance
  result.source = stScripted
  result.fire = fmAuto
  result.leadTicks = params.leadTicks
  result.riskMilli = params.riskMilli
  result.zone = znNone

  if view.over:
    result.mode = mdSafe
    result.riskMilli = 0
    result.leadTicks = 12
    result.fire = fmNever
    result.note = "the credit is spent"
    result.say = ArcaderSayings[2]
    return

  if view.powerTicksLeft > 48'i32:
    result.mode = mdStrike
    result.riskMilli = 850
    result.leadTicks = 10
    result.note = "power window open: cash the chain"
    result.say = ArcaderSayings[1]
  elif view.nearestEta <= params.panicTicks:
    result.mode = mdSafe
    result.riskMilli = 150
    result.leadTicks = 8
    result.note = "threat inside " & $params.panicTicks & " ticks: survive first"
    result.say = ArcaderSayings[2]
  else:
    var
      power = (found: false, zone: znNone)
      bestZone = znNone
      bestValue = -1
    for target in view.targets:
      if target.kind == "power" and target.distTicks <= 72'i32 and
          not power.found:
        power = (true, target.zone)
      if target.value > bestValue:
        bestValue = target.value
        bestZone = target.zone
    if power.found:
      result.mode = mdHunt
      result.zone = power.zone
      result.leadTicks = 16
      result.note = "power pellet in reach"
      result.say = ArcaderSayings[3]
    else:
      result.mode = mdClear
      result.zone = bestZone
      result.leadTicks = 14
      result.note = "take the nearest scoring thing"
      result.say = ArcaderSayings[0]

  # The last-life override applies in EVERY branch.
  if view.lives == 1'i32:
    result.riskMilli = result.riskMilli div 2
    if result.mode == mdHunt:
      result.mode = mdClear
    result.say = ArcaderSayings[4]

proc arcaderStance*(view: JsonNode, params = DefaultBaselineParams): LaneStance =
  arcaderStance(baselineView(view), params)

proc arcaderStance*(sim: SimServer, seat: int,
    params = DefaultBaselineParams): LaneStance =
  ## Project only the fields present in the issued private observation.
  let lane = sim.lanes[seat]
  var view = BaselineView(over: lane.phase == lpOver, lives: lane.lives,
    powerTicksLeft: lane.powerTicksLeft, nearestEta: FarEta)
  let threats = laneThreats(lane, sim.config.preset)
  if threats.len > 0: view.nearestEta = threats[0].etaTicks
  for target in laneTargets(lane, sim.config.preset):
    view.targets.add(BaselineTarget(kind: target.kind, distTicks: target.distTicks,
      value: target.value, zone: parseZone(target.zone)))
  arcaderStance(view, params)

proc hooverStance*(sim: SimServer, seat: int): LaneStance =
  ## The second filler, deliberately different in SHAPE and weaker: it never
  ## dodges. It banks points fast and dies fast, which gives the ladder a
  ## spread and gives a champion a visibly different neighbour on the
  ## momentum graph.
  result = DefaultStance
  result.source = stScripted
  if sim.lanes[seat].phase == lpOver:
    result.mode = mdSafe
    result.riskMilli = 0
    result.leadTicks = 12
    result.fire = fmNever
    result.note = "the credit is spent"
    return
  result.mode = mdClear
  result.zone = znNone
  result.riskMilli = 1000
  result.leadTicks = 24
  result.fire = fmAuto
  result.note = "everything on the screen, in order, no dodging"
  result.say = "vacuum"

proc scriptedStance*(
  sim: SimServer, seat: int, kind: Baseline,
  params = DefaultBaselineParams
): LaneStance =
  case kind
  of blHoover: hooverStance(sim, seat)
  of blArcader: arcaderStance(sim, seat, params)
