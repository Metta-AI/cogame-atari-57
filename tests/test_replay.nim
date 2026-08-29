## An END-TO-END episode that writes a replay, for EVERY end reason — not just
## `complete`. A wall-clock fact cannot be re-derived from sim state, and
## recording the hash of a state playback cannot reproduce mismatches every
## deadline-ended replay (particle-worlds 13c66d7, 2026-08-26).

import std/[json, os, osproc, strformat, strutils, unicode]
import lane_helpers
import lane/[sim_types, replays, replay_runtime, broadcast, decide, stances]

type Recorded = object
  path: string
  reason, endRule: string
  ticks: int

proc recordEpisode(
  config: GameConfig, dir: string, stopAtTick = -1, faultAtTick = -1
): Recorded =
  ## Writes a replay exactly the way `server.nim` does: joins, one `register`
  ## per seat, a `stance` per seat per turn, an action byte per seat per tick
  ## (change-only), one hash per tick, the `stopped` record when the wall clock
  ## trips, and one `result` record at the end.
  createDir(dir)
  result.path = dir / "episode.replay"
  var names: seq[string]
  for seat in 0 ..< 4:
    names.add("P" & $(seat + 1))
  var writer = openReplayWriter(result.path, config.configJson(names))
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< 4:
    discard game.addPlayer(names[seat], seat, "", trusted = true)
    writer.writeJoin(tickTime(game.tickCount), seat, names[seat], seat, "")
    while writer.lastMasks.len < 4:
      writer.lastMasks.add(0)
    let record = registerRecord(
      seat, seat, laneAlias(seat), "policy \u00e9\u00e9", "scripted", "arcader")
    writer.writeChat(tickTime(game.tickCount), seat, record)
    game.applyControlRecord(record)

  var
    controls: array[4, ControlLane]
    active: array[4, LaneStance]
    cmds = newSeq[uint8](4)
  for i in 0 ..< 4:
    controls[i] = initControlLane()
  # The loop is the SERVER's: the lobby ticks are stepped and hashed exactly
  # like the playing ones, because playback replays them too.
  while game.phase != GameOver:
    for seat in 0 ..< 4:
      cmds[seat] = 0'u8
    if game.phase == Playing:
      let turn = game.gameTicksElapsed() div config.turnTicks
      if game.gameTicksElapsed() mod config.turnTicks == 0:
        for seat in 0 ..< 4:
          active[seat] = arcaderStance(game, seat)
          ## A NON-ASCII say and note, deliberately, so the UTF-8 path is real.
          active[seat].say = "caf\u00e9 \u00e9clair"
          active[seat].note = "prend le p\u00e9lerin \u2014 " & active[seat].note
          let record = active[seat].boundedStanceRecord(
            turn, seat, seat, laneAlias(seat))
          writer.writeChat(tickTime(game.tickCount), seat, record)
          game.applyControlRecord(record)
      if stopAtTick >= 0 and game.tickCount >= stopAtTick:
        writer.writeChat(
          tickTime(game.tickCount), 0, stoppedRecord(game.tickCount))
        game.recordStop(game.tickCount)
        game.finishGame(ReasonDeadline, EndRuleWallClock)
        break
      if faultAtTick >= 0 and game.tickCount >= faultAtTick:
        ## An injected guard trip: the episode ends `fault` / `sim_fault` and
        ## the PARTIAL replay is still written.
        game.finishGame(ReasonFault, EndRuleSimFault)
        break
      for seat in 0 ..< 4:
        cmds[seat] = laneCommand(controls[seat], game.lanes[seat],
                                 active[seat], config.preset, game.tickCount)
    for seat in 0 ..< 4:
      writer.writeInputMaskChange(tickTime(game.tickCount), seat, cmds[seat])
    game.step(cmds)
    writer.writeHash(uint32(game.tickCount), game.gameHash())
  writer.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
  writer.closeReplayWriter()
  result.reason = game.endReason
  result.endRule = game.endRule
  result.ticks = game.tickCount

proc resimulate(path: string): tuple[ticks, mismatch: int] =
  let data = loadReplay(path)
  var init = initReplayRuntime(data, mismatchQuit = false,
                               gameEventLoggingEnabled = false)
  var
    game = move(init.sim)
    player = move(init.player)
  while game.tickCount < player.replayMaxTick() and
      player.hashIndex < data.hashes.len and player.hashMismatchTick < 0:
    player.stepReplay(game)
  (game.tickCount, player.hashMismatchTick)

proc testEveryRomRoundTrips() =
  let dir = getTempDir() / "atari57-replay-test"
  removeDir(dir)
  for rom in RomNames:
    let config = testConfig(rom, 5_140_913)
    let recorded = recordEpisode(config, dir / rom)
    let data = loadReplay(recorded.path)
    check(data.gameName == GameName, "the replay names the wrong game")
    check(data.gameVersion == GameVersion, "the replay carries the wrong version")
    check(data.joins.len == 4, &"{rom}: {data.joins.len} joins, not 4")
    check(data.hashes.len > 100, &"{rom}: only {data.hashes.len} hashes")
    let outcome = resimulate(recorded.path)
    check(outcome.mismatch < 0,
          &"{rom}: the recorded action log re-simulated to a DIFFERENT state " &
          &"at tick {outcome.mismatch}")
    check(outcome.ticks == recorded.ticks,
          &"{rom}: playback stopped at {outcome.ticks}, recording ran to " &
          &"{recorded.ticks}")
    report(&"{rom}: {data.hashes.len} ticks re-simulate exactly")

proc testEveryEndReason() =
  ## `full_time`, `all_lanes_over`, `wall_clock` (a forced short budget) and
  ## `sim_fault` (an injected guard trip) — all four record and re-derive.
  let dir = getTempDir() / "atari57-replay-reasons"
  removeDir(dir)
  block fullTime:
    let recorded = recordEpisode(testConfig(RomBrickfall, 42), dir / "full")
    check(recorded.endRule == EndRuleFullTime,
          &"expected full_time, got {recorded.endRule}")
    check(resimulate(recorded.path).mismatch < 0, "full_time did not re-derive")
  block allOver:
    var config = testConfig(RomGallery, 5_140_913)
    config.update("""{"rom":"gallery","seed":5140913,"minTicks":0,
                      "minPlayers":1,"startWaitTicks":0}""")
    let recorded = recordEpisode(config, dir / "over")
    check(recorded.endRule == EndRuleAllLanesOver,
          &"expected all_lanes_over, got {recorded.endRule}")
    check(resimulate(recorded.path).mismatch < 0,
          "all_lanes_over did not re-derive")
  block wallClock:
    let recorded = recordEpisode(
      testConfig(RomChomper, 7), dir / "wall", stopAtTick = 400)
    check(recorded.reason == ReasonDeadline and
          recorded.endRule == EndRuleWallClock,
          &"expected deadline/wall_clock, got {recorded.reason}/{recorded.endRule}")
    check(resimulate(recorded.path).mismatch < 0,
          "a DEADLINE-ended replay did not re-derive — the `stopped` record " &
          "is not being applied by the same proc on both sides")
  block simFault:
    let recorded = recordEpisode(
      testConfig(RomChomper, 9), dir / "fault", faultAtTick = 300)
    check(recorded.reason == ReasonFault and
          recorded.endRule == EndRuleSimFault,
          &"expected fault/sim_fault, got {recorded.reason}/{recorded.endRule}")
    check(resimulate(recorded.path).mismatch < 0,
          "a partial fault replay did not re-derive")
  report("full_time, all_lanes_over, wall_clock and sim_fault all re-derive")

proc testRecordStream() =
  let dir = getTempDir() / "atari57-replay-records"
  removeDir(dir)
  let config = testConfig(RomChomper, 5_140_913)
  let recorded = recordEpisode(config, dir)
  let data = loadReplay(recorded.path)
  var
    registers = 0
    stances = 0
    results = 0
  for chat in data.chats:
    check(chat.message.validateUtf8() == -1,
          "a recorded chat record is not valid UTF-8")
    let record = parseJson(chat.message)
    case record{"k"}.getStr()
    of "register": inc registers
    of "stance":
      inc stances
      check(chat.message.runeLen <= MaxStanceRunes,
            &"a stance record is {chat.message.runeLen} runes, over " &
            &"{MaxStanceRunes}")
      check(record{"note"}.getStr().runeLen <= MaxNoteRunes,
            "a recorded note is over its cap")
      check(record{"say"}.getStr().runeLen <= MaxSayRunes,
            "a recorded say is over its cap")
    of "result":
      inc results
      let doc = record{"results"}
      check(doc{"reason"}.getStr() in ["complete", "deadline", "fault"],
            "an illegal results.reason reached the replay")
      check(doc{"endRule"}.getStr() in
              ["all_lanes_over", "full_time", "wall_clock", "sim_fault",
               "host_error"], "an illegal results.endRule reached the replay")
      check(doc{"rom"}.getStr() in RomNames, "an illegal results.rom")
  check(registers == 4, &"{registers} register records, not 4")
  check(stances >= 4, &"only {stances} stance records")
  check(results == 1, &"{results} result records, not exactly 1")

  ## The embedded config JSON decodes strictly and carries what playback needs.
  let embedded = parseJson(data.configJson)
  check(embedded{"seed"}.getInt() == 5_140_913, "the replay lost its seed")
  check(embedded{"rom"}.getStr() == RomChomper, "the replay lost its rom")
  check(embedded{"parScore"}.getInt() > 0, "the replay lost parScore")
  check(embedded{"preset"}{"avatarSpeed"}.getInt() > 0,
        "the replay does not carry the resolved preset")
  check(embedded{"map"}.len == GridH, "the replay does not carry the 17 map rows")
  check(embedded{"mapSha256"}.getStr().len == 64, "the replay lost the map hash")
  report("register x4, stances, one result, and a fully resolved config")

proc testReplaySummary() =
  ## `tools/replay_summary.py` output parses under a STRICT UTF-8 JSON parser,
  ## with the fixture forced to carry a non-ASCII say and a non-ASCII policy
  ## label, so the UTF-8 path is real and not decorative.
  let dir = getTempDir() / "atari57-replay-summary"
  removeDir(dir)
  let recorded = recordEpisode(testConfig(RomChomper, 5_140_913), dir)
  let (output, code) = execCmdEx(
    "python3 " & (repoRoot() / "tools" / "replay_summary.py") & " " &
    recorded.path)
  check(code == 0, &"replay_summary.py exited {code}: {output}")
  check(output.validateUtf8() == -1, "replay_summary.py emitted invalid UTF-8")
  let summary = parseJson(output)
  check(summary{"protocol"}.getStr() == "atari-57/v1", "the wrong protocol tag")
  check(summary{"gameVersion"}.getStr() == GameVersion, "the wrong gameVersion")
  check(summary{"rom"}.getStr() == RomChomper, "the wrong rom")
  check(summary{"tickCount"}.getInt() > 100, "the summary saw no ticks")
  check(summary{"stances"}.len >= 4, "the summary found no stances")
  check(summary{"results"}{"reason"}.getStr().len > 0,
        "the summary carries no results")
  var sawAccent = false
  for stance in summary{"stances"}:
    if stance{"say"}.getStr().contains("\u00e9"):
      sawAccent = true
  check(sawAccent, "the non-ASCII say did not survive the round trip")
  report("replay_summary.py emits strict UTF-8 JSON with the results embedded")

proc testHalfSpeedIsAReplayOnlyCrawl() =
  ## The fleet-wide 1/2x replay speed: command '5' selects
  ## ReplayHalfSpeedIndex, the chrome shows 0.5, and the step budget spends
  ## one tick every OTHER frame (halfPhase parity) outside lulls.
  var replay = ReplayPlayer()
  replay.speedIndex = 0
  applySpeedCommand(replay.speedIndex, '5')
  check(replay.speedIndex == ReplayHalfSpeedIndex, "'5' must select 1/2x")
  check(replay.replayDisplaySpeed() == 0.5,
        "the chrome speed at 1/2x is 0.5, got " & $replay.replayDisplaySpeed())
  check(replay.replaySpeed() == 1,
        "the integer speed clamps to 1x at 1/2x (live loop safety)")
  replay.skipLulls = false
  replay.halfPhase = false
  check(replay.replayStepBudget(0) == 0, "even frame at 1/2x spends no tick")
  replay.halfPhase = true
  check(replay.replayStepBudget(0) == 1, "odd frame at 1/2x spends one tick")
  applySpeedCommand(replay.speedIndex, '+')
  check(replay.speedIndex == 0, "'+' from 1/2x lands on 1x")
  applySpeedCommand(replay.speedIndex, '-')
  check(replay.speedIndex == ReplayHalfSpeedIndex, "'-' from 1x lands on 1/2x")
  applySpeedCommand(replay.speedIndex, '-')
  check(replay.speedIndex == ReplayHalfSpeedIndex, "1/2x is the floor")
  report("'5' is a replay-only crawl: 0.5 shown, one tick every other frame")

when isMainModule:
  echo "test_replay"
  testEveryRomRoundTrips()
  testEveryEndReason()
  testRecordStream()
  testReplaySummary()
  testHalfSpeedIsAReplayOnlyCrawl()
  echo "test_replay OK"
