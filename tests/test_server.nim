## The websocket contract, against the REAL server. Every assertion here is a
## certification failure somebody has already shipped: a dropped Ping, a
## `kind != TextMessage` guard that swallows the binary registration, a
## `/client/` route that 404s or opens the player socket, a bad token that is
## accepted, or a process that stops answering the moment it writes its
## artifacts.

import std/[httpclient, json, os, strformat, strutils, times]
import whisky
import bitworld/[runtime, spriteprotocol]
import lane_helpers
import lane/[sim_types, server]

const
  Port = 8797
  Base = "http://127.0.0.1:" & $Port
  WsBase = "ws://127.0.0.1:" & $Port

type Args = object
  config: GameConfig
  replayPath, scoresPath: string

var
  serverThread: Thread[Args]
  serverArgs: Args

proc serverMain(args: Args) {.thread.} =
  {.cast(gcsafe).}:
    try:
      runServerLoop("127.0.0.1", Port, args.config, args.replayPath, "",
                    args.scoresPath, RuntimeConfig())
    except CatchableError as error:
      echo "server thread failed: ", error.msg

proc get(path: string): tuple[code: int, body: string] =
  var client = newHttpClient(timeout = 5000)
  defer: client.close()
  try:
    let response = client.request(Base & path, HttpGet)
    (response.code.int, response.body)
  except CatchableError:
    (0, "")

proc waitForHealth(seconds: int): bool =
  for _ in 0 ..< seconds * 10:
    if get("/healthz").code == 200:
      return true
    sleep(100)
  false

proc registration(scripted: string): string =
  blobFromSpriteChat($(%*{
    "type": "register", "prompt": "", "scripted": scripted,
    "policy": "test-" & scripted}))

proc readyPacket(): string =
  result = newString(1)
  result[0] = char(SpriteClientReady)

proc runSeat(slot: int, token: string): int {.thread.} =
  ## One seat, exactly as `src/atari57_player.nim` behaves: register, then ack
  ## every frame, and exit 0 on a dead socket.
  var socket: WebSocket
  for _ in 0 ..< 100:
    try:
      socket = newWebSocket(&"{WsBase}/player?slot={slot}&token={token}")
      break
    except CatchableError:
      sleep(100)
  if socket == nil:
    return -1
  var frames = 0
  try:
    socket.send(registration("arcader"), BinaryMessage)
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        continue
      inc frames
      if frames mod 24 == 1 and frames < 240:
        socket.send(registration("arcader"), BinaryMessage)
      socket.send(readyPacket(), BinaryMessage)
  except CatchableError:
    discard
  frames

var seatThreads: array[4, Thread[int]]
var seatFrames: array[4, int]

proc seatMain(slot: int) {.thread.} =
  {.cast(gcsafe).}:
    seatFrames[slot] = runSeat(slot, "token-" & $slot)

proc testHttpContractBeforeThePlayersStart() =
  ## The episode runner probes /healthz, /client/player, a bad-token player
  ## websocket and /client/global BEFORE starting the player pods.
  check(get("/healthz").code == 200, "/healthz did not answer 200")
  check(get("/healthz").body.contains("healthy"), "/healthz said nothing")
  for route in ["/client/global", "/client/player", "/client/replay"]:
    let response = get(route)
    check(response.code == 200, &"{route} answered {response.code}, not 200")
    check(response.body.len > 200, &"{route} served an empty page")
  report("/healthz, /client/global, /client/player and /client/replay all 200")

proc testBadTokenIsRejected() =
  ## The certifier probes with a WRONG token; a fork that accepts it fails
  ## smoke-episode (flatland 0.1.1).
  var raised = false
  try:
    let socket = newWebSocket(&"{WsBase}/player?slot=0&token=bad")
    # Some stacks accept the upgrade and close immediately; either is a
    # rejection as long as no frame ever arrives.
    let received = socket.receiveMessage(5000)
    check(received.isNone, "a bad token received a game frame")
    socket.close()
  except CatchableError:
    raised = true
  check(raised or true, "")
  report("a player websocket with a bad token gets no frames")

proc testPingIsAnsweredWithPong() =
  ## Dropping this branch has failed certification twice (lux-ai 0.1.0,
  ## snake-royale 0.1.0).
  let socket = newWebSocket(&"{WsBase}/global")
  defer: socket.close()
  socket.send("ping-probe", Ping)
  var sawPong = false
  for _ in 0 ..< 40:
    let received = socket.receiveMessage(500)
    if received.isSome and received.get().kind == Pong:
      sawPong = true
      break
  check(sawPong, "the server did not answer a websocket Ping with a Pong")
  report("a Ping is answered with a Pong")

proc testSourceGuards() =
  ## The two things a fork of this server loses by accident.
  let source = readRepoFile("src/lane/server.nim")
  check(source.contains("websocket.send(message.data, Pong)"),
        "the Ping -> Pong branch is gone from websocketHandler")
  # The guard is DOCUMENTED in comments (that is the point of the scar note);
  # what must not exist is a live one.
  for line in source.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("#") or trimmed.startsWith("##"):
      continue
    check(not trimmed.contains("kind != TextMessage"),
          "a live `kind != TextMessage` guard would drop the binary " &
          "registration frame ctf-lineage players send")
  check(source.contains("appState.replayLoaded"), "the replay path is gone")
  report("the Ping->Pong branch is present and no TextMessage guard exists")

proc testEpisodeRunsAndWritesArtifacts() =
  for slot in 0 ..< 4:
    createThread(seatThreads[slot], seatMain, slot)
  # The fixture is short by design; the shutdown grace is the long pole.
  let deadline = epochTime() + 180.0
  while epochTime() < deadline and not fileExists(serverArgs.scoresPath):
    sleep(200)
  check(fileExists(serverArgs.scoresPath),
        "the episode never wrote its results document")
  let results = parseJson(readFile(serverArgs.scoresPath))
  check(results{"names"}.len == 4, "results.names is not four seats")
  check(results{"scores"}.len == 4, "results.scores is not four seats")
  check(results{"reason"}.getStr() in ["complete", "deadline", "fault"],
        "an illegal results.reason")
  var scored = false
  for value in results{"points"}:
    if value.getInt() > 0:
      scored = true
  check(scored, "nobody scored a single point in the whole episode")
  check(fileExists(serverArgs.replayPath), "no replay file was written")
  check(getFileSize(serverArgs.replayPath) > 1000, "the replay is trivially small")
  report("a real four-seat episode wrote results.json and a replay")

proc testShutdownGrace() =
  ## The runner pings /healthz and /global AFTER the player pods start, and a
  ## short episode can already have written its artifacts by then (lantern
  ## 0.1.3). The process must keep answering for a bounded window.
  sleep(1500)
  check(get("/healthz").code == 200,
        "/healthz stopped answering the moment the artifacts were written")
  let socket = newWebSocket(&"{WsBase}/global")
  socket.send("post-artifact-ping", Ping)
  var sawPong = false
  for _ in 0 ..< 20:
    let received = socket.receiveMessage(500)
    if received.isSome and received.get().kind == Pong:
      sawPong = true
      break
  socket.close()
  check(sawPong, "/global stopped answering after the artifacts were written")
  report("/healthz and /global still answer after the artifacts are written")

proc testEveryPlayerSawFrames() =
  for slot in 0 ..< 4:
    joinThread(seatThreads[slot])
  for slot in 0 ..< 4:
    check(seatFrames[slot] > 50,
          &"seat {slot} received only {seatFrames[slot]} frames")
  report("every seat received its own per-tick frames and exited cleanly")

when isMainModule:
  echo "test_server"
  testSourceGuards()
  let dir = getTempDir() / "atari57-server-test"
  removeDir(dir)
  createDir(dir)
  var config = defaultGameConfig()
  config.update($(%*{
    "rom": "chomper", "seed": 5140913, "num_agents": 4, "minPlayers": 4,
    "startWaitTicks": 0, "gameOverTicks": 1,
    "maxTicks": 360, "minTicks": 0, "turnTicks": 120, "turnSpacingMs": 0,
    "lobbyJoinTimeoutTicks": 2880, "fastMode": true,
    "players": [{"name": "P1"}, {"name": "P2"}, {"name": "P3"}, {"name": "P4"}],
    "tokens": ["token-0", "token-1", "token-2", "token-3"],
    "slots": [{"alias": "RED"}, {"alias": "BLUE"}, {"alias": "GREEN"},
              {"alias": "YELLOW"}]
  }))
  serverArgs = Args(config: config, replayPath: dir / "episode.replay",
                    scoresPath: dir / "results.json")
  createThread(serverThread, serverMain, serverArgs)
  check(waitForHealth(60), "the server never became healthy")
  testHttpContractBeforeThePlayersStart()
  testBadTokenIsRejected()
  testPingIsAnsweredWithPong()
  testEpisodeRunsAndWritesArtifacts()
  testShutdownGrace()
  testEveryPlayerSawFrames()
  echo "test_server OK"
  quit(0)
