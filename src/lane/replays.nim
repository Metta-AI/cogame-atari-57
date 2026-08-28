## The replay codec wrapper: keyframes, the incremental precompute walk, lull
## spans, beat events, the seek/speed transport, and the per-tick hash check.
##
## This is `coworld-ctf`'s `src/ctf/replays.nim`, kept whole. Three named
## edits (design note §The three named edits to replays.nim):
##
##   1. `serializeReplaySim` / `deserializeReplaySim` cover the LANE fields
##      (there are no static map bakes to strip: the cabinet's board art is
##      baked in `global.nim`, outside the sim, so a keyframe is just the
##      flatty image of `SimServer`).
##   2. `CtfReplayMagic "COWLDCTF"` becomes `Atari57ReplayMagic "COWLDA57"`,
##      with `GameName` `atari-57` and `GameVersion` `1`.
##   3. A `stopped` chat record, applied by ONE shared proc on record and on
##      playback — a wall-clock fact cannot be re-derived from sim state, and
##      hashing a state playback cannot reproduce mismatches every
##      deadline-ended replay (particle-worlds 13c66d7, 2026-08-26).

import
  std/[json, tables],
  flatty,
  bitworld/spriteprotocol,
  bitworld/replays as replayCodec,
  broadcast, sim, global

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    ## Player leaves shift overlay indices, so keyframes snapshot overlay state.
    overlaysBytes*: string
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    overlays*: seq[DebugOverlay]
    masks*: seq[uint8]
    pressedMasks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## First tick the match is actually being PLAYED (the Lobby "WAITING FOR
      ## PLAYERS" span before this is dead air a spectator should never have to
      ## watch). Playback auto-starts here, loops back here, and the scrubber /
      ## tick clock are offset by it so the shown timeline is 0 = first action.
    leadSeries*: seq[seq[int]]
      ## [tick, leadPerTeam…] change-points across the WHOLE match/episode
      ## (one value per team, in Team order): remaining LIVES for classic
      ## games, CUMULATIVE HILL TICKS for KotH games (scanTeamLead).
      ## Precomputed on the deterministic keyframe walk so the momentum graph
      ## can draw its full-timeline shape all at once (not accumulate as it
      ## plays). Only points where some team's value CHANGES are stored
      ## (compact step series); the client holds each value to the next point
      ## and to maxTick.
    endHoldFrames*: int
      ## Real-time frames left to HOLD on the final game-over frame before a
      ## looping replay restarts, so the end segment (winner, win condition,
      ## stats) is readable instead of flashing for one frame. 0 = not holding.
    pendingSeekTick*: int
      ## A seek still converging, or -1. A seek lands on the newest keyframe
      ## at or before its target and then RE-SIMULATES the gap, and while the
      ## precompute walk is still running the keyframes only cover its
      ## prefix — on a 4 405-tick hosted replay the 50 % scrub had ~2 000
      ## ticks of gap and re-simulated all of them inside ONE presentation
      ## frame, so the viewer showed nothing for seconds and the
      ## viewer-check's 50 % clock probe read identically to its 0 % probe.
      ## The gap is now walked SeekTicksPerFrame at a time (like the
      ## precompute scan), so the first frame after a click already moves and
      ## no frame stalls.
    skipLulls*: bool
      ## When on, playback fast-forwards through the lull spans below. ON for
      ## every replay `initReplayPlayer` builds: a spectator's default watch
      ## should not sit through the quiet stretches. 'f' turns it off.
    lullSpans*: seq[array[2, int]]
      ## Inclusive [firstTick, lastTick] spans where nothing beat-worthy
      ## happens (no kill/steal/return/capture/phase change within
      ## LullLeadTicks), precomputed on the same keyframe walk. Spans shorter
      ## than MinLullTicks are dropped: skipping a short breather is more
      ## jarring than watching it.
    beatEvents*: JsonNode
      ## Full-match flag-story beats (steal/return/capture) plus the terminal
      ## gameover verdict, exactly as `stepEvents` emits them, precomputed on
      ## the same keyframe walk. Shipped once to the HUD client so the
      ## scrubber can place its flag markers and winner cap up front instead
      ## of accumulating them as playback happens to pass each beat.
    achievementBadges*: JsonNode
      ## Always an empty array here: the cabinet has no achievements
      ## (design note §Out of scope). Kept so the inherited chrome frame
      ## builder needs no edit.
    scan: ReplayScan
      ## The in-flight whole-match precompute walk, nil when finished (and
      ## for players that never scan — the offline tools). The walk used to
      ## run synchronously before the first frame — seconds of black screen
      ## on a giant board — and now advances a bounded slice per
      ## presentation frame (advanceReplayScan) while playback is already on
      ## screen.
    scanDone: bool
      ## True once the precompute walk has finished; read via scanComplete.
      ## Private so no caller can flip it mid-walk — a premature true would
      ## freeze a half-scanned timeline into the HUD (the lead chrome ships
      ## exactly once per viewer).

  ReplayScan* = ref object
    ## Working state of the incremental precompute walk: a second sim +
    ## player stepped from tick 0 that derives keyframes, the lives-lead
    ## series, story beats and lull spans without touching the on-screen
    ## playback state.
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: seq[int]
    interval: int
    maxTick: int

# PlaybackSpeeds moved to sim_types.nim (the single source for every speed-coupled
# layer); re-exported here for the existing `import replays` consumers.
export PlaybackSpeeds

const
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
    ## How long a looping replay holds on its final game-over frame (real
    ## seconds) before restarting.
  LullLeadTicks* = 2 * ReplayFps
    ## Context kept before and after every beat event.
  MinLullTicks* = 6 * ReplayFps
    ## Shortest quiet stretch worth fast-forwarding.
  LullSpeedBoost* = 8
    ## Speed multiplier applied inside a lull span.
  MaxLullTicksPerFrame* = 64
    ## Per-frame cap on boosted stepping so the server stays responsive.
  SeekTicksPerFrame* = 240
    ## Per-frame cap on the re-simulation a SEEK may do (10 s of sim time).
    ## A seek past the keyframed prefix converges over this many ticks per
    ## presentation frame instead of blocking one frame for the whole gap.
  Atari57ReplayMagic = "COWLDA57"
  Atari57ReplayFormatVersion = 1'u16
  Atari57ReplaySpec = ReplaySpec(
    magic: Atari57ReplayMagic,
    formatVersion: Atari57ReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

export replayCodec

proc tickTime*(tick: int): uint32 =
  ## Converts a simulation tick to replay milliseconds.
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(
  replayWriter: var ReplayWriter,
  time: uint32,
  playerIndex: int,
  mask: uint8
) =
  ## Writes one replay input event when a COG's applied mask changes.
  ##
  ## Lives here rather than in server.nim because the mask log IS the replay's
  ## action stream: the tests that prove the recorded masks re-simulate to the
  ## identical hash chain have to write it exactly the way the server does, and
  ## two copies of this would be two chances to drift.
  if playerIndex < 0 or playerIndex >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[playerIndex] == mask:
    return
  replayWriter.writeInput(ReplayInput(
    time: time,
    player: uint8(playerIndex),
    keys: mask
  ))
  replayWriter.lastMasks[playerIndex] = mask

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  ## Opens a replay file and writes the header.
  replayCodec.openReplayWriter(path, configJson, Atari57ReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  ## Parses one replay file buffer into memory.
  replayCodec.parseReplayBytes(bytes, Atari57ReplaySpec)

proc loadReplay*(path: string): ReplayData =
  ## Loads a replay file into memory.
  replayCodec.loadReplay(path, Atari57ReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## Serializes one simulation state for a replay keyframe. Unlike paintbot's
  ## version there are no static map bakes to set aside: the cabinet's board
  ## art is baked in `global.nim`, OUTSIDE the sim, so a keyframe is exactly
  ## the flatty image of `SimServer` — the four lanes' phases, timers, lives,
  ## points, screens, tile bitmaps, bunker hit points, every sprite, the
  ## power window, the chains, the ramps, the counters, the score
  ## accumulators and each lane's RNG state.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string, donor: var SimServer): SimServer =
  ## Deserializes one simulation state from a replay keyframe.
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.pressedMasks = @[]
  result.lastAppliedMasks = @[]
  result.overlays = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed.
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  ## Returns the final tick available in the replay.
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  ## Returns the first tick a spectator should watch: the moment the match
  ## leaves the lobby (never negative, never past the end).
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  ## Resets replay playback cursors.
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.debugSpriteIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = @[]
  replay.pressedMasks = @[]
  replay.lastAppliedMasks = @[]
  replay.overlays = @[]

proc saveReplayKeyframe(
  replay: ReplayPlayer,
  sim: var SimServer
): ReplayKeyframe =
  ## Builds one replay keyframe from the current playback state.
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    debugSpriteIndex: replay.debugSpriteIndex,
    hashIndex: replay.hashIndex,
    overlaysBytes: replay.overlays.toFlatty(),
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  ## Restores playback state from one replay keyframe. The outgoing sim
  ## donates its static map bakes to the restored one (keyframes exclude
  ## them — see serializeReplaySim).
  let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes, sim)
  restored.gameEventLoggingEnabled = gameEventLoggingEnabled
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.debugSpriteIndex = keyframe.debugSpriteIndex
  replay.hashIndex = keyframe.hashIndex
  replay.overlays = keyframe.overlaysBytes.fromFlatty(seq[DebugOverlay])
  replay.masks = keyframe.masks
  replay.pressedMasks = newSeq[uint8](replay.masks.len)
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  ## Returns the newest keyframe at or before one tick.
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  ## Expands replay input tables for one player.
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.pressedMasks.add(0)
    replay.lastAppliedMasks.add(0)
    replay.overlays.add(DebugOverlay())

proc clearReplayPressedMasks(replay: var ReplayPlayer) =
  ## Clears per-step replay press events.
  for mask in replay.pressedMasks.mitems:
    mask = 0

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins and inputs for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    ## A leave does NOT shift the mask arrays: the four lanes are fixed for
    ## the whole episode and the recorded action bytes are indexed BY SEAT,
    ## so deleting a row would silently re-point every byte after it at the
    ## wrong lane for the rest of playback.
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, int(join.player), join.token,
                          trusted = true)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.pressedMasks[int(input.player)] =
      replay.pressedMasks[int(input.player)] or
        (input.keys and not replay.masks[int(input.player)])
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    # The cabinet's CONTROL records (register / stance / fallback /
    # budget_guard / stopped / result) ride the chat stream as JSON objects
    # and are re-applied here into NON-HASHED state only — with ONE
    # exception, `stopped`, which IS hashed and is applied by the same proc
    # the live server used, because a wall-clock fact cannot be re-derived
    # from sim state (design note, replays.nim edit 3).
    if chat.message.len > 0 and chat.message[0] == '{':
      sim.applyControlRecord(chat.message)
    inc replay.chatIndex

  # Leaves are consumed first, so equal-time debug records use shifted indices.
  while replay.debugSpriteIndex < replay.data.debugSprites.len and
      replay.data.debugSprites[replay.debugSpriteIndex].time <= time:
    let debugSprite = replay.data.debugSprites[replay.debugSpriteIndex]
    replay.ensureReplayPlayer(int(debugSprite.player))
    # Crafted replay records are skipped so one malformed packet is non-fatal.
    try:
      replay.overlays[int(debugSprite.player)].applyDebugSpritePacket(
        debugSprite.packet
      )
    except SpriteProtocolError:
      discard
    inc replay.debugSpriteIndex

proc replayInputs(
  replay: var ReplayPlayer,
  playerCount: int
): seq[uint8] =
  ## Builds the ACTION BYTES for the current tick. Paintbot's press/release
  ## wrapper is gone: our byte is a VALUE, not a button mask, so a
  ## repeated-press fold would corrupt it. `writeInputMaskChange`'s own
  ## change-only guard is the whole log.
  result = newSeq[uint8](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    let value = replay.masks[playerIndex]
    result[playerIndex] = value
    replay.lastAppliedMasks[playerIndex] = value

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message =
      "Replay hash mismatch at tick " & $sim.tickCount &
        "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick, from the RECORDED action bytes.
  replay.clearReplayPressedMasks()
  replay.applyReplayEvents(sim)
  let inputs = replay.replayInputs(max(4, sim.players.len))
  sim.step(inputs)
  replay.clearReplayPressedMasks()
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int],
  startTick, maxTick: int
): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping LullLeadTicks of context on both sides and dropping spans shorter
  ## than MinLullTicks.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len:
        beatTicks[i]
      else:
        # The stretch after the final beat runs lead-free to the end: there is
        # no upcoming action that needs a lead-in.
        maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanTeamLead(sim: SimServer): seq[int] =
  ## One lead value per LANE, in Team order — the metric the momentum graph
  ## plots. On a score-attack cabinet that metric is the SCORE itself
  ## (`points / 100 + livesLeft`), carried in hundredths so the series stays
  ## integer: a death is a visible 100-unit dip and a screen clear is a step.
  for seat in 0 ..< 4:
    result.add(int(sim.lanes[seat].scoreMicro div 10_000))

proc scanSeriesPoint(tick: int, lead: seq[int]): seq[int] =
  ## One [tick, leadPerTeam…] change-point of the momentum series.
  result = @[tick]
  result.add(lead)

proc scanComplete*(replay: ReplayPlayer): bool =
  ## True once the precompute walk has finished: leadSeries, beatEvents and
  ## lullSpans hold the whole match and the lead chrome may ship. Until then
  ## keyframes only cover the walked prefix (seeks past it re-simulate
  ## forward, exactly like seeking between keyframes) and skip-lulls has no
  ## spans to boost through.
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Starts the whole-match precompute walk: seek keyframes, the per-team
  ## lives change-point series (momentum graph), the flag-story beats, and
  ## the beat ticks the lull map derives from. The walk advances via
  ## advanceReplayScan — a bounded slice per presentation frame in the
  ## hosted viewer, or all at once via buildReplayKeyframes.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.achievementBadges = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastLead = scanTeamLead(scan.sim)
  replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  # Beat ticks for the lull map are derived by the SAME tracker the broadcast
  # channel uses, so "nothing happens here" agrees with the story the kill
  # feed and banners tell. Respawns are excluded: they trail kills on a fixed
  # timer and are not drama worth slowing down for.
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  # -1 until the match leaves the lobby: the first tick the game is Playing is
  # where a spectator's watch should begin (everything before is warmup).
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  # An empty recording has nothing to walk: finalize immediately instead of
  # spending a frame in a fictitious in-flight state.
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` simulation ticks; when
  ## the walk stops — at the recording's final hash, earlier if the
  ## builder's playback ends (the recorded match is over), or at a malformed
  ## record — it derives the lull spans from whatever prefix it covered and
  ## marks the lead chrome ready (scanComplete). No-op once finished.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      # A malformed record (bad join/leave, or a hash mismatch under
      # mismatchQuit) would otherwise re-raise from this same tick on EVERY
      # subsequent frame — the walk's cursor cannot advance past it. With
      # mismatchQuit the raise is the diagnostic mode's whole point, so it
      # propagates; otherwise finalize on the walked prefix and let the
      # DISPLAY path surface the same defect loudly when playback reaches
      # that tick.
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ",
        error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    # Record the per-team hill-tick change-points across the full episode so
    # the momentum graph draws its whole-timeline shape up front
    # (deterministic replay: a tick's hill counts are fixed). Only points
    # where some team's count changes are stored to keep the series compact.
    let lead = scanTeamLead(scan.sim)
    if lead != scan.lastLead:
      replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, lead))
      scan.lastLead = lead
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      # The objective story + verdict for the scrubber's up-front timeline.
      # Kills stay out: dozens of same-looking ticks would bury the beats.
      # Classic replays keep the flag beats; KotH replays get the hill beats.
      const scrubberBeats = [
        "life_lost", "screen_clear", "record", "lane_over", "over"]
      if event["k"].getStr() in scrubberBeats:
        replay.beatEvents.add(event)
    for event in stepBeats:
      ## `pickup`, `chain`, `near_miss` and `say` fire hundreds of times, so
      ## they are events but never beats — they would bury the scrubber.
      if event["k"].getStr() notin ["pickup", "chain", "say", "near_miss"]:
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return                              # more slices to come.
  # Anchor the final tick so the client can hold the last value to the end.
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(
      scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  replay.lullSpans = buildLullSpans(
    scan.beatTicks,
    replay.replayStartTick(),
    scan.maxTick
  )
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## The board is a fixed 1400x1400 and the roster is always four, so the
  ## slice is the paintbot small-board one.
  96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Runs the whole precompute walk synchronously (tests and offline tools;
  ## the hosted viewer advances it a slice per frame instead — see
  ## advanceReplayScan).
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  ## Returns true when one tick sits inside a precomputed lull span.
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## Returns how many ticks playback may advance this frame from one tick:
  ## the chosen speed, boosted inside a lull while skip-lulls is on.
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)]
    )
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(
  replay: var ReplayPlayer,
  sim: var SimServer
): bool =
  ## Walks a pending seek up to SeekTicksPerFrame ticks closer to its target.
  ## Returns true when it moved the sim, so the caller can resync its
  ## broadcast tracker. Clears the pending seek once the target (or the end of
  ## the recording) is reached.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Starts a BOUNDED seek: land on the newest keyframe at or before `tick`
  ## (instant) and record the target. Convergence happens SeekTicksPerFrame
  ## at a time from advanceReplayPlayback — which every host calls in the same
  ## frame — so a seek inside the keyframed region still lands on this frame
  ## while a seek past the precompute walk's prefix costs one bounded slice
  ## per frame instead of stalling the viewer. The keyframe restore alone
  ## already moves the clock, which is what makes a scrubber click visible in
  ## the very next frame. Call convergeSeek in a loop for a synchronous seek.
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Seeks replay playback and pauses on the target tick. The seek itself is
  ## bounded per frame (beginSeek); playback stays paused while it converges.
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## Applies one live playback speed command.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, 0)
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '3':
    speedIndex = 2
  of '4':
    speedIndex = 3
  of '8':
    speedIndex = 4
  of '6':
    speedIndex = 5
  else:
    discard

proc applyReplayCommand*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  ## Applies one global viewer replay command.
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  ## Cancels the end-of-replay hold. Callers cancel after any manual
  ## seek/jump — a scrub off the final frame leaves the end segment.
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  ## Whole seconds left in the end-of-replay hold (0 when not holding), for
  ## the broadcast chrome's "replaying in N" countdown.
  if replay.endHoldFrames <= 0:
    0
  else:
    (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame (call once per TargetFps frame,
  ## after replay seeks/commands have been applied). Steps the sim
  ## `replaySpeed` ticks while playing; `onStep` runs after every sim tick
  ## (beat-event derivation), `onJump` after any playback jump (tracker
  ## resync). Shared by the native replay server and the static WASM viewer
  ## so both tell the same story at the end of a match: a LOOPING replay does
  ## NOT restart the moment playback stops — the final game-over frame (the
  ## end segment: winner, win condition, stats) holds for
  ## ReplayEndHoldSeconds of real time first. A play command during the hold
  ## skips the wait and loops immediately.
  # A seek the viewer asked for OWNS the frame. Converging it takes priority
  # over the background precompute walk (a scan slice plus a seek slice in one
  # frame is what made the hosted 50 % scrub read stale) and over playback:
  # the seek is paused by definition, and the next frame either converges
  # further or resumes.
  if replay.pendingSeekTick >= 0:
    if replay.convergeSeek(sim):
      onJump()
    return
  # Advance the background precompute walk a bounded slice per frame (no-op
  # once complete). Runs while paused too: a paused frame has budget to
  # spare, and finishing the walk is what unlocks the momentum graph, beat
  # markers and skip-lulls.
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    # Play pressed during the end hold: skip the wait and loop now.
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    # The step budget is re-read every tick: inside a lull it is boosted, and
    # the moment stepping crosses back into action it drops to the plain
    # speed, so a fast-forward never overshoots a beat's lead-in.
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      # Playback just reached the end: begin the end-segment hold.
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()


proc playbackSpeed*(speedIndex: int): int =
  ## Returns the live playback speed for an index.
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
