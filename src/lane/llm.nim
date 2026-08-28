## Claude-backed lane command. A policy is just a prompt: the game server
## composes the seat's own board view plus that seat's PLAYER_PROMPT and asks
## Claude what STANCE the lane takes for the next 5 seconds.
##
## This is `coworld-ctf`'s `src/ctf/llm.nim` with the identifier rename only.
## Kept exactly, because every line of it is scar tissue from a real hosted
## failure: the credential ladder (Bedrock sidecar -> ANTHROPIC_API_KEY ->
## ANTHROPIC_API_KEY_URI -> none), the SINGLE haiku candidate, the
## `throttled` fast-fail, the fence-tolerant JSON extraction and the
## rune-boundary truncation.
##
## The cabinet is a SIMULTANEOUS-decision game — four lanes step on the same
## tick — so all four seats' calls go out as ONE parallel batch per turn
## (`curly.makeRequests`). Seats are never queried sequentially: that is what
## keeps 24 turns inside the wall-clock budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, stances

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again (paintball round 2, 2026-08-25).

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "atari-57 llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call.
  ##
  ## `us.anthropic.claude-sonnet-4-6` was never a candidate (cogame-raid round
  ## 2, 2026-08-23) and `us.anthropic.claude-sonnet-4-5-20250929-v1:0` is not
  ## one either: it was the ladder fallback for paintball 0.1.2 and the hosted
  ## round-2 game log recorded 133 calls to it, every single one returning
  ## "Timeout was reached" and none returning text. One haiku throttle then
  ## cascaded into a whole episode of scripted fallbacks — the retry is what
  ## burned the turn, not the throttle. With no second candidate a throttle
  ## fails fast (see LlmClient.throttled) and the seat plays the scripted
  ## fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "atari-57 llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "atari-57 llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "atari-57 llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" below: "LLM provider is unavailable".
    echo "atari-57 llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are ONE cog at ONE cabinet in a four-cabinet arcade. All four cabinets are
running the SAME game from the SAME seed at the SAME moment, each on its own
private 17x17 screen. You cannot see, touch, help or hurt any other cabinet, and
nothing you do can change their screens. This is a SCORE ATTACK: the highest
score on the board when the credit runs out wins.
Your screen is 17 columns by 17 rows. (col 0, row 0) is the TOP-LEFT of YOUR
screen. col grows RIGHT, row grows DOWN.
You have 3 lives. Losing your last life ends YOUR game; your points freeze and
the other three play on. Points are never taken away.
SCORE = points / 100 + lives you still have. So one unspent life is worth 100
points, and dying to grab a 50-point pellet is a bad trade.
Three cartridges exist; "rom" in your view tells you which one is loaded.
 CHOMPER  - a maze. Eat all 120 pellets (10 each). Four HUNTERS chase you and
            cost a life on contact. The 4 power pellets (50) make hunters FLEE
            for 6 seconds; eating fleeing hunters pays 100, 150, 200, 250 in a
            chain. Clearing the maze pays 500. There is a wrap TUNNEL across
            row 8.
 BRICKFALL- a paddle on the bottom row and one ball. Bricks pay 50/30/20/10 by
            row, top row worth most. The ball leaves your paddle at an angle set
            by WHERE ON THE PADDLE it hit - the ends send it steeply sideways,
            the middle sends it straight up. Let the ball past you and you lose
            a life. Clearing the wall pays 350. Every 8 bricks the ball speeds
            up.
 GALLERY  - a formation of 32 marchers steps down toward you. Shoot them (30/20/
            10/10 by row, top row worth most); the saucer that crosses the top
            pays 100. Their bolts and any marcher reaching row 13 cost a life.
            Three bunkers absorb 3 hits each. Clearing the wave pays 300 and the
            next wave starts lower.
YOU CAN SEE YOUR WHOLE SCREEN: every tile, every sprite, your lives, your points.
Nothing on your own screen is hidden. You can also see the SCOREBOARD - the other
three cabinets' scores, lives and screen numbers - and nothing else about them.
You CANNOT talk to anyone and nobody sees anything you write.
Every 5 seconds you set your STANCE for the next 5 seconds. A deterministic
autopilot runs it 24 times a second: it does the pathfinding, the dodging, the
aiming and the firing. You choose WHAT to go for and HOW MUCH RISK to take.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, your reasoning",
 "mode":"clear"|"hunt"|"strike"|"safe"|"bank",
   // clear  : take the nearest scoring thing, over and over. The default.
   // hunt   : go for the HIGHEST-VALUE thing reachable (a power pellet, the top
   //          brick row, the top marcher row, the saucer) even if it is far.
   // strike : cash in. In CHOMPER chase fleeing hunters for the chain; in
   //          BRICKFALL aim returns off the paddle ends at the top rows; in
   //          GALLERY push to the flank with the most marchers and fire flat
   //          out.
   // safe   : keep the largest distance from every threat that still scores.
   // bank   : refuse every trade. Never enter a tile a threat can reach before
   //          you leave it. You will score slowly and you will not die.
 "zone":"nw"|"ne"|"sw"|"se"|"centre"|"left"|"right"|"top"|"bottom"|"none",
                            // work in this part of YOUR screen; "none" = anywhere
 "risk":0.0..1.0,           // 0 = never let a threat within 4 tiles,
                            // 1 = ignore threats entirely
 "lead_ticks":0..48,        // how long the autopilot commits to a chosen route
                            // before re-deciding (24 ticks = 1 second)
 "fire":"auto"|"hold"|"never",   // GALLERY only; ignored by the other roms
 "say":"<=48 chars"}        // spectators only; no cabinet ever sees it
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## own board view (see observation.nim). The prompt text is NEVER echoed
  ## into the replay — only `policyKind`, the label and the resulting stance.
  operatorBlock(operatorPrompt) & viewJson
