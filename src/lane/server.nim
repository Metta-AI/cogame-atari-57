## The cabinet server: mummy HTTP + websockets, the lobby, the 24 Hz tick
## loop, the decision turn, the replay writer, and the artifact block.
##
## This is `coworld-ctf`'s `src/ctf/server.nim` with the design note's six
## named edits, and NOTHING ELSE moved:
##
##   1. **Input source.** Player sockets contribute NO input. The loop calls
##      `control.laneCommand` for all four lanes and passes the action-byte
##      array into `sim.step`; any input mask arriving on a player socket is
##      discarded.
##   2. **Replay input write.** paintbot's `writeInputFrameMasks` press/release
##      wrapper is DELETED — its `repeatedPressedMask` logic is button
##      semantics and would corrupt a value byte. The loop calls
##      `replayWriter.writeInputMaskChange` directly and decodes with
##      `decodeAction`, whose `cmd >= 15 -> 0` repair is shared with the
##      replay runtime.
##   3. **Turn boundary.** Immediately before stepping a tick where
##      `tick mod turnTicks == 0`, `decide.turn` runs: one parallel batch over
##      the seats whose lanes are alive, two bounded deadlines, the stances
##      installed, the `stance` / `fallback` records written.
##   4. **Wall-clock stop.** A `wallClockBudgetSeconds` check at the top of
##      every iteration writes a load-bearing `stopped` record and forces
##      `deadline` / `wall_clock`. The SAME proc applies it on record and on
##      playback.
##   5. **Shutdown grace.** `/healthz` and `/global` keep answering for a
##      bounded ~20 s after the artifacts are written, then the process exits
##      (lantern 0.1.3: the runner pings `/global` after the player pods
##      start, and a short episode can already be gone).
##   6. **Register loudness.** A seat that reaches the first turn with no
##      `register` record is logged at error level and reported as
##      `scripted`, so a silently-lost register packet is visible in the
##      hosted log instead of looking like an LLM that chose badly.
##
## Kept EXACTLY, because dropping either has failed certification twice: the
## `Ping -> Pong` branch in `websocketHandler`, and the ABSENCE of any
## `kind != TextMessage` guard (ctf-lineage players register over
## `BinaryMessage`).

import
  std/[algorithm, json, locks, monotimes, nativesockets, os, strutils, tables,
       times],
  bitworld/client as bitworldClient, bitworld/spriteprotocol, bitworld/runtime,
  mummy,
  sim, global, replays, broadcast, replay_runtime, events, wire_constants,
  control, stances, baselines, decide

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    spritesOff: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  PendingPlayerJoin = object
    websocket: WebSocket
    address: string
    token: string
    requestedSlot: int
    slotIndex: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  LeagueReplayerPath = "/client/league"
  BroadcastFontPath = "/client/font.ttf"
  LockerRoomBgPath = "/client/art/lockerroom/bg.jpg"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (1009), so
    ## outbound sprite packets are chunked under a margin below that.
  ShutdownGraceSeconds = 20
  MaxDebugSpriteBytesPerTick* = 32 * 1024

  ## The designed broadcast replay client, embedded at compile time. Final
  ## in-page script order: wire constants, shared chrome, core, page IIFE.
  EmbeddedBroadcastReplayHtml =
    staticRead("../../client/replay_broadcast.html").replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
    ).replace(
      "<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
    ).spliceWireConstants()
  EmbeddedLeagueReplayerHtml =
    staticRead("../../client/league_replayer.html").replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
    ).spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomBg = staticRead("../../client/art/lockerroom/bg.jpg")
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")

var appState: WebSocketAppState

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.spritesOff = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.config = defaultGameConfig()

proc removePlayerWebSocketState(websocket: WebSocket): int =
  result = -1
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.spritesOff.del(websocket)

proc removeWebSocketState(websocket: WebSocket): int =
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  result = removePlayerWebSocketState(websocket)

proc isPlayerWebSocket(websocket: WebSocket): bool =
  websocket in appState.playerViewers and
    websocket notin appState.globalViewers

proc registerPlayerWebSocket(
  websocket: WebSocket, identity: string, slot: int, token: string
): bool =
  appState.globalViewers.del(websocket)
  discard removePlayerWebSocketState(websocket)
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = identity
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] =
    if appState.replayLoaded: -1 else: 0x7fffffff
  appState.playerReady[websocket] = false
  true

proc registerGlobalWebSocket(websocket: WebSocket) =
  discard removePlayerWebSocketState(websocket)
  appState.globalViewers[websocket] = initGlobalViewerState()

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerSlot(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
  if result.len == 0:
    result = "P" & $(slot + 1)

proc hasPlayerCredentialParams*(name, slot, token: string): bool =
  name.strip().len > 0 or slot.strip().len > 0 or token.strip().len > 0

proc hasPlayerCredentialParams(request: Request): bool =
  hasPlayerCredentialParams(
    request.queryParams.getOrDefault("name", ""),
    request.queryParams.getOrDefault("slot", ""),
    request.queryParams.getOrDefault("token", ""))

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc configuredPlayerJoinError(
  config: GameConfig, address: string, slot: int, token: string
): string =
  ## The bad-token gate. The certifier probes `/player?slot=0&token=bad` and a
  ## fork that accepts it fails `smoke-episode` (flatland 0.1.1).
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and " & $(MaxPlayers - 1) & "."
  if slot >= 0 and slot < config.players.len and
      config.players[slot].token.len > 0 and token != config.players[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc isPlayerReadyPacket*(message: string): bool =
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc isSpritesOffPacket*(message: string): bool =
  message.len == 1 and message[0].uint8 == 0x87'u8

var replayArtifactBytes: string
var replayArtifactLock: Lock

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        let joinError = appState.config.configuredPlayerJoinError(
          identity, slot, token)
        if joinError.len > 0:
          request.respondForbiddenWebSocket(joinError)
          return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        discard websocket.registerPlayerWebSocket(identity, slot, token)
    echo "player connected: ", identity
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    var payload = ""
    {.gcsafe.}:
      withLock replayArtifactLock:
        payload = replayArtifactBytes
    request.respond((if payload.len > 0: 200 else: 404), headers, payload)
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    var texHeaders: HttpHeaders
    texHeaders["Content-Type"] = "image/jpeg"
    texHeaders["Cache-Control"] = "public, max-age=3600"
    request.respond(200, texHeaders,
      (if request.path == WallTextureHorizontalPath: WallTextureHorizontal
       else: WallTextureVertical))
  elif request.path == LockerRoomBgPath and request.httpMethod == "GET":
    var lockerHeaders: HttpHeaders
    lockerHeaders["Content-Type"] = "image/jpeg"
    lockerHeaders["Cache-Control"] = "public, max-age=3600"
    request.respond(200, lockerHeaders, LockerRoomBg)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var fontHeaders: HttpHeaders
    fontHeaders["Content-Type"] = "font/ttf"
    fontHeaders["Cache-Control"] = "public, max-age=3600"
    request.respond(200, fontHeaders, BroadcastFont)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      LeagueReplayerPath] and request.httpMethod == "GET":
    var replayHeaders: HttpHeaders
    replayHeaders["Content-Type"] = "text/html; charset=utf-8"
    replayHeaders["Cache-Control"] = "no-cache"
    if request.path == LeagueReplayerPath:
      request.respond(200, replayHeaders, EmbeddedLeagueReplayerHtml)
    else:
      request.respond(200, replayHeaders, EmbeddedBroadcastReplayHtml)
  elif bitworldClient.serveClientRoute(
      request, bitworldClient.GlobalClientRoute):
    ## `/client/global` AND `/client/player` serve real pages, registered
    ## BEFORE any catch-all asset route, and neither opens the player socket:
    ## the episode runner probes both before starting the player pods
    ## (lantern 0.1.1).
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "atari-57 cabinet")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers:
          discard removePlayerWebSocketState(websocket)
        elif websocket.isPlayerWebSocket() and
            websocket notin appState.playerIndices:
          appState.playerIndices[websocket] =
            if appState.replayLoaded: -1 else: 0x7fffffff
          appState.playerReady[websocket] = false
  of MessageEvent:
    # KEEP THIS BRANCH. Dropping it fails certification with "did not answer a
    # WebSocket Ping with Pong" (lux-ai 0.1.0, snake-royale 0.1.0), and adding
    # a `kind != TextMessage` guard drops the player's BINARY registration
    # frame, which is how a champion silently plays the scripted baseline.
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif message.data.isSpritesOffPacket():
            appState.spritesOff[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers and
              not appState.replayLoaded:
            var
              mask = 0'u8
              pressed = 0'u8
              chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, mask, pressed, chatText)
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let newlyClosed = markSocketClosed(websocket)
        if newlyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc resetPlayerReady(sockets: openArray[WebSocket]) =
  {.gcsafe.}:
    withLock appState.lock:
      for websocket in sockets:
        if websocket in appState.playerReady:
          appState.playerReady[websocket] = false

proc allPlayersReady(sockets: openArray[WebSocket]): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for websocket in sockets:
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc runFrameLimiter(
  previousTick: var MonoTime, fastMode: bool, sockets: openArray[WebSocket]
) =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      break
    if fastMode and sockets.allPlayersReady():
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
  previousTick = getMonoTime()

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it
  ## rather than poisoning the whole episode unattributed. Best-effort:
  ## outside the platform (env unset) this is a no-op.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"arcader"|null,"policy":"…"}
  ## Anything that is not that object is not a registration.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc comparePendingPlayerJoins(a, b: PendingPlayerJoin): int =
  result = cmp(a.slotIndex, b.slotIndex)
  if result != 0:
    return
  result = cmp(a.address, b.address)

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  initLock(replayArtifactLock)
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config) else: initialConfig
  var seatNames: seq[string] = @[]
  for i in 0 ..< config.numAgents:
    seatNames.add(
      if i < config.players.len and config.players[i].name.len > 0:
        config.players[i].name
      else: "P" & $(i + 1))
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson(seatNames))
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(
        ValueError, "COGAME_EVENTS_URI must be a file:// path, got: " & uri)

  var
    game =
      if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  game.collectEvents = eventsPath.len > 0
  block:
    ## Bake the board BEFORE the listener opens: a viewer's first-message
    ## clock starts at its successful connect and the certifier allows only
    ## seconds, so nothing may be accepted until every frame the loop will
    ## ever build can be assembled instantly.
    let warmStart = getMonoTime()
    game.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  let laneMode = not replayLoaded and config.numAgents > 0
  var
    engine = if laneMode: initDecisionEngine(game) else: DecisionEngine()
    controls: array[4, ControlLane]
    lanesBuilt = false
    forceStart = false
    lastTurnKey = -1
    episodeStart = getMonoTime()
    quitAfterFrame = false
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    loggedMissingRegister = false
  for i in 0 ..< 4:
    controls[i] = initControlLane()

  while true:
    var
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      cmds = newSeq[uint8](4)

    # --- edit 4: the engine's own hard stop, checked before anything else ---
    if laneMode and not game.stopped and game.phase == Playing and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the cabinet from the counters at this tick"
      replayWriter.writeChat(
        tickTime(game.tickCount), 0, stoppedRecord(game.tickCount))
      game.recordStop(game.tickCount)
      game.finishGame(ReasonDeadline, EndRuleWallClock)
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          ## A seat that drops does NOT remove its lane: the lane keeps
          ## playing on the scripted layer and the seat revives on reconnect.
          ## Deleting the row would renumber every later lane mid-replay.
          let index = removeWebSocketState(websocket)
          if index >= 0 and index < game.players.len:
            game.recordGameAbandon(index)
        appState.closedSockets.setLen(0)

        if laneMode and not lanesBuilt and game.lobbyJoinTimedOut():
          ## A seat that never connects does NOT end the episode: report the
          ## no-show, then seat its lane anyway and let the `arcader` baseline
          ## drive it for the whole run.
          let stuckSlot = game.nextPlayerSlot()
          declarePlayerFailure(
            stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(config.lobbyJoinTimeoutTicks div TargetFps) &
              "s); its lane plays the arcader baseline")
          forceStart = true

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket() and
                appState.playerIndices[websocket] == 0x7fffffff:
              newSockets.add(websocket)
          var progressed = true
          while progressed:
            progressed = false
            var pending: seq[PendingPlayerJoin] = @[]
            for websocket in newSockets:
              if websocket notin appState.playerIndices or
                  appState.playerIndices[websocket] != 0x7fffffff:
                continue
              let
                address = appState.playerAddresses.getOrDefault(
                  websocket, "unknown")
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if game.phase == Lobby:
                pending.add(PendingPlayerJoin(
                  websocket: websocket, address: address, token: token,
                  requestedSlot: slot,
                  slotIndex: game.resolvePlayerSlot(address, token, slot)))
              else:
                appState.playerIndices[websocket] = -1
            pending.sort(comparePendingPlayerJoins)
            for join in pending:
              if join.slotIndex != game.nextPlayerSlot():
                continue
              try:
                appState.playerIndices[join.websocket] = game.addPlayer(
                  join.address, join.slotIndex, join.token)
              except LaneError:
                socketsToClose.add(join.websocket)
                continue
              appState.playerSlots[join.websocket] = join.slotIndex
              replayWriter.writeJoin(
                tickTime(game.tickCount), join.slotIndex, join.address,
                join.slotIndex, join.token)
              while replayWriter.lastMasks.len < 4:
                replayWriter.lastMasks.add(0)
              progressed = true

          if laneMode and not lanesBuilt and game.phase == Lobby and
              (game.players.len >= config.numAgents or forceStart):
            ## Seat every lane that has no live connection with a trusted
            ## join carrying ONLY its anonymous alias, so the replay's join
            ## stream leaks no policy identity and no lane is ever uncommanded.
            while game.players.len < config.numAgents:
              let order = game.players.len
              try:
                discard game.addPlayer(
                  laneAlias(order), order, "", trusted = true)
              except LaneError as error:
                echo "lane construction failed at seat ", order, ": ",
                  error.msg
                break
              replayWriter.writeJoin(
                tickTime(game.tickCount), order, laneAlias(order), order, "")
              while replayWriter.lastMasks.len < 4:
                replayWriter.lastMasks.add(0)
            lanesBuilt = game.players.len >= config.numAgents
            if lanesBuilt:
              for seat in 0 ..< config.numAgents:
                game.seatPolicyKind[seat] = engine.policyKind(seat)
              echo "cabinet ready: ", game.players.len, " lanes, rom ",
                config.rom

        for websocket, playerIndex in appState.playerIndices.pairs:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add(websocket)
          playerViewerStates.add(appState.playerViewers[websocket])
          ## EDIT 1: seats send NO inputs. Any mask arriving on a player
          ## socket is discarded; every action byte comes from the control
          ## layer below.

        if not replayLoaded:
          ## Registrations that cannot be applied YET are HELD, not dropped:
          ## joins are strictly slot-sequential and the lobby sends frames to
          ## a socket before it has been admitted, so a seat's registration
          ## can arrive while its player index is still 0x7fffffff.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
            if playerIndex < 0 or playerIndex >= config.numAgents:
              if websocket.isPlayerWebSocket() and parseRegistration(chatText).ok:
                held.add((websocket, chatText))
              continue
            let registration = parseRegistration(chatText)
            if not registration.ok:
              continue                 ## seats do not chat; lanes do not talk.
            var policy = engine.seats[playerIndex]
            let firstRegistration = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[playerIndex] = policy
            game.seatPolicyKind[playerIndex] = engine.policyKind(playerIndex)
            if firstRegistration:
              replayWriter.writeChat(
                tickTime(game.tickCount), playerIndex,
                registerRecord(
                  playerIndex, playerIndex, laneAlias(playerIndex),
                  policy.label, engine.policyKind(playerIndex),
                  $policy.baseline))
              echo "seat ", playerIndex, " registered: kind=",
                engine.policyKind(playerIndex), " baseline=", $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    # --- edit 3: the decision turn, then the control-compiled action bytes -
    if laneMode and lanesBuilt and game.phase == Playing:
      let
        elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
        turnTicks = max(1, config.turnTicks)
        turnIndex = game.gameTicksElapsed() div turnTicks
      if game.gameTicksElapsed() mod turnTicks == 0 and turnIndex != lastTurnKey:
        lastTurnKey = turnIndex
        if not loggedMissingRegister:
          loggedMissingRegister = true
          for seat in 0 ..< config.numAgents:
            if not engine.seats[seat].registered:
              ## EDIT 6: loudly, at the first turn. A silently-lost register
              ## packet is otherwise indistinguishable from an LLM that chose
              ## badly (grf-football round 2, 2026-08-27).
              echo "ERROR: SEAT ", seat, " NEVER REGISTERED — playing arcader"
              game.seatPolicyKind[seat] = "scripted"
        let records = engine.turn(
          game, turnIndex, config.turnsPerEpisode(), elapsedSeconds)
        for record in records:
          replayWriter.writeChat(tickTime(game.tickCount), 0, record)
          game.applyControlRecord(record)
        for seat in 0 ..< 4:
          if not engine.haveStance[seat]:
            continue
          let record = engine.stances[seat].boundedStanceRecord(
            turnIndex, seat, seat, laneAlias(seat))
          replayWriter.writeChat(tickTime(game.tickCount), seat, record)
          game.applyControlRecord(record)
          game.emitEvent(
            Stance, lane = seat, amount = turnIndex,
            detail = $engine.stances[seat].source,
            content = engine.stances[seat].note)
      for seat in 0 ..< 4:
        cmds[seat] = laneCommand(
          controls[seat], game.lanes[seat], engine.stances[seat],
          config.preset, game.tickCount)
        ## EDIT 2: the codec's own change-only guard is the whole action log.
        replayWriter.writeInputMaskChange(
          tickTime(game.tickCount), seat, cmds[seat])
    elif laneMode and lanesBuilt:
      for seat in 0 ..< 4:
        replayWriter.writeInputMaskChange(tickTime(game.tickCount), seat, 0)

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        game, broadcastTracker, replaySeekTicks, replayCommands)
    else:
      var faultRule = ""
      let phaseBefore = game.phase
      try:
        game.step(cmds)
      except SimGuardError as guard:
        echo "atari-57: SIM GUARD tripped at tick ", game.tickCount, ": ",
          guard.msg
        faultRule = EndRuleSimFault
      except CatchableError as error:
        echo "atari-57: HOST ERROR at tick ", game.tickCount, ": ", error.msg
        faultRule = EndRuleHostError
      if faultRule.len > 0:
        game.finishGame(ReasonFault, faultRule)
        quitAfterFrame = true
      else:
        replayWriter.writeHash(uint32(game.tickCount), game.gameHash())
        game.stepEvents(broadcastTracker, frameEvents)
        if game.collectEvents:
          for event in game.events:
            collectedEvents.add(event)
          game.events.setLen(0)
        if phaseBefore != GameOver and game.phase == GameOver:
          quitAfterFrame = true

    if not replayLoaded and config.fastMode:
      sockets.resetPlayerReady()

    var spritesOffFlags = newSeq[bool](sockets.len)
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 ..< sockets.len:
          spritesOffFlags[i] = appState.spritesOff.getOrDefault(sockets[i], false)
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      var index = -1
      {.gcsafe.}:
        withLock appState.lock:
          index = appState.playerIndices.getOrDefault(sockets[i], -1)
      if index < 0 or index >= 4:
        continue
      let framePacket = game.buildSpriteProtocolPlayerUpdates(
        index, playerViewerStates[i], nextState, spritesOff = spritesOffFlags[i])
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        (if spritesOffFlags[i]: framePacket.stripSpritePixels()
         else: framePacket),
        nextState.sentPlacements)
      try:
        if wirePacket.len == 0:
          ## One binary message per tick is the frame contract — clients count
          ## messages to advance. An all-deduped frame still ships, as empty.
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          game.buildReplayViewerPacket(
            replayPlayer, globalStates[i], nextState, frameEvents)
        else:
          var built = game.buildSpriteProtocolUpdates(
            globalStates[i], nextState, [], game.tickCount,
            true, 1, config.maxTicks, false, false, -1)
          if built.len > 0:
            built.addSprite(
              BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
              game.buildStateJson(
                frameEvents, true, 1, config.maxTicks, false, false, -1, -1))
          built
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      ## The `result` control record: the full results document, written once
      ## into the replay chat stream at episode end, so the bytes are
      ## SELF-SUFFICIENT — the outcome would otherwise live only at
      ## COGAME_RESULTS_URI, which a spectator with the file cannot read.
      replayWriter.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        let bytes = readFile(saveReplayPath)
        echo "Replay written: ", saveReplayPath, " (", bytes.len, " bytes)"
        {.gcsafe.}:
          withLock replayArtifactLock:
            replayArtifactBytes = bytes
        runtimeConfig.writeReplay(bytes)
      if eventsPath.len > 0:
        writeFile(eventsPath, collectedEvents.eventsJsonl(game.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      let scoresJson = game.playerResultsJson() & "\n"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(scoresJson)
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, scoresJson)
        echo "Scores written: ", saveScoresPath
      echo "results: ", scoresJson
      ## EDIT 5: bounded shutdown grace. The certification runner pings
      ## /healthz and /global AFTER the player pods start, and a short episode
      ## can already have written its artifacts by then.
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick, not replayLoaded and config.fastMode, sockets)
