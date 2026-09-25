## Jev chooses a stance from the same private board view as prompt players.

import std/[json, os, strutils]
import curly

let Modes = %*{
  "clear": "Collect the nearest scoring target.",
  "hunt": "Pursue the highest-value reachable target.",
  "strike": "Cash in a scoring opportunity aggressively.",
  "safe": "Avoid near threats while continuing to score.",
  "bank": "Preserve lives, accepting slower scoring."
}

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc chooseJevAction*(view: JsonNode, seat, timeoutSeconds: int): JsonNode =
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: getEnv("BEDROCK_MODEL")
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $seat
  let body = %*{
    "model": model,
    "state": "Choose one Atari 57 stance from this seat's private view. " &
      "Other cabinets are isolated. Maximize your final score.\n" & $view,
    "questions": {"mode": {
      "type": "choice",
      "instructions": "Choose the goal for the next five seconds.",
      "criteria": Modes
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answer = parseJson(response.body)["answers"]["mode"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != Modes.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned an invalid stance choice")
  var best = -1.0
  var total = 0.0
  var mode = ""
  for choice, probability in probabilities.pairs:
    if not Modes.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown stance")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      mode = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  var zone = "none"
  var targetValue = -1
  for target in view["targets"]:
    if target["safe"].getBool() and target["value"].getInt() > targetValue:
      targetValue = target["value"].getInt()
      zone = target["zone"].getStr()
  %*{
    "note": "Jev stance choice", "mode": mode, "zone": zone,
    "risk": (if mode in ["bank", "safe"]: 0.2 else: 0.55),
    "lead_ticks": 12, "fire": "auto", "say": ""
  }
