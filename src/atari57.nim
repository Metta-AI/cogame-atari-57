## The cabinet entrypoint (`/bin/atari-57`).
##
## `coworld-ctf`'s `src/ctf.nim`, kept: the seed is randomised HERE, BEFORE
## `config.update`, so every seed-derived draw — and the resolved ROM preset
## the replay pins — follows the FINAL seed. Nim module names may not contain
## `-`, so this file is `atari57.nim` while the built binary is
## `/bin/atari-57` and every manifest, compose and slug string is `atari-57`.

import
  std/[json, os, sysrand],
  bitworld/runtime,
  lane/sim,
  lane/server

proc seedPinned(configJson: string): bool =
  ## True when the runtime config EXPLICITLY names a seed (the certification
  ## fixture, a forensic re-run, a recorded test). A hosted variant names
  ## none, so every league episode draws a fresh one — with a public fixed
  ## seed the scatter flips, serve angles and marcher volleys would all be
  ## pre-computable by an opponent.
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false  # config.update reports the real parse error.

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(LaneError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("atari-57-replay-" & $getCurrentProcessId() & ".replay")
      else:
        ""

  var config = defaultGameConfig()
  try:
    if seedPinned(runtimeConfig.config):
      config.update(runtimeConfig.config)
    else:
      config.seed = randomSeed()
      config.update(stripUnpinnedSeed(runtimeConfig.config))
      echo "seed not pinned; randomized"
  except LaneError as error:
    ## A clean message and a non-zero exit, never a traceback: a malformed
    ## COGAME_CONFIG_URI is an operator problem, not a crash report.
    stderr.writeLine("atari-57: bad game config: " & error.msg)
    quit(2)

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("atari-57-load-" & $getCurrentProcessId() &
        ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "atari-57 config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " rom=", config.rom,
    " num_agents=", config.numAgents,
    " maxTicks=", config.maxTicks,
    " minTicks=", config.minTicks,
    " turnTicks=", config.turnTicks,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds
  echo "starting atari-57 on ", runtimeConfig.host, ":", runtimeConfig.port
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    "",
    runtimeConfig
  )
