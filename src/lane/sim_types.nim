## The cabinet's shared vocabulary: constants (including `GameVersion` and its
## prepend-only changelog), the lane/sprite/tile types, the `GameConfig`
## record and the small pure helpers every leaf module needs.
##
## Inherited from `coworld-ctf`'s `src/ctf/sim_types.nim`: the module's ROLE
## (one shared vocabulary, no gameplay), the `GameVersion` changelog
## discipline, the `TargetFps`/`ReplayFps`/`PlaybackSpeeds` trio, the
## `GamePhase` enum, the reason/endRule string constants, the websocket path
## constants, and the rule that **field order in every type here is WIRE
## FORMAT** — `SimServer` is flatty-serialized POSITIONALLY into replay
## keyframes, so reordering a field without a `GameVersion` bump breaks every
## recorded replay.
##
## INTEGER DISCIPLINE (design note §Integer arithmetic rules): every stored
## sim field below is explicitly `int32`, `int64`, `uint8`, `int8`, `bool` or
## an enum. There is NO bare `int` in a hashed field, because Nim's `int` is
## 64-bit natively and 32-bit under `--cpu:wasm32`, and the wasm replay
## viewer re-simulates the very same module the native server ran.

import std/[strutils]

const
  GameName* = "atari-57"
  GameVersion* = "1"  ## GV1 (lane rules): four isolated lanes, one action
    ## byte, three roms. The cabinet's first published rule set: a 17x17 tile
    ## screen per seat, `chomper` / `brickfall` / `gallery` sharing one tile
    ## engine, a 15-value action byte compiled by a deterministic autopilot
    ## from an LLM stance every 120 ticks, and `points/100 + livesLeft` as the
    ## whole score. Prepend the next rule's headline ABOVE this line; never
    ## reuse a number for a different rule.

  # --- timing ---------------------------------------------------------------
  TargetFps* = 24        ## kept verbatim from paintbot: every speed-coupled
                         ## layer (playback speeds, lull scan, momentum
                         ## series, transport bar) is keyed to it.
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  DefaultMaxTicks* = 2880       ## 120.0 s of sim time.
  DefaultMinTicks* = 1440       ## 60.0 s floor: a replay shorter than the
                                ## viewer smoke's soak reads as "frozen".
  DefaultTurnTicks* = 120       ## 5.0 s of sim time per decision turn.
  DefaultStartWaitTicks* = 2 * TargetFps
  DefaultGameOverTicks* = 96
  DefaultLobbyJoinTimeoutTicks* = 2880

  # --- decision layer -------------------------------------------------------
  DefaultTurnBudgetMs* = 16_000  ## hard monotonic cap around one whole turn.
  DefaultAttempt1Ms* = 9_000     ## first parallel batch deadline.
  DefaultRetryMs* = 5_000        ## single retry batch deadline (9 + 5 <= 16).
  DefaultTurnSpacingMs* = 12_000 ## wall-clock floor between batch STARTS:
                                 ## 4 requests / 12 s = 20 rpm, under the
                                 ## Bedrock sidecar's 30 rpm per-episode cap.
  DefaultWallClockBudgetSeconds* = 660
  DefaultMaxOutputTokens* = 900  ## 400 truncates Haiku mid-object.

  # --- string caps, all in RUNES, never bytes -------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxModeRunes* = 8
  MaxZoneRunes* = 8
  MaxFireRunes* = 6
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxStanceRunes* = 600
  MaxPromptRunes* = 4000

  # --- the lane grid --------------------------------------------------------
  GridW* = 17
  GridH* = 17
  GridCells* = GridW * GridH        ## 289
  TileU* = 12_000                   ## micro-units per tile.
  HalfTileU* = TileU div 2
  LaneSpanU* = GridW * TileU        ## 204 000 µu across a lane.
  BoxHalf* = 4_000                  ## avatar / chaser box half-extent.
  BallHalf* = 3_000                 ## ball + bolt box half-extent.
  LatchTicks* = 6                   ## the deterministic turn latch window.
  LatchWindowU* = 640               ## how close to a tile centre a latch fires.
  BallSpeedMax* = 3_920             ## capped brickfall ball speed, µu/tick.
  BoltSpeedFriendly* = 4_000        ## gallery friendly bolt, µu/tick (up).
  BoltSpeedHostile* = 2_600         ## gallery hostile bolt, µu/tick (down).
  BoltReloadTicks* = 6
  MaxFriendlyBolts* = 2
  MaxHostileBolts* = 3
  PaddleHalfU* = 18_000             ## a 3-tile paddle, half its width.
  DyingTicks* = 24
  RespawningTicks* = 24
  ChaserChaseSpeed* = 1_250
  ChaserFleeSpeed* = 900
  ChaserReturnSpeed* = 2_000
  SaucerSpeed* = 3_000
  ScatterHoldTicks* = 120
  MaxTargets* = 12                  ## `targets` cap in the observation.
  MaxSprites* = 48                  ## hard cap on live sprites per lane.
  BfsNodeCap* = 300                 ## the autopilot's bounded flood.

  ## The no-tunnelling bound, asserted directly by tests/test_physics.nim:
  ## the fastest collidable travels 4 000 µu in a tick and the shallowest
  ## contact window is half a tile plus a box half-side.
  MaxSpriteSpeed* = 4_000
  ContactWindowU* = HalfTileU + BallHalf   ## 9 000 > 4 000.

  # --- the board (four lanes in a 2x2 quad-split) ---------------------------
  BoardTiles* = 35                  ## 17 + 1 gutter + 17.
  BoardTilePx* = 40                 ## board pixels per tile.
  MapWidth* = BoardTiles * BoardTilePx     ## 1400
  MapHeight* = BoardTiles * BoardTilePx    ## 1400
  LaneOrigins*: array[4, tuple[col, row: int]] = [
    (0, 0), (GridW + 1, 0), (0, GridH + 1), (GridW + 1, GridH + 1)
  ]

  # --- scoring --------------------------------------------------------------
  PointsMicro* = 10_000        ## 100 arcade points = 1.000 score.
  LifeMicro* = 1_000_000       ## each unspent life = 1.000 score.

  # --- end conditions -------------------------------------------------------
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleAllLanesOver* = "all_lanes_over"
  EndRuleFullTime* = "full_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  # --- rom names ------------------------------------------------------------
  RomChomper* = "chomper"
  RomBrickfall* = "brickfall"
  RomGallery* = "gallery"
  RomNames* = [RomChomper, RomBrickfall, RomGallery]

  # --- websocket routes (paintbot's, kept) ----------------------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

  MaxPlayers* = 4
  MinPlayersDefault* = 4

  ## The four in-game aliases. A seat is RED / BLUE / GREEN / YELLOW in game
  ## and NOTHING else; real policy names live spectator-side only.
  LaneAliases* = ["RED", "BLUE", "GREEN", "YELLOW"]
  LaneTeamKeys* = ["red", "blue", "green", "yellow"]

type
  LaneError* = object of ValueError

  SimGuardError* = object of CatchableError
    ## A sim INVARIANT tripped (a centre outside its lane, a velocity above
    ## `BallSpeedMax`, a `dir` outside 0..4, lives out of range, a negative
    ## point total). The episode ends `fault` / `sim_fault` and the partial
    ## replay is still written.

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  AvatarMode* = enum
    ## How the avatar may move. Ordinals are wire format.
    amFreeGrid                 ## chomper: corridors, turns at tile centres.
    amRailBottom               ## brickfall / gallery: a paddle on one row.

  Tile* = enum
    ## One lane tile. Ordinals are wire format: APPEND, never insert.
    tlFloor
    tlWall
    tlPellet
    tlPower
    tlBrick
    tlBunker
    tlTunnel                   ## an open lane edge (chomper's row-8 mouths).

  LanePhase* = enum
    lpPlaying
    lpDying
    lpRespawning
    lpOver

  SpriteKind* = enum
    skNone
    skChaser
    skBall
    skMarcher
    skSaucer
    skBoltFriendly
    skBoltHostile

  SpriteState* = enum
    ssIdle
    ssChasing
    ssScatter
    ssFleeing
    ssReturning
    ssServing

  LaneSprite* = object
    ## One sprite in one lane. Positions and velocities are micro-units;
    ## every field is hashed.
    kind*: SpriteKind
    state*: SpriteState
    alive*: bool
    x*, y*: int32
    vx*, vy*: int32
    dir*: uint8                ## 0 stay, 1 up, 2 down, 3 left, 4 right.
    timer*: int32
    id*: int32                 ## personality / formation index.
    homeCol*, homeRow*: int8

  Lane* = object
    ## One sealed 17x17 screen. `stepLane` is a pure function of THIS object,
    ## its own action byte and its own RNG stream: it never reads or writes
    ## another lane, which is the invariant `tests/test_isolation.nim` pins.
    phase*: LanePhase
    phaseTimer*: int32
    lives*: int32
    points*: int32
    screen*: int32
    overTick*: int32
    lastScoreTick*: int32
    recordFlag*: bool
    ax*, ay*: int32            ## avatar centre, micro-units.
    facing*: uint8
    pendingDir*: uint8
    pendingAge*: int32
    reload*: int32
    tiles*: array[GridCells, uint8]
    bunkerHp*: array[GridCells, uint8]
    sprites*: seq[LaneSprite]
    powerTicksLeft*: int32
    chain*: int32
    bestChain*: int32
    speedPermille*: int32
    marchTicks*: int32
    marchTimer*: int32
    marchDir*: int32           ## +1 right, -1 left.
    marchTopRow*: int32
    scatterTimer*: int32
    scatterHold*: int32
    saucerCooldown*: int32
    serveTimer*: int32
    deaths*: int32
    screensCleared*: int32
    shotsFired*: int32
    brickHits*: int32
    scoreMicro*: int64
    rngDraws*: int32
    rngA*, rngB*: uint64       ## the lane's own xoroshiro128+ stream.

  RomPreset* = object
    ## The fully resolved cartridge. Everything a replay needs to re-derive
    ## the rules is in here and in the config JSON.
    rom*: string
    livesPerLane*: int32
    avatarMode*: AvatarMode
    avatarSpeed*: int32
    parScore*: int32
    fireEnabled*: bool
    brakeEnabled*: bool
    screenClearBonus*: int32
    rampPermille*: int32
    latchTicks*: int32
    powerTicks*: int32
    marchTicks0*: int32
    fireChancePermille*: int32
    ballSpeedMax*: int32

  PlayerSlotConfig* = object
    name*: string
    token*: string

  Player* = object
    ## One seat. `address` is the REAL policy name and is spectator-side
    ## only; in-game the seat is `LaneAliases[joinOrder]`.
    address*: string
    token*: string
    slot*: int32
    joinOrder*: int32
    lane*: int32
    connected*: bool
    reward*: int32

  GameConfig* = object
    seed*: int
    speed*: int
    numAgents*: int
    minPlayers*: int
    closedRoster*: bool
    maxTicks*: int
    minTicks*: int
    maxGames*: int
    startWaitTicks*: int
    gameOverTicks*: int
    lobbyJoinTimeoutTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    model*: string
    maxOutputTokens*: int
    # --- rom keys (schema defaults -> named preset -> explicit key) ---------
    rom*: string
    livesPerLane*: int
    parScore*: int
    avatarSpeedMilli*: int
    latchTicks*: int
    powerTicks*: int
    screenClearBonus*: int
    rampPermille*: int
    fireEnabled*: bool
    brakeEnabled*: bool
    marchTicks0*: int
    fireChancePermille*: int
    ballSpeedMaxMilli*: int
    preset*: RomPreset
    tokens*: seq[string]
    players*: seq[PlayerSlotConfig]
    slots*: seq[string]        ## per-slot alias (RED / BLUE / GREEN / YELLOW).

  SimEventKind* = enum
    ## The tier-2 analysis stream's vocabulary (`COGAME_EVENTS_URI`).
    ## `SimEvent` never enters `gameHash`, so nothing here can affect
    ## determinism.
    Pickup
    Chip
    Bunker
    Chain
    Saucer
    NearMiss
    LifeLost
    ScreenClear
    Record
    LaneOver
    Stance
    PhaseChange

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    lane*: int
    amount*: int
    col*, row*: int
    detail*: string
    content*: string

  SimServer* = object
    ## The four-lane container. Flatty-serialized POSITIONALLY into replay
    ## keyframes: **field order here is wire format**.
    config*: GameConfig
    tickCount*: int
    gameStartTick*: int
    phase*: GamePhase
    lobbyTicks*: int
    startCountdown*: int
    gameOverHold*: int
    lanes*: array[4, Lane]
    players*: seq[Player]
    winner*: int
    isDraw*: bool
    timeLimitReached*: bool
    endReason*: string
    endRule*: string
    placements*: array[4, int]
    stopped*: bool
    stoppedTick*: int
    seatNames*: array[4, string]
    seatPolicyKind*: array[4, string]
    llmTurns*: array[4, int]
    fallbackTurns*: array[4, int]
    seatMode*: array[4, string]
    seatZone*: array[4, string]
    seatSay*: array[4, string]
    seatSayUntil*: array[4, int]
    feedRecords*: seq[string]
    events*: seq[SimEvent]
    collectEvents*: bool
    gameEventLoggingEnabled*: bool
    needsReregister*: bool

proc tileIndex*(col, row: int): int {.inline.} =
  ## The flat index of one lane tile. Callers clamp; this never bounds-checks
  ## for them, because every hot path already knows the coordinate is legal.
  row * GridW + col

proc inGrid*(col, row: int): bool {.inline.} =
  col >= 0 and col < GridW and row >= 0 and row < GridH

proc laneAlias*(lane: int): string =
  ## The ANONYMOUS in-game name of one lane. Never a policy name.
  if lane >= 0 and lane < LaneAliases.len: LaneAliases[lane] else: "LANE"

proc laneTeamKey*(lane: int): string =
  ## The chrome `teams` key of one lane. `chrome_common.js` pins
  ## TEAM_ORDER = ['red','blue','green','yellow'], which is why these four
  ## names — and no others — make the four plates lay out with no edit.
  if lane >= 0 and lane < LaneTeamKeys.len: LaneTeamKeys[lane] else: "red"

proc dirOf*(cmd: uint8): int32 {.inline.} =
  ## Decodes one action byte's direction. `cmd >= 15` is REPAIRED to 0 in
  ## both the server and the replay runtime, so a corrupt byte can never
  ## desynchronise the two.
  if cmd >= 15'u8: 0'i32 else: int32(cmd) mod 5'i32

proc actOf*(cmd: uint8): int32 {.inline.} =
  ## Decodes one action byte's action: 0 none, 1 fire, 2 brake.
  if cmd >= 15'u8: 0'i32 else: int32(cmd) div 5'i32

proc decodeAction*(cmd: uint8): tuple[dir, act: int32] {.inline.} =
  ## The ONE decoder both the server and the wasm replay runtime call.
  (dirOf(cmd), actOf(cmd))

proc encodeAction*(dir, act: int32): uint8 {.inline.} =
  ## Builds a legal action byte. Out-of-range parts collapse to 0.
  if dir < 0 or dir > 4 or act < 0 or act > 2:
    0'u8
  else:
    uint8(act * 5 + dir)

proc dirVector*(dir: int32): tuple[dx, dy: int32] {.inline.} =
  case dir
  of 1: (0'i32, -1'i32)
  of 2: (0'i32, 1'i32)
  of 3: (-1'i32, 0'i32)
  of 4: (1'i32, 0'i32)
  else: (0'i32, 0'i32)

proc facingText*(dir: uint8): string =
  case dir
  of 1: "up"
  of 2: "down"
  of 3: "left"
  of 4: "right"
  else: "stay"

proc romText*(rom: string): string =
  ## Normalises a rom name; anything unknown resolves to `chomper` so a
  ## malformed config still plays a real cartridge.
  let key = rom.strip().toLowerAscii()
  for name in RomNames:
    if name == key:
      return name
  RomChomper

proc isRomName*(rom: string): bool =
  for name in RomNames:
    if name == rom:
      return true
  false
