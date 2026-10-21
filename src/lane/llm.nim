## The ordinary prompt player calls the native Coworld sidecar only.
## The game owns fallback when no endpoint or usable completion exists.

import std/[json, os, strutils], curly, sim_types, stances

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
