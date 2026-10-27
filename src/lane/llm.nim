## The ordinary prompt player calls the native Coworld sidecar only.
## The game owns fallback when no endpoint or usable completion exists.

import
  std/[json, options, os, strutils, tables],
  bitworld/decision_trajectory,
  curly,
  sim_types

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

proc responseEvidence*(attempt: var DecisionAttempt, headers: HttpHeaders, body: string) =
  ## Preserve native metadata before the existing domain completion parser runs.
  attempt.rawResponse = %body
  var receivedHeaders = initTable[string, string]()
  for (key, value) in headers:
    receivedHeaders[key] = value
  attempt.responseHeaders = some(receivedHeaders)
  for key in ["request-id", "x-request-id"]:
    if headers.contains(key):
      attempt.providerRequestId = some(headers[key])
      break
  if headers.contains("X-Softmax-Llm-Call-Id"):
    attempt.platformCallId = some(headers["X-Softmax-Llm-Call-Id"])
  for header in ["X-Coworld-Checkpoint-Sha256", "X-Coworld-Tokenizer-Sha256",
      "X-Coworld-Chat-Template-Sha256"]:
    if headers.contains(header):
      case header
      of "X-Coworld-Checkpoint-Sha256": attempt.modelIdentity = some(headers[header])
      of "X-Coworld-Tokenizer-Sha256": attempt.tokenizerIdentity = some(headers[header])
      else: attempt.chatTemplateSha256 = some(headers[header])

proc completionEvidence*(attempt: var DecisionAttempt, payload: JsonNode) =
  attempt.model = some(payload["model"].getStr())
  attempt.stopReason = some(payload["stop_reason"].getStr())
  if payload.hasKey("usage"):
    attempt.inputTokens = some(payload["usage"]["input_tokens"].getInt())
    attempt.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]: promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]: sampledIds.add(token.getInt())
    attempt.promptTokenIds = some(promptIds)
    attempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      for probability in sampling["behavior_log_probs"]: probabilities.add(probability.getFloat())
      attempt.behaviorLogprobs = some(probabilities)
    attempt.stopReason = some(sampling["stop_reason"].getStr())
