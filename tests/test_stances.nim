## Tolerant parsing and repair: every field the schema bounds is REPAIRED, not
## rejected, and every truncation lands on a RUNE boundary.

import std/[json, strformat, strutils, unicode]
import lane_helpers
import lane/[sim_types, stances]

proc parsed(text: string, previous = DefaultStance, have = false): LaneStance =
  parseLaneStance(extractJsonObject(text), previous, have)

proc testProsePrefixed() =
  let stance = parsed(
    "Sure! Here is my plan for the next five seconds.\n\n" &
    "```json\n{\"mode\": \"hunt\", \"zone\": \"sw\", \"risk\": 0.55}\n```\n" &
    "Let me know if you want a different one.")
  check(stance.mode == mdHunt, "a fenced, prose-wrapped reply did not parse")
  check(stance.zone == znSw, "the zone was lost")
  check(stance.riskMilli == 550, &"risk parsed as {stance.riskMilli}")
  report("prose-prefixed and fenced JSON parse")

proc testPercentageRisk() =
  check(parsed("""{"mode":"clear","risk":55}""").riskMilli == 550,
        "an integer percentage risk was not divided by 100")
  check(parsed("""{"mode":"clear","risk":"0.25"}""").riskMilli == 250,
        "a numeric string risk did not parse")
  check(parsed("""{"mode":"clear","risk":"85%"}""").riskMilli == 850,
        "a percent-suffixed risk did not parse")
  check(parsed("""{"mode":"clear","risk":9.9}""").riskMilli == 99,
        "a value above 1 was not read as a percentage")
  check(parsed("""{"mode":"clear","risk":140}""").riskMilli == 1000,
        "a percentage above 100 was not clamped to 1.0")
  check(parsed("""{"mode":"clear","risk":-3}""").riskMilli == 0,
        "a negative risk was not clamped to 0")
  report("risk: fractions, strings, percentages and out-of-range values")

proc testModeSynonyms() =
  for (text, want) in [("greedy", mdClear), ("collect", mdClear),
                       ("attack", mdStrike), ("chase", mdHunt),
                       ("defend", mdSafe), ("dodge", mdSafe),
                       ("survive", mdBank), ("turtle", mdBank),
                       ("  STRIKE  ", mdStrike), ("Bank", mdBank)]:
    let stance = parsed(&"""{{"mode":"{text}"}}""")
    check(stance.mode == want, &"mode `{text}` parsed as {stance.mode}")
  report("mode synonyms, case and whitespace")

proc testZoneSynonyms() =
  for (text, want) in [("north-west", znNw), ("top left", znNw),
                       ("upper left", znNw), ("north east", znNe),
                       ("bottom right", znSe), ("lower left", znSw),
                       ("middle", znCentre), ("anywhere", znNone),
                       ("", znNone), ("nowhere-at-all", znNone)]:
    let stance = parsed(&"""{{"mode":"clear","zone":"{text}"}}""")
    check(stance.zone == want, &"zone `{text}` parsed as {stance.zone}")
  report("zone synonyms and the unknown-zone repair")

proc testFireSynonyms() =
  for (text, want) in [("always", fmAuto), ("off", fmNever), ("on", fmAuto),
                       ("hold", fmHold), ("nonsense", fmAuto)]:
    let stance = parsed(&"""{{"mode":"clear","fire":"{text}"}}""")
    check(stance.fire == want, &"fire `{text}` parsed as {stance.fire}")
  report("fire synonyms and the unknown-fire repair")

proc testUnknownModeKeepsLastTurn() =
  var previous = DefaultStance
  previous.mode = mdStrike
  previous.riskMilli = 900
  let stance = parsed("""{"mode":"teleport","zone":"ne"}""", previous, true)
  check(stance.mode == mdStrike,
        "an unrecognised mode did not keep last turn's value")
  let fresh = parsed("""{"mode":"teleport","zone":"ne"}""")
  check(fresh.mode == mdClear,
        "an unrecognised mode with no history did not fall to clear")
  report("an unknown mode keeps last turn's, else clear")

proc testLeadTicksClamp() =
  check(parsed("""{"mode":"clear","lead_ticks":-5}""").leadTicks == 0,
        "lead_ticks -5 was not clamped to 0")
  check(parsed("""{"mode":"clear","lead_ticks":999}""").leadTicks == 48,
        "lead_ticks 999 was not clamped to 48")
  check(parsed("""{"mode":"clear","lead_ticks":"16"}""").leadTicks == 16,
        "a numeric-string lead_ticks did not parse")
  check(parsed("""{"mode":"clear","lead_ticks":null}""").leadTicks == 14,
        "a null lead_ticks did not repair to 14")
  report("lead_ticks: clamped to [0, 48], null repairs to 14")

proc testNoteAndSayCaps() =
  let long = "x".repeat(300)
  let stance = parsed(&"""{{"mode":"clear","note":"{long}"}}""")
  check(stance.note.runeLen == MaxNoteRunes,
        &"a 300-char note came out {stance.note.runeLen} runes")
  report("a 300-character note is cut to exactly 160 runes")

proc testEmojiOnTheBoundary() =
  ## THE RUNE RULE. A 4-byte emoji sitting on the 48-rune boundary must be cut
  ## on the RUNE boundary: a byte-truncated codepoint renders in a browser and
  ## then fails a strict UTF-8 parser, which is the bug that makes a replay
  ## unreadable to everything except the one lenient viewer.
  let say = "a".repeat(47) & "\u{1F600}\u{1F600}"    ## 47 + two 4-byte emoji
  check(say.runeLen == 49, "the fixture say is not 49 runes")
  var node = newJObject()
  node["mode"] = %"clear"
  node["say"] = %say
  let stance = parseLaneStance(node, DefaultStance, false)
  # sanitizeSay caps at 48 runes FIRST and then strips non-printable-ASCII, so
  # the emoji goes entirely — it is never left as a half codepoint.
  check(stance.say.runeLen <= MaxSayRunes,
        &"say is {stance.say.runeLen} runes, over the cap")
  check(stance.say.validateUtf8() == -1, "say is not valid UTF-8")
  # And the raw truncation on its own lands on the boundary too.
  let cut = truncateRunes(say, 48)
  check(cut.runeLen == 48, &"truncateRunes gave {cut.runeLen} runes")
  check(cut.validateUtf8() == -1, "truncateRunes split a codepoint")
  check(cut.endsWith("\u{1F600}"), "truncateRunes dropped the boundary rune")
  # The whole record must round-trip through %$ -> parseJson and decode as
  # UTF-8, which is exactly what the replay reader does.
  var emojiStance = stance
  emojiStance.note = "\u{1F600}".repeat(200)
  emojiStance.note = truncateRunes(emojiStance.note, MaxNoteRunes)
  let record = boundedStanceRecord(emojiStance, 3, 1, 1, "BLUE")
  check(record.runeLen <= MaxStanceRunes,
        &"the stance record is {record.runeLen} runes, over {MaxStanceRunes}")
  check(record.validateUtf8() == -1, "the stance record is not valid UTF-8")
  let reparsed = parseJson(record)
  check(reparsed{"k"}.getStr() == "stance", "the record did not round-trip")
  report("a 4-byte emoji on the boundary: rune-cut, valid UTF-8, round-trips")

proc testNoUsableFieldRaises() =
  ## The ONE condition the retry and then the fallback exist for.
  var raised = false
  try:
    discard parsed("""{"weather":"fine"}""")
  except StanceError:
    raised = true
  check(raised, "a reply with no usable field did not raise")
  raised = false
  try:
    discard parsed("I would rather not say.")
  except StanceError:
    raised = true
  except JsonParsingError:
    raised = true
  check(raised, "a reply with no JSON object at all did not raise")
  report("a reply with nothing usable raises, so the retry can fire")

proc testRecordCaps() =
  let long = "n".repeat(400)
  var stance = DefaultStance
  stance.note = long
  stance.say = "s".repeat(200)
  let record = boundedStanceRecord(stance, 11, 2, 2, "GREEN")
  check(record.runeLen <= MaxStanceRunes,
        &"an over-long stance record is {record.runeLen} runes")
  check(parseJson(record){"k"}.getStr() == "stance",
        "the shrunk record is not valid JSON")
  let reg = registerRecord(0, 0, "RED", "p".repeat(200), "llm", "arcader")
  check(parseJson(reg){"policy"}.getStr().runeLen == MaxPolicyLabelRunes,
        "the policy label was not capped at 48 runes")
  let fb = fallbackRecord(3, 1, 2, "timeout", "d".repeat(500))
  check(parseJson(fb){"detail"}.getStr().runeLen == MaxFallbackDetailRunes,
        "the fallback detail was not capped at 200 runes")
  report("register.policy ≤ 48, fallback.detail ≤ 200, stance ≤ 600 runes")

when isMainModule:
  echo "test_stances"
  testProsePrefixed()
  testPercentageRisk()
  testModeSynonyms()
  testZoneSynonyms()
  testFireSynonyms()
  testUnknownModeKeepsLastTurn()
  testLeadTicksClamp()
  testNoteAndSayCaps()
  testEmojiOnTheBoundary()
  testNoUsableFieldRaises()
  testRecordCaps()
  echo "test_stances OK"
