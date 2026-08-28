## The stance schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal reply is REPAIRED rather than
## rejected.
##
## This is `coworld-ctf`'s `src/ctf/directives.nim`, same file shape and same
## discipline, retargeted from a squad directive to one lane stance:
## `truncateRunes` / `sanitizeSay` / `sanitizeNote` / `extractJsonObject` are
## carried over behaviour for behaviour, because every one of them is scar
## tissue from a real hosted failure.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser, which is exactly the class of bug
## that makes a replay unreadable to everything except the one lenient viewer.

import std/[json, strutils, unicode]
import sim_types

type
  Mode* = enum
    ## What the seat is going for. A closed enum: an unrecognised mode keeps
    ## LAST turn's value (else `clear`), never nothing.
    mdClear = "clear"
    mdHunt = "hunt"
    mdStrike = "strike"
    mdSafe = "safe"
    mdBank = "bank"

  Zone* = enum
    znNone = "none"
    znNw = "nw"
    znNe = "ne"
    znSw = "sw"
    znSe = "se"
    znCentre = "centre"
    znLeft = "left"
    znRight = "right"
    znTop = "top"
    znBottom = "bottom"

  FireMode* = enum
    fmAuto = "auto"
    fmHold = "hold"
    fmNever = "never"

  StanceSource* = enum
    stLlm = "llm"
    stScripted = "scripted"
    stFallback = "fallback"

  LaneStance* = object
    ## One seat's whole decision for one 120-tick turn.
    note*: string              ## <= MaxNoteRunes.
    mode*: Mode
    zone*: Zone
    riskMilli*: int32          ## risk quantised to 0..1000.
    leadTicks*: int32          ## 0..48.
    fire*: FireMode
    say*: string               ## <= MaxSayRunes, sanitized.
    source*: StanceSource
    latencyMs*: int

  StanceError* = object of ValueError

const
  DefaultStance* = LaneStance(
    note: "",
    mode: mdClear,
    zone: znNone,
    riskMilli: 500,
    leadTicks: 14,
    fire: fmAuto,
    say: "",
    source: stScripted
  )

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A seat's spectator line: capped at MaxSayRunes on a rune boundary FIRST,
  ## then run through the starter's printable-ASCII shout filter. In that
  ## order, so the rune cut never leaves half a codepoint for the filter to
  ## smear. Braces are excluded deliberately — the replay chat stream tells a
  ## CONTROL record from a spoken line by a leading '{'.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The policy's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseMode*(text: string, fallback: Mode): tuple[ok: bool, mode: Mode] =
  ## Case-insensitive, whitespace-tolerant, with the design note's synonym
  ## table. Anything still unknown reports `ok = false` so the caller can keep
  ## last turn's value rather than inventing one.
  let key = text.strip().toLowerAscii().truncateRunes(MaxModeRunes)
  for mode in Mode:
    if $mode == key:
      return (true, mode)
  case key
  of "greedy", "collect", "gather", "farm": (true, mdClear)
  of "attack", "cash", "cash_in": (true, mdStrike)
  of "chase", "seek": (true, mdHunt)
  of "defend", "dodge", "evade": (true, mdSafe)
  of "survive", "turtle", "hold": (true, mdBank)
  else: (false, fallback)

proc parseZone*(text: string): Zone =
  ## The nine zones plus `none`, accepting the shapes models really emit:
  ## `"north-west"`, `"top left"`, `"upper left"`, `"middle"`, `"anywhere"`.
  let key = text.strip().toLowerAscii().replace("-", " ").replace("_", " ")
  for zone in Zone:
    if $zone == key:
      return zone
  case key
  of "north west", "top left", "upper left", "northwest", "topleft": znNw
  of "north east", "top right", "upper right", "northeast", "topright": znNe
  of "south west", "bottom left", "lower left", "southwest": znSw
  of "south east", "bottom right", "lower right", "southeast": znSe
  of "middle", "center", "central": znCentre
  of "west": znLeft
  of "east": znRight
  of "north", "up": znTop
  of "south", "down": znBottom
  of "anywhere", "any", "": znNone
  else: znNone

proc parseFire*(text: string): FireMode =
  let key = text.strip().toLowerAscii().truncateRunes(MaxFireRunes)
  for mode in FireMode:
    if $mode == key:
      return mode
  case key
  of "always", "on", "free", "yes": fmAuto
  of "off", "no", "cease": fmNever
  of "aimed", "when", "wait": fmHold
  else: fmAuto

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      StanceError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## One numeric field: an int, a float, or a numeric string. Non-finite
  ## values report `ok = false` so the caller applies its own repair.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt: (true, float(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0.0)
    else: (true, f)
  of JString:
    var raw = node.getStr().strip()
    if raw.endsWith("%"):
      raw = raw[0 ..< raw.high]
    try: (true, parseFloat(raw.strip()))
    except CatchableError: (false, 0.0)
  else: (false, 0.0)

proc parseLaneStance*(
  payload: JsonNode,
  previous: LaneStance,
  havePrevious: bool
): LaneStance =
  ## Turns one parsed reply into a legal stance, REPAIRING every field the
  ## schema bounds rather than rejecting the reply. Raises `StanceError` only
  ## when NO usable field can be recovered — that is the one condition the
  ## retry and then the scripted fallback exist for.
  result = (if havePrevious: previous else: DefaultStance)
  result.source = stLlm
  result.latencyMs = 0
  result.note = ""
  result.say = ""
  var usable = 0

  if not payload.isNil and payload.kind == JObject:
    if payload.hasKey("note") and payload["note"].kind == JString:
      result.note = sanitizeNote(payload["note"].getStr())
      inc usable
    if payload.hasKey("mode") and payload["mode"].kind == JString:
      let parsed = parseMode(
        payload["mode"].getStr(),
        (if havePrevious: previous.mode else: mdClear))
      result.mode = parsed.mode
      if parsed.ok:
        inc usable
    if payload.hasKey("zone") and payload["zone"].kind == JString:
      result.zone = parseZone(payload["zone"].getStr())
      inc usable
    if payload.hasKey("risk"):
      let risk = readNumber(payload["risk"])
      if risk.ok:
        var value = risk.value
        ## An integer percentage is a shape models really emit; anything
        ## above 1 is read as a percentage and divided by 100.
        if value > 1.0:
          value = value / 100.0
        result.riskMilli = int32(clamp(int(value * 1000.0 + 0.5), 0, 1000))
        inc usable
    if payload.hasKey("lead_ticks") or payload.hasKey("leadTicks"):
      let node =
        if payload.hasKey("lead_ticks"): payload["lead_ticks"]
        else: payload["leadTicks"]
      let lead = readNumber(node)
      if lead.ok:
        result.leadTicks = int32(clamp(int(lead.value + 0.5), 0, 48))
        inc usable
      else:
        result.leadTicks = 14
    if payload.hasKey("fire") and payload["fire"].kind == JString:
      result.fire = parseFire(payload["fire"].getStr())
      inc usable
    if payload.hasKey("say") and payload["say"].kind == JString:
      result.say = sanitizeSay(payload["say"].getStr())
      inc usable

  if usable == 0:
    raise newException(StanceError, "reply carried no usable stance field")

proc risk*(stance: LaneStance): float {.inline.} =
  ## The quantised risk as a fraction. Lives OUTSIDE the determinism boundary
  ## (the autopilot may use floats; the sim may not).
  float(stance.riskMilli) / 1000.0

proc stanceRecord*(
  stance: LaneStance, turn, seat, lane: int, alias: string
): JsonNode =
  ## The replay chat record for one turn's stance. Re-applied at playback
  ## into NON-HASHED fields only, so it can never affect the simulation.
  %*{
    "k": "stance",
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "lane": lane,
    "source": $stance.source,
    "latency_ms": stance.latencyMs,
    "note": stance.note,
    "mode": $stance.mode,
    "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0,
    "lead_ticks": stance.leadTicks,
    "fire": $stance.fire,
    "say": stance.say
  }

proc boundedStanceRecord*(
  stance: LaneStance, turn, seat, lane: int, alias: string
): string =
  ## The serialized stance record, guaranteed <= MaxStanceRunes. The note is
  ## the only unbounded-in-practice field, so it is the one that shrinks; the
  ## cut still lands on a rune boundary. NEVER cut the serialized string —
  ## that would emit broken JSON, the exact failure the rune rule prevents.
  var trimmed = stance
  result = $stanceRecord(trimmed, turn, seat, lane, alias)
  var guard = 0
  while result.runeLen > MaxStanceRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $stanceRecord(trimmed, turn, seat, lane, alias)

proc registerRecord*(
  seat, lane: int, alias, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "lane": lane,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stoppedRecord*(tick: int): string =
  $(%*{"k": "stopped", "tick": tick, "reason": EndRuleWallClock})
