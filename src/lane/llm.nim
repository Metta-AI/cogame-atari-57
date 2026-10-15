## The ordinary prompt player calls the native Coworld sidecar only.
## The game owns fallback when no endpoint or usable completion exists.

import std/[json, os, strutils, unicode], curly, sim_types, stances

const AnthropicVersion = "2023-06-01"

type
  LlmClient* = ref object
    curl*: Curly
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
  LlmError* = object of ValueError

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    maxOutputTokens: max(1, config.maxOutputTokens))
  result.sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip().strip(
    chars = {'/'}, leading = false)
  result.disabled = result.sidecarEndpoint.len == 0
  if not result.disabled: result.curl = newCurly()

proc requestFor*(client: LlmClient, system, user: string,
    slot: int): tuple[url: string, headers: HttpHeaders, body: string] =
  if slot < 0 or slot >= MaxPlayers:
    raise newException(LlmError, "native inference requires the issued player slot")
  if client.disabled:
    raise newException(LlmError, "native inference endpoint is not configured")
  client.throttled = false
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = AnthropicVersion
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.body = $(%*{"model": client.model,
    "max_tokens": client.maxOutputTokens, "system": system,
    "messages": [{"role": "user", "content": user}]})

proc textOf*(client: LlmClient, response: Response, error: string): string =
  ## Public fallback exposes stable causes, never private received bytes or URLs.
  if error.len > 0:
    raise newException(LlmError, "native inference transport failed")
  if response.code == 401 or response.code == 403:
    client.disabled = true
    raise newException(LlmError, "native inference auth failed (" & $response.code & ")")
  if response.code == 429:
    client.throttled = true
    raise newException(LlmError, "native inference throttled (429)")
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "native inference error " & $response.code)
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "native reply ended before a JSON action")

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
