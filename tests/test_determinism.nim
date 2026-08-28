## THE GATE. If this test fails, the physics or a build flag changed — fix the
## code, never the test.
##
## Replays are re-simulated by the emscripten/wasm32 build of the very same
## module the native amd64 server ran, and their per-tick `gameHash` chains
## must agree bit for bit. Everything here exists to make that true by
## construction rather than by an argument about two builds of libm agreeing.

import std/[json, os, random, strformat, strutils]
import lane_helpers
import lane/[sim_types, grid]

const SimModules = [
  "sim.nim", "grid.nim", "rom.nim", "maps.nim", "sprites.nim",
  "sim_types.nim", "sim_config.nim", "sim_state.nim"
]

proc isWordChar(ch: char): bool {.inline.} =
  ch.isAlphaNumeric or ch == '_'

proc hasToken(body, token: string): bool =
  ## A whole-identifier search: `float` must fire on `float32` too (it is in
  ## the list itself), but `sin` must NOT fire on `using` or `Missing`.
  var start = 0
  while true:
    let at = body.find(token, start)
    if at < 0:
      return false
    let
      beforeOk = at == 0 or not isWordChar(body[at - 1])
      after = at + token.len
      afterOk = after >= body.len or not isWordChar(body[after])
    if beforeOk and afterOk:
      return true
    start = at + 1

proc stripComments(source: string): string =
  ## Only CODE is searched: the modules document the very hazards they must
  ## not contain, so a naive grep would fail on its own doc comment.
  for line in source.splitLines():
    let hash = line.find('#')
    result.add(if hash >= 0: line[0 ..< hash] else: line)
    result.add('\n')

proc testSameLogSameHashes() =
  ## (a) Same seed + same ROM + same action-byte log ⇒ identical gameHash at
  ## every tick, twice in one process and once in a fresh sim.
  for rom in RomNames:
    let config = testConfig(rom, 5_140_913)
    let first = runScripted(config, recordActions = true)
    let second = runScripted(config, recordActions = true)
    check(first.hashes == second.hashes,
          &"{rom}: two runs of one seed produced different hash chains")
    check(first.actions == second.actions,
          &"{rom}: two runs of one seed produced different action logs")
    let replayed = replayActions(config, first.actions)
    check(replayed == first.hashes,
          &"{rom}: re-simulating the recorded action log diverged")
    report(&"{rom}: same seed + same log ⇒ identical hashes ({first.hashes.len} ticks)")

proc testOneByteChanges() =
  ## (b) An edited action byte is CAUSAL: the hash chain is bit-identical up
  ## to the edited tick and changes at or after it. Not every byte is
  ## observable — `fire` is a no-op in two of the three ROMs and a turn into a
  ## wall changes nothing — so the assertion is causality plus a strong
  ## majority, which is the real property. A byte that changed a hash BEFORE
  ## its own tick would mean the sim reads the future.
  let config = testConfig(RomChomper, 5_140_913)
  let base = runScripted(config, maxTicks = 400, recordActions = true)
  var
    changed = 0
    rng = initRand(99)
  for _ in 0 ..< 12:
    var actions = base.actions
    let
      tick = rng.rand(0 ..< actions.len - 40)
      seat = rng.rand(0 .. 3)
    actions[tick][seat] = uint8((int(actions[tick][seat]) + 1) mod 15)
    let hashes = replayActions(config, actions)
    check(hashes.len == base.hashes.len, "the edited log changed the length")
    for i in 0 ..< tick:
      check(hashes[i] == base.hashes[i],
            &"an edit at tick {tick} changed the hash at tick {i}")
    var differs = false
    for i in tick ..< hashes.len:
      if hashes[i] != base.hashes[i]:
        differs = true
        break
    if differs:
      inc changed
  check(changed >= 8,
        &"only {changed}/12 single-byte edits were observable at all")
  report(&"action bytes are causal; {changed}/12 single-byte edits observable")

proc testGoldenFixture() =
  ## (c) A committed golden fixture pins the hash at every 48th tick for seed
  ## 5 140 913 in EACH of the three ROMs. A rule change that forgets to bump
  ## GameVersion lands here.
  let golden = parseJson(readRepoFile("tests/data/golden_hashes.json"))
  check(golden{"seed"}.getInt() == 5_140_913, "the golden fixture moved seeds")
  for rom in RomNames:
    let expected = golden{"roms"}{rom}
    check(not expected.isNil, &"no golden hashes for {rom}")
    let config = testConfig(rom, 5_140_913)
    let run = runScripted(config)
    let goldenTicks = expected{"ticks"}.getInt()
    check(run.hashes.len == goldenTicks,
          &"{rom}: {run.hashes.len} ticks, golden says {goldenTicks}")
    var index = 0
    for i, h in run.hashes:
      if (i + 1) mod 48 != 0:
        continue
      let want = expected{"every48"}[index].getStr()
      check($h == want,
            &"{rom}: hash at tick {i + 1} is {h}, golden says {want}")
      inc index
    check(index == expected{"every48"}.len, &"{rom}: golden length mismatch")
    check(run.reason == expected{"reason"}.getStr() and
          run.endRule == expected{"endRule"}.getStr(),
          &"{rom}: the ending moved")
    report(&"{rom}: {index} golden hashes match")

proc testSourceGuards() =
  ## (d) The source guard. Nothing downstream can catch a float that only
  ## rounds differently on wasm32, so it is forbidden at the source.
  const Forbidden = [
    "sin", "cos", "tan", "arctan", "arcsin", "arccos", "exp", "ln", "log",
    "pow", "sqrt", "hypot", "float", "float32", "float64"]
  for name in SimModules:
    let body = stripComments(readRepoFile("src/lane" / name))
    for token in Forbidden:
      check(not body.hasToken(token),
            &"src/lane/{name} contains `{token}` — the wasm32 and amd64 " &
            "builds would not agree")
    check(not body.contains("rand("),
          &"src/lane/{name} calls rand( — every draw must go through drawInt")
  for name in ["Dockerfile", "Dockerfile.replay-viewer",
               "replay-viewer/config.nims", "tools/build_replay_viewer.sh"]:
    check(not readRepoFile(name).contains("ffast-math"),
          &"{name} enables -ffast-math")
  # Every `while` in the sim modules is bounded by a compile-time constant or
  # a length; a `while true` there would be an unbounded loop in the tick.
  for name in SimModules:
    for line in stripComments(readRepoFile("src/lane" / name)).splitLines():
      check(not line.strip().startsWith("while true"),
            &"src/lane/{name} has an unbounded `while true` in the sim")
  report("no float, no rand(, no -ffast-math, no unbounded while in the sim")

proc testLaneStreamsAgree() =
  ## (e) The four lanes' RNG streams produce IDENTICAL first-500 draw
  ## sequences from one seed — the fairness proof at the source.
  var draws: array[4, seq[int32]]
  for seat in 0 ..< 4:
    var lane: Lane
    seedLaneRng(lane.rngA, lane.rngB, 5_140_913)
    for _ in 0 ..< 500:
      draws[seat].add(drawInt(lane, 0'i32, 1_000_000'i32))
  for seat in 1 ..< 4:
    check(draws[seat] == draws[0], &"lane {seat}'s RNG stream differs from lane 0's")
  check(draws[0][0] != draws[0][1], "the RNG returns a constant")
  report("all four lanes draw the identical first 500 values from one seed")

proc testRngDrawsAgree() =
  ## (f) `rngDraws` is identical between two runs of the same action log —
  ## it is hashed, so a schedule that consumed a different number of draws
  ## would already have failed above; this names the cause.
  let config = testConfig(RomGallery, 42)
  let first = runScripted(config, maxTicks = 600, recordActions = true)
  var game = seatedSim(config)
  for cmds in first.actions:
    game.step(cmds)
  for seat in 0 ..< 4:
    check(game.lanes[seat].rngDraws == game.lanes[0].rngDraws,
          "the four lanes consumed different numbers of draws")
  check(game.lanes[0].rngDraws > 0, "gallery consumed no draws at all")
  report(&"rngDraws reproduce exactly ({game.lanes[0].rngDraws} draws)")

when isMainModule:
  echo "test_determinism"
  testSameLogSameHashes()
  testOneByteChanges()
  testGoldenFixture()
  testSourceGuards()
  testLaneStreamsAgree()
  testRngDrawsAgree()
  echo "test_determinism OK"
