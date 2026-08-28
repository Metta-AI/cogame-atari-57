## Everything about `coworld_manifest_template.json` that the platform's
## validator, the certifier or the ladder would otherwise reject — checked
## here, where the failure costs a CI minute instead of a release dispatch.

import std/[algorithm, json, strformat, strutils, tables]
import lane_helpers
import lane/[sim_types, roster]

let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))

proc testSeatCounts() =
  ## `num_agents` == 4 in every variant AND in the certification fixture, and
  ## ABSENT at every variant's top level: `CoworldVariant` is
  ## additionalProperties:false and rejects it there
  ## (goofspiel-oshi-zumo 0.1.0, 2026-08-26).
  let variants = manifest{"variants"}
  check(variants.len == 3, &"{variants.len} variants, not 3")
  for variant in variants:
    let id = variant{"id"}.getStr()
    check(not variant.hasKey("num_agents"),
          &"variant {id} carries num_agents at its TOP LEVEL")
    let cfg = variant{"game_config"}
    check(cfg{"num_agents"}.getInt() == 4,
          &"variant {id}: num_agents is not 4")
    check(cfg{"players"}.len == 4, &"variant {id}: not four players")
    check(cfg{"slots"}.len == 4, &"variant {id}: not four slots")
  let cert = manifest{"certification"}
  check(cert{"players"}.len == 4, "certification.players is not four seats")
  check(cert{"game_config"}{"num_agents"}.getInt() == 4,
        "certification.game_config.num_agents is not 4")
  check(cert{"game_config"}{"players"}.len == 4,
        "certification.game_config.players is not four seats")
  report("num_agents == 4 in all three variants and the cert fixture")

proc testNoLiteralTokens() =
  ## A literal `tokens` in any game_config is rejected by matriculate: the
  ## runner injects them (knights-archers 0.1.0).
  for variant in manifest{"variants"}:
    let id = variant{"id"}.getStr()
    check(not variant{"game_config"}.hasKey("tokens"),
          &"variant {id} carries a literal tokens")
  check(not manifest{"certification"}{"game_config"}.hasKey("tokens"),
        "the cert fixture carries a literal tokens")
  report("no game_config carries a literal tokens")

proc testDeclaredPlayersAreSeated() =
  ## EVERY declared player entry must occupy at least one certification slot,
  ## or cert fails `players_missing` (raid 0.1.2), and `limits.cpu` below "1"
  ## is a 400 at upload (pistonball 0.1.1).
  var seated: seq[string]
  for entry in manifest{"certification"}{"players"}:
    seated.add(entry{"player_id"}.getStr())
  for player in manifest{"player"}:
    let id = player{"id"}.getStr()
    check(id in seated, &"declared player {id} occupies no certification slot")
    check(player{"resources"}{"limits"}{"cpu"}.getStr() == "1",
          &"player {id}: limits.cpu is not \"1\"")
    check(player{"type"}.getStr() == "player", &"player {id}: wrong type")
    check(player{"name"}.getStr().len > 0, &"player {id}: no name")
    check(player{"description"}.getStr().len > 0, &"player {id}: no description")
    check(player{"run"}[0].getStr() == "/bin/atari-57-player",
          &"player {id}: the wrong entrypoint")
  report("every declared player is seated; limits.cpu is \"1\"")

proc testResultsSchemaMatchesTheDocument() =
  ## `results_schema` must equal `playerResultsJson` KEY FOR KEY: the schema is
  ## additionalProperties:false and the certifier rejects an unknown field, so
  ## adding a key to one without the other breaks certification.
  let schema = manifest{"game"}{"results_schema"}
  check(schema{"additionalProperties"}.getBool() == false,
        "results_schema is not additionalProperties:false")
  var schemaKeys: seq[string]
  for key, _ in schema{"properties"}:
    schemaKeys.add(key)
  var docKeys = resultsKeys()
  var a = schemaKeys
  var b = docKeys
  a.sort()
  b.sort()
  check(a == b, &"results_schema keys {a} != playerResultsJson keys {b}")
  const seatArrays = [
    "names", "aliases", "lanes", "policyKinds", "scores", "win", "placements",
    "points", "livesLeft", "deaths", "screensCleared", "bestChain",
    "shotsFired", "records", "lastScoreTick", "ticksAlive", "llmTurns",
    "fallbackTurns"]
  for key in seatArrays:
    let prop = schema{"properties"}{key}
    check(prop{"type"}.getStr() == "array", &"{key} is not an array")
    check(prop{"minItems"}.getInt() == 4 and prop{"maxItems"}.getInt() == 4,
          &"{key} is not bounded minItems: 4, maxItems: 4")
  for (key, values) in [("reason", @["complete", "deadline", "fault"]),
                        ("endRule", @["all_lanes_over", "full_time",
                                      "wall_clock", "sim_fault", "host_error"]),
                        ("rom", @["chomper", "brickfall", "gallery"])]:
    var got: seq[string]
    for item in schema{"properties"}{key}{"enum"}:
      got.add(item.getStr())
    check(got == values, &"{key} enum is {got}, not {values}")
  for key in ["names", "scores", "win", "placements", "rom", "points",
              "reason", "endRule"]:
    var required = false
    for item in schema{"required"}:
      if item.getStr() == key:
        required = true
    check(required, &"{key} is not required by results_schema")
  report("results_schema == playerResultsJson, 24 keys, arrays bounded 4..4")

proc testResultsDocumentValidates() =
  ## The document a real episode writes really does satisfy the schema.
  let config = testConfig(RomChomper, 5_140_913)
  var game = seatedSim(config)
  for _ in 0 ..< 240:
    game.step(newSeq[uint8](4))
  game.finishGame(ReasonComplete, EndRuleFullTime)
  let doc = parseJson(game.playerResultsJson())
  let props = manifest{"game"}{"results_schema"}{"properties"}
  for key, value in doc:
    check(props.hasKey(key), &"results.json carries {key}, which the schema forbids")
    if props{key}{"type"}.getStr() == "array":
      check(value.len == 4, &"results.{key} has {value.len} entries, not 4")
  for key in resultsKeys():
    check(doc.hasKey(key), &"results.json is missing {key}")
  report("a real results document validates against results_schema")

proc testConfigSchema() =
  ## Every ARRAY property carries minItems/maxItems — not just membership in
  ## `required` (tandem 0.1.0) — and every field `sim_config.update` reads is
  ## settable.
  let schema = manifest{"game"}{"config_schema"}
  check(schema{"additionalProperties"}.getBool() == false,
        "config_schema is not additionalProperties:false")
  var required: seq[string]
  for item in schema{"required"}:
    required.add(item.getStr())
  check("tokens" in required and "players" in required,
        "config_schema does not require tokens and players")
  for key, prop in schema{"properties"}:
    if prop{"type"}.getStr() == "array":
      check(prop.hasKey("minItems") and prop.hasKey("maxItems"),
            &"config_schema.{key} is an array with no minItems/maxItems")
  # Every key `update` actually reads must be declared, or it is not settable.
  let source = readRepoFile("src/lane/sim_config.nim")
  var missing: seq[string]
  for line in source.splitLines():
    let trimmed = line.strip()
    for prefix in ["node.readInt(\"", "node.readBool(\"", "node.readStr(\""]:
      if trimmed.startsWith(prefix):
        let rest = trimmed[prefix.len .. ^1]
        let key = rest[0 ..< rest.find('"')]
        if key == "numAgents":
          continue           ## the camelCase alias of num_agents
        if not schema{"properties"}.hasKey(key):
          missing.add(key)
  check(missing.len == 0,
        &"config_schema does not cover keys sim_config.update reads: {missing}")
  check(schema{"properties"}{"rom"}{"enum"}.len == 3,
        "the rom enum is not the three cartridges")
  report("config_schema: every array bounded, every settable key declared")

proc testGameBlock() =
  let game = manifest{"game"}
  check(game{"name"}.getStr() == "atari-57", "game.name is not atari-57")
  check(game{"description"}.getStr().len > 40,
        "game.description is missing or trivial")
  check(not game.hasKey("tags"), "game.tags exists — tags live top-level only")
  check(manifest{"tags"}.len >= 3, "fewer than three top-level tags")
  check(game{"owner"}.getStr().len > 0, "game.owner is missing")
  check(not manifest.hasKey("version"), "a top-level version exists")
  check(not game.hasKey("display_name"), "game.display_name exists")
  check(game{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer",
        "the replay viewer is not the static bundle")
  check(game{"runnable"}{"type"}.getStr() == "game", "runnable.type is not game")
  check(game{"runnable"}{"run"}[0].getStr() == "/bin/atari-57",
        "the game entrypoint is wrong")
  check(game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
          "secret://coworld/atari-57/anthropic_api_key",
        "the hosted game pod would never receive the secret")
  for key in ["player", "global"]:
    let proto = game{"protocols"}{key}
    check(proto.kind == JObject, &"protocols.{key} is not an object")
    check(proto{"type"}.getStr() == "text", &"protocols.{key}.type is not text")
    check(proto{"value"}.getStr().len > 200, &"protocols.{key} is trivial")
  check(game{"docs"}{"readme"}{"type"}.getStr() == "text",
        "docs.readme is not a text object")
  check(game{"docs"}{"readme"}{"value"}.getStr().len > 400,
        "docs.readme is trivial")
  check(game{"docs"}{"pages"}.len == 3, "docs.pages is not three pages")
  for page in game{"docs"}{"pages"}:
    check(page{"id"}.getStr().len > 0, "a docs page has no id")
    check(page{"title"}.getStr().len > 0, "a docs page has no title")
    check(page{"content"}{"type"}.getStr() == "text",
          "a docs page's content is not a text object")
    let pageId = page{"id"}.getStr()
    check(page{"content"}{"value"}.getStr().len > 400,
          &"docs page {pageId} is trivial")
  report("game block: description, tags, owner, protocols, docs, bundle")

proc testSecretNamespaceEqualsGameName() =
  ## The `secret://coworld/<ns>/…` namespace must equal `game.name` EXACTLY
  ## (cooperative-hunting, 2026-08-25), or upload 400s after a green certify.
  let uri = manifest{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr()
  let parts = uri.split('/')
  check(parts.len == 5, &"the secret URI has an unexpected shape: {uri}")
  check(parts[3] == manifest{"game"}{"name"}.getStr(),
        &"the secret namespace {parts[3]} is not game.name")
  report("the secret namespace equals game.name")

proc testImagePlaceholderMatchesCompose() =
  ## Placeholders are DERIVED from compose SERVICE names by uppercasing and
  ## replacing `-` with `_` — `{{GAME_IMAGE}}` is not a thing (lantern 0.1.0).
  let compose = readRepoFile("compose.yaml")
  var service = ""
  var image = ""
  var inServices = false
  for line in compose.splitLines():
    if line.startsWith("services:"):
      inServices = true
      continue
    if line.len == 0 or line.startsWith("#"):
      continue
    let trimmed = line.strip()
    # A service name is the ONLY key at exactly two spaces of indent under
    # `services:`; `build:` and friends sit deeper.
    if inServices and line.startsWith("  ") and not line.startsWith("   ") and
        trimmed.endsWith(":") and service.len == 0:
      service = trimmed[0 ..< trimmed.high]
    elif trimmed.startsWith("image:"):
      image = trimmed[6 .. ^1].strip()
  check(service == "atari-57", &"the compose service is {service}")
  check(image == "coworld-atari-57:latest", &"the compose image is {image}")
  let want = "{{" & service.toUpperAscii().replace("-", "_") & "_IMAGE}}"
  check(manifest{"game"}{"runnable"}{"image"}.getStr() == want,
        &"the game image placeholder is not {want}")
  for player in manifest{"player"}:
    check(player{"image"}.getStr() == want,
          &"a player image placeholder is not {want}")
  report(&"the image placeholder {want} is derived from the compose service")

proc testVariantsShareTheClock() =
  ## A variant changes only the ROM preset — never the seat count, the clock,
  ## the decision cadence or the wall-clock budget. That is what makes ONE
  ## budget arithmetic and ONE score scale correct for all three.
  const shared = ["maxTicks", "minTicks", "turnTicks", "turnSpacingMs",
                  "turnBudgetMs", "wallClockBudgetSeconds", "attempt1Ms",
                  "retryMs", "lobbyJoinTimeoutTicks", "maxGames", "minPlayers"]
  var first = initTable[string, int]()
  for variant in manifest{"variants"}:
    let cfg = variant{"game_config"}
    let id = variant{"id"}.getStr()
    check(variant{"description"}.getStr().len > 20,
          &"variant {id} has no real description")
    check(variant{"name"}.getStr().len > 0, "a variant has no name")
    for key in shared:
      let value = cfg{key}.getInt()
      if first.hasKey(key):
        check(first[key] == value, &"variant {id} changed {key}")
      else:
        first[key] = value
    check(cfg{"rom"}.getStr() == variant{"id"}.getStr(),
          "a variant's id and rom disagree")
  check(first["wallClockBudgetSeconds"] <= 720,
        "wallClockBudgetSeconds exceeds 60% of the 1200 s episode timeout")
  check(first["attempt1Ms"] + first["retryMs"] <= first["turnBudgetMs"],
        "attempt1Ms + retryMs does not fit inside turnBudgetMs")
  check(first["maxTicks"] mod first["turnTicks"] == 0,
        "maxTicks is not a whole number of turns")
  check(first["minTicks"] <= first["maxTicks"], "minTicks exceeds maxTicks")
  check(manifest{"episode_timeout_minutes"}.getInt() == 20,
        "episode_timeout_minutes is not 20")
  report("all three variants share the clock, the cadence and the budget")

proc testCertFixtureShape() =
  let cfg = manifest{"certification"}{"game_config"}
  check(cfg{"livesPerLane"}.getInt() == 9,
        "the cert fixture does not override livesPerLane to 9")
  check(cfg{"minTicks"}.getInt() == cfg{"maxTicks"}.getInt(),
        "minTicks != maxTicks: the cert replay is not a guaranteed 60 s")
  check(cfg{"maxTicks"}.getInt() == 1440, "the cert fixture is not 1440 ticks")
  check(cfg{"turnSpacingMs"}.getInt() == 0,
        "the cert fixture pays the inter-batch floor")
  check(cfg{"wallClockBudgetSeconds"}.getInt() == 180,
        "the cert fixture's wall-clock budget moved")
  check(cfg{"seed"}.getInt() == 5_140_913, "the cert fixture's seed moved")
  report("cert fixture: 9 lives, minTicks == maxTicks == 1440, spacing 0")

when isMainModule:
  echo "test_manifest"
  testSeatCounts()
  testNoLiteralTokens()
  testDeclaredPlayersAreSeated()
  testResultsSchemaMatchesTheDocument()
  testResultsDocumentValidates()
  testConfigSchema()
  testGameBlock()
  testSecretNamespaceEqualsGameName()
  testImagePlaceholderMatchesCompose()
  testVariantsShareTheClock()
  testCertFixtureShape()
  echo "test_manifest OK"
