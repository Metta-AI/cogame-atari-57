## Hosted calls must reach the native sidecar without provider credentials.
include "../src/lane/llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-be-used")
  let client = newLlmClient(GameConfig())
  for slot in 0 .. 3:
    let request = client.requestFor("rules", "private view", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
    doAssert not body.hasKey("output_config")
  echo "hosted sidecar routing and seat attribution passed"

block:
  delEnv("COWORLD_LLM_ENDPOINT")
  putEnv("ANTHROPIC_API_KEY", "retired-provider-key")
  putEnv("ANTHROPIC_API_KEY_URI", "http://retired.invalid/key")
  doAssert newLlmClient(GameConfig()).disabled,
    "a retired provider credential bypassed the sidecar"
  echo "no endpoint uses game-owned fallback despite retired credentials"
