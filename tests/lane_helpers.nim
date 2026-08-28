## Shared test helpers: one scripted episode driver, used by every test that
## needs a real run rather than a synthetic state.

import std/[json, os, random]
import lane/[sim, stances, control, baselines]

export sim, stances, control, baselines

const TestSeeds* = [5_140_913, 7, 42, 909, 1234, 77_003]

proc testConfig*(rom = RomChomper, seed = 5_140_913, extra: JsonNode = nil): GameConfig =
  ## A four-seat config with the lobby out of the way, so a test spends its
  ## time on the game and not on the countdown.
  var node = %*{
    "rom": rom,
    "seed": seed,
    "num_agents": 4,
    "minPlayers": 1,
    "startWaitTicks": 0,
    "gameOverTicks": 1,
    "players": [{"name": "P1"}, {"name": "P2"}, {"name": "P3"}, {"name": "P4"}],
    "slots": [{"alias": "RED"}, {"alias": "BLUE"}, {"alias": "GREEN"},
              {"alias": "YELLOW"}]
  }
  if not extra.isNil:
    for key, value in extra:
      node[key] = value
  result = defaultGameConfig()
  result.update($node)

proc seatedSim*(config: GameConfig): SimServer =
  ## A sim with four trusted seats already joined and the credit inserted.
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< 4:
    discard result.addPlayer("P" & $(seat + 1), seat, "", trusted = true)
  result.startGame()

type ScriptedRun* = object
  actions*: seq[seq[uint8]]     ## per tick, one action byte per seat
  hashes*: seq[uint64]
  finalPoints*: array[4, int32]
  finalLives*: array[4, int32]
  screens*: array[4, int32]
  deaths*: array[4, int32]
  reason*, endRule*: string
  ticks*: int

proc runScripted*(
  config: GameConfig,
  kinds: array[4, Baseline] = [blArcader, blArcader, blArcader, blArcader],
  maxTicks = 0,
  recordActions = false
): ScriptedRun =
  ## Plays one whole episode with the scripted layer, exactly as the server
  ## would: a stance per seat every `turnTicks`, an action byte per seat every
  ## tick, and `sim.step` over those bytes.
  var game = seatedSim(config)
  var
    controls: array[4, ControlLane]
    active: array[4, LaneStance]
    cmds = newSeq[uint8](4)
  for i in 0 ..< 4:
    controls[i] = initControlLane()
  let limit = (if maxTicks > 0: maxTicks else: config.maxTicks + 64)
  while game.phase == Playing and game.gameTicksElapsed() < limit:
    if game.gameTicksElapsed() mod config.turnTicks == 0:
      for seat in 0 ..< 4:
        active[seat] = scriptedStance(game, seat, kinds[seat])
    for seat in 0 ..< 4:
      cmds[seat] = laneCommand(
        controls[seat], game.lanes[seat], active[seat], config.preset,
        game.tickCount)
    if recordActions:
      result.actions.add(cmds)
    game.step(cmds)
    result.hashes.add(game.gameHash())
  for seat in 0 ..< 4:
    result.finalPoints[seat] = game.lanes[seat].points
    result.finalLives[seat] = game.lanes[seat].lives
    result.screens[seat] = game.lanes[seat].screensCleared
    result.deaths[seat] = game.lanes[seat].deaths
  result.reason = game.endReason
  result.endRule = game.endRule
  result.ticks = game.tickCount

proc replayActions*(
  config: GameConfig, actions: seq[seq[uint8]]
): seq[uint64] =
  ## Re-steps a fresh sim from a recorded action log — the operation the wasm
  ## viewer performs on every frame.
  var game = seatedSim(config)
  for cmds in actions:
    game.step(cmds)
    result.add(game.gameHash())

proc randomActions*(rng: var Rand, ticks: int): seq[seq[uint8]] =
  for _ in 0 ..< ticks:
    var row = newSeq[uint8](4)
    for seat in 0 ..< 4:
      row[seat] = uint8(rng.rand(0 .. 14))
    result.add(row)

proc repoRoot*(): string =
  ## Tests run from the repo root (assets resolve via `data/`), but resolve it
  ## from this file so a stray working directory fails loudly rather than
  ## silently skipping an assertion.
  currentSourcePath().parentDir().parentDir()

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc check*(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc report*(name: string) =
  echo "  ok  ", name
