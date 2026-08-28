## `GameConfig` lifecycle: the schema defaults, `update` (which parses the
## platform's `COGAME_CONFIG_URI` document), and `configJson` (which is what
## the replay header carries and therefore what playback re-derives the whole
## episode from).
##
## Kept from `coworld-ctf`'s `src/ctf/sim_config.nim`: the shape
## (`defaultGameConfig` / `update` / `configJson` / `configuredPlayerName` /
## `playerJoinAllowed`), the "unknown keys are ignored, malformed keys raise"
## contract, and the rule that anything a replay must reproduce is echoed
## into `configJson`. The arena's knobs are gone; the lane's are here, with
## `rom.applyPreset` running BETWEEN the defaults and the explicit keys.

import std/[json, strutils]
import sim_types, rom, maps, sprites

proc defaultGameConfig*(): GameConfig =
  result = GameConfig(
    seed: 5_140_913,
    speed: 1,
    numAgents: 4,
    minPlayers: MinPlayersDefault,
    closedRoster: false,
    maxTicks: DefaultMaxTicks,
    minTicks: DefaultMinTicks,
    maxGames: 1,
    startWaitTicks: DefaultStartWaitTicks,
    gameOverTicks: DefaultGameOverTicks,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    fastMode: true,
    showPlayerLabels: false,
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    model: "",
    maxOutputTokens: DefaultMaxOutputTokens,
    rom: RomChomper,
    livesPerLane: 3,
    parScore: 2_600,
    avatarSpeedMilli: 1_500,
    latchTicks: LatchTicks,
    powerTicks: 144,
    screenClearBonus: 500,
    rampPermille: 1_060,
    fireEnabled: false,
    brakeEnabled: true,
    marchTicks0: 20,
    fireChancePermille: 18,
    ballSpeedMaxMilli: BallSpeedMax,
    tokens: @[],
    players: @[],
    slots: @[]
  )
  result.applyPreset(nil)

proc readInt(node: JsonNode, name: string, target: var int) =
  ## One integer key. A key of the wrong TYPE raises rather than being
  ## silently ignored: a config the platform meant to set and we quietly
  ## dropped is the worst outcome of the three.
  if not node.hasKey(name):
    return
  let value = node[name]
  case value.kind
  of JInt: target = int(value.getBiggestInt())
  of JFloat: target = int(value.getFloat())
  of JString:
    try: target = parseInt(value.getStr().strip())
    except CatchableError:
      raise newException(LaneError, "config key " & name & " is not an integer")
  else:
    raise newException(LaneError, "config key " & name & " is not an integer")

proc readBool(node: JsonNode, name: string, target: var bool) =
  if not node.hasKey(name):
    return
  let value = node[name]
  case value.kind
  of JBool: target = value.getBool()
  of JInt: target = value.getBiggestInt() != 0
  else:
    raise newException(LaneError, "config key " & name & " is not a boolean")

proc readStr(node: JsonNode, name: string, target: var string) =
  if not node.hasKey(name):
    return
  if node[name].kind != JString:
    raise newException(LaneError, "config key " & name & " is not a string")
  target = node[name].getStr()

proc update*(config: var GameConfig, configJson: string) =
  ## Applies one runtime config document. Order is load-bearing: the flat
  ## keys land first, then `applyPreset` resolves the cartridge in the
  ## defaults -> preset -> explicit order, using the raw object to tell an
  ## explicitly supplied key from one that merely equals a default.
  if configJson.len == 0:
    config.applyPreset(nil)
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(LaneError, "config is not valid JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(LaneError, "config must be a JSON object")

  node.readInt("seed", config.seed)
  node.readInt("speed", config.speed)
  node.readInt("num_agents", config.numAgents)
  node.readInt("numAgents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readBool("closedRoster", config.closedRoster)
  node.readInt("maxTicks", config.maxTicks)
  node.readInt("minTicks", config.minTicks)
  node.readInt("maxGames", config.maxGames)
  node.readInt("startWaitTicks", config.startWaitTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readInt("turnTicks", config.turnTicks)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("turnSpacingMs", config.turnSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readStr("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)

  node.readStr("rom", config.rom)
  if not isRomName(romText(config.rom)) or
      (node.hasKey("rom") and not isRomName(node["rom"].getStr().strip().toLowerAscii())):
    raise newException(
      LaneError,
      "rom must be one of chomper, brickfall, gallery; got: " &
        (if node.hasKey("rom"): node["rom"].getStr() else: config.rom))
  node.readInt("livesPerLane", config.livesPerLane)
  node.readInt("parScore", config.parScore)
  node.readInt("avatarSpeedMilli", config.avatarSpeedMilli)
  node.readInt("latchTicks", config.latchTicks)
  node.readInt("powerTicks", config.powerTicks)
  node.readInt("screenClearBonus", config.screenClearBonus)
  node.readInt("rampPermille", config.rampPermille)
  node.readBool("fireEnabled", config.fireEnabled)
  node.readBool("brakeEnabled", config.brakeEnabled)
  node.readInt("marchTicks0", config.marchTicks0)
  node.readInt("fireChancePermille", config.fireChancePermille)
  node.readInt("ballSpeedMaxMilli", config.ballSpeedMaxMilli)

  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    config.tokens = @[]
    for item in node["tokens"]:
      config.tokens.add(item.getStr())
  if node.hasKey("players") and node["players"].kind == JArray:
    config.players = @[]
    for item in node["players"]:
      var entry = PlayerSlotConfig()
      if item.kind == JObject:
        entry.name = item{"name"}.getStr()
        entry.token = item{"token"}.getStr()
      elif item.kind == JString:
        entry.name = item.getStr()
      config.players.add(entry)
  if node.hasKey("slots") and node["slots"].kind == JArray:
    config.slots = @[]
    for item in node["slots"]:
      let index = config.slots.len
      if item.kind == JObject:
        let alias = item{"alias"}.getStr()
        config.slots.add(
          if alias.len > 0: alias else: laneAlias(index))
      elif item.kind == JString:
        config.slots.add(item.getStr())
  for i in 0 ..< config.tokens.len:
    if i < config.players.len and config.players[i].token.len == 0:
      config.players[i].token = config.tokens[i]

  # Bounds. Everything below is untrusted platform input.
  config.numAgents = clamp(config.numAgents, 1, MaxPlayers)
  config.minPlayers = clamp(config.minPlayers, 1, config.numAgents)
  config.maxTicks = clamp(config.maxTicks, 120, 20_000)
  config.minTicks = clamp(config.minTicks, 0, config.maxTicks)
  config.maxGames = clamp(config.maxGames, 1, 4)
  config.turnTicks = clamp(config.turnTicks, 12, 600)
  config.turnBudgetMs = clamp(config.turnBudgetMs, 1_000, 60_000)
  config.attempt1Ms = clamp(config.attempt1Ms, 1_000, 60_000)
  config.retryMs = clamp(config.retryMs, 1_000, 60_000)
  config.turnSpacingMs = clamp(config.turnSpacingMs, 0, 60_000)
  config.wallClockBudgetSeconds =
    clamp(config.wallClockBudgetSeconds, 10, 720)
  config.maxOutputTokens = clamp(config.maxOutputTokens, 64, 4_096)
  config.lobbyJoinTimeoutTicks = clamp(config.lobbyJoinTimeoutTicks, 0, 20_000)
  config.speed = clamp(config.speed, 1, 16)

  config.applyPreset(node)

proc configuredPlayerName*(config: GameConfig, slot: int, token: string): string =
  ## The roster name for one slot, resolved from the config alone.
  if slot >= 0 and slot < config.players.len:
    let name = config.players[slot].name
    if name.len > 0:
      return name
  if token.len > 0:
    for i, player in config.players:
      if player.token.len > 0 and player.token == token:
        return (if player.name.len > 0: player.name else: "P" & $(i + 1))
  ""

proc playerJoinAllowed*(
  config: GameConfig, address: string, slot: int, token: string
): bool =
  ## The token/slot gate. A wrong token for a configured slot is refused —
  ## the certifier probes with a bad token and a fork that accepts it fails
  ## `smoke-episode` (flatland 0.1.1).
  if slot >= MaxPlayers:
    return false
  if slot >= 0 and slot < config.players.len:
    let expected = config.players[slot].token
    if expected.len > 0 and expected != token:
      return false
    return true
  if slot >= 0 and config.closedRoster:
    return false
  true

proc laneAliasFor*(config: GameConfig, slot: int): string =
  ## The in-game alias of one seat: the config's if it named one, else the
  ## colour for that lane. Never a policy name.
  if slot >= 0 and slot < config.slots.len and config.slots[slot].len > 0:
    return config.slots[slot]
  laneAlias(slot)

proc turnsPerEpisode*(config: GameConfig): int =
  max(1, config.maxTicks div max(1, config.turnTicks))

proc configJson*(config: GameConfig, playerNames: openArray[string]): string =
  ## Everything a replay needs to re-derive the episode. **Every FLAT key
  ## `update` reads is echoed at its RESOLVED value**, so playback rebuilds
  ## the identical cartridge without re-running `applyPreset`'s defaults.
  ## Omitting one is not cosmetic: the certification fixture's
  ## `livesPerLane: 9` lived only inside `preset`, and a replay that dropped
  ## it re-simulated with three lives and mismatched on tick 1.
  ##
  ## The rest: the seed, the fully
  ## resolved cartridge preset, the loaded map's 17 rows verbatim and its
  ## sha256, the whole geometry table, the scoring constants, the REAL player
  ## names (spectator-side) and the in-game aliases.
  var names = newJArray()
  for name in playerNames:
    names.add(%*{"name": name})
  var slots = newJArray()
  for i in 0 ..< max(config.numAgents, config.slots.len):
    slots.add(%*{"alias": config.laneAliasFor(i)})
  var rows = newJArray()
  for row in mapRows(config.rom):
    rows.add(%row)
  var fan = newJArray()
  for entry in BallFan:
    fan.add(%*[entry.vx, entry.vy])
  var mapHashes = newJObject()
  for name in RomNames:
    mapHashes[name] = %mapHash(name)

  let node = %*{
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "maxTicks": config.maxTicks,
    "minTicks": config.minTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "speed": config.speed,
    "rom": config.rom,
    "livesPerLane": config.preset.livesPerLane,
    "parScore": config.preset.parScore,
    "avatarSpeedMilli": config.preset.avatarSpeed,
    "latchTicks": config.preset.latchTicks,
    "powerTicks": config.preset.powerTicks,
    "screenClearBonus": config.preset.screenClearBonus,
    "rampPermille": config.preset.rampPermille,
    "fireEnabled": config.preset.fireEnabled,
    "brakeEnabled": config.preset.brakeEnabled,
    "marchTicks0": config.preset.marchTicks0,
    "fireChancePermille": config.preset.fireChancePermille,
    "ballSpeedMaxMilli": config.preset.ballSpeedMax,
    "preset": presetJson(config.preset),
    "map": rows,
    "mapSha256": mapHash(config.rom),
    "mapHashes": mapHashes,
    "geometry": {
      "grid": [GridW, GridH],
      "tileU": TileU,
      "laneSpanU": LaneSpanU,
      "boxHalf": BoxHalf,
      "ballHalf": BallHalf,
      "boardTiles": BoardTiles,
      "boardTilePx": BoardTilePx,
      "mapWidth": MapWidth,
      "mapHeight": MapHeight,
      "ballFan": fan,
      "chaserSpeeds": [ChaserChaseSpeed, ChaserFleeSpeed, ChaserReturnSpeed],
      "boltSpeeds": [BoltSpeedFriendly, BoltSpeedHostile],
      "saucerSpeed": SaucerSpeed,
      "paddleHalfU": PaddleHalfU,
      "dyingTicks": DyingTicks,
      "respawningTicks": RespawningTicks,
      "scatterHoldTicks": ScatterHoldTicks
    },
    "points": {
      "pellet": PelletPoints,
      "power": PowerPoints,
      "chain": ChainPoints,
      "brickRows": BrickRowPoints,
      "marcherRows": MarcherRowPoints,
      "saucer": SaucerPoints,
      "screenClear": config.preset.screenClearBonus
    },
    "scoring": {
      "pointsMicro": PointsMicro,
      "lifeMicro": LifeMicro,
      "formula": "points / 100 + livesLeft"
    },
    "players": names,
    "slots": slots
  }
  $node
