## Prompt player inference. Hosted players use the model sidecar; local players
## can use ANTHROPIC_API_KEY or ANTHROPIC_API_KEY_URI. The game owns fallback.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, stances

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429. Retrying within the same turn would burn
      ## its deadline; the game moves this seat to scripted fallback.

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

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("BEDROCK_MODEL")
    result.curl = newCurly()
    echo "atari-57 llm: sidecar transport, model ", result.model
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
  client.throttled = false
  var body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["anthropic-version"] = AnthropicVersion
  if client.transport == ltSidecar:
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## throttling fails fast for the current turn.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
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
