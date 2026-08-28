## Static assertions over the shipped chrome. The board is proved by
## `wasm-viewer` in CI; this proves the PAGE is still the starter's page with
## the cabinet's block appended, and that every readout the sim can produce has
## somewhere to land.

import std/[strformat, strutils]
import crunchy
import lane_helpers

let
  page = readRepoFile("client/replay_broadcast.html")
  chrome = readRepoFile("client/chrome_common.js")
  core = readRepoFile("client/broadcast_core.js")
  config = readRepoFile("replay-viewer/config.nims")
  staticReplay = readRepoFile("replay-viewer/static_replay.js")

const
  ## The starter's `client/chrome_common.js`, byte for byte. It is copied with
  ## ZERO edits, so this pin is the whole assertion: if it moves, somebody
  ## edited the shared chrome instead of the appended game block.
  ChromeCommonSha =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  Banner = "atari-57 additions to the inherited coworld-ctf chrome"

proc sha256Hex(text: string): string =
  for b in sha256(text):
    result.add(toHex(int(b), 2).toLowerAscii())

proc gameBlock(): string =
  let at = page.find(Banner)
  check(at >= 0, "the appended game block's banner comment is missing")
  page[at .. ^1]

proc testChromeCommonIsByteIdentical() =
  let got = sha256Hex(chrome)
  check(got == ChromeCommonSha,
        &"client/chrome_common.js sha256 is {got}, the pin says " &
        &"{ChromeCommonSha}. It is copied byte-for-byte from coworld-ctf: " &
        "put your change in the appended game block instead.")
  check(chrome.contains("TEAM_ORDER = ['red', 'blue', 'green', 'yellow']"),
        "chrome_common no longer pins the four-team order the plates need")
  report("chrome_common.js is byte-identical to the starter's copy")

proc testTransportContract() =
  ## relayout() still owns --hudscale / --topband / --band on :root, the
  ## endcard still stops at the transport band, and every seek still dismisses
  ## it.
  check(page.contains("function relayout("), "relayout() is gone")
  for token in ["--hudscale", "--topband", "--band"]:
    check(page.contains("setProperty('" & token & "'") or
          page.contains("setProperty(\"" & token & "\""),
          &"relayout() no longer sets {token}")
  check(page.contains("var root = document.documentElement") and
        page.contains("root.style.setProperty('--hudscale'"),
        "the CSS variables are no longer set on the document root")
  let cardStart = page.find("#endcard {")
  check(cardStart >= 0, "#endcard has no CSS rule")
  check(page[cardStart ..< cardStart + 900].contains("bottom: var(--band"),
        "#endcard no longer stops at the transport band")
  check(page.contains("classList.remove('on')") and page.contains("endcard"),
        "the endcard is never dismissed")
  report("relayout owns --hudscale/--topband/--band; the endcard stops at --band")

proc testKeptElements() =
  const kept = [
    "id=\"viewport\"", "id=\"stage\"", "id=\"board\"", "id=\"lightpool\"",
    "id=\"grain\"", "id=\"lockerroom\"", "id=\"lk-art\"", "id=\"lk-bg\"",
    "id=\"lk-cap\"", "id=\"lk-sprites\"", "id=\"chrome\"", "id=\"scorebug\"",
    "id=\"plates-l\"", "id=\"plates-r\"", "id=\"clock\"", "id=\"clock-time\"",
    "id=\"clock-caption\"", "id=\"mmwarn\"", "id=\"bannerlane\"",
    "id=\"killfeed\"", "id=\"transport\"", "id=\"btn-play\"", "id=\"btn-back\"",
    "id=\"btn-fwd\"", "id=\"btn-end\"", "id=\"btn-restart\"", "id=\"btn-loop\"",
    "id=\"btn-skip\"", "id=\"btn-spoilers\"", "id=\"speedchips\"",
    "id=\"scrub\"", "id=\"scrub-fill\"", "id=\"scrub-head\"", "id=\"scrub-win\"",
    "id=\"momentum\"", "id=\"lulls\"", "id=\"tick-clock\"", "id=\"ffwd-chip\"",
    "id=\"ffwd-mini\"", "id=\"win-chip\"", "id=\"endcard\"",
    "id=\"ec-headline\"", "id=\"ec-how\"", "id=\"ec-wincond\"",
    "id=\"ec-teams\"", "id=\"ec-replay\"", "id=\"status\""]
  for id in kept:
    check(page.contains(id), &"the starter element {id} was removed")
  report(&"all {kept.len} kept starter elements are present")

proc testRemovedElements() =
  ## EXACTLY the elements the design note lists, and their CSS with them. The
  ## board is a fixed 1400x1400 square that always fits the frame, so the zoom
  ## bar and minimap exist for nothing.
  const removed = [
    "id=\"viewpanel\"", "id=\"minimap\"", "id=\"minimap-canvas\"",
    "id=\"zoombar\"", "id=\"zoom-out\"", "id=\"zoom-in\"", "id=\"zoom-slider\"",
    "id=\"zoom-read\"", "id=\"fpv\"", "id=\"fpv-canvas\"", "id=\"fpv-hud\"",
    "id=\"fpv-name\"", "id=\"fpv-hp\"", "id=\"fpv-gear\"", "id=\"fpv-map\"",
    "id=\"fpv-map-canvas\"", "id=\"fpv-cap\"", "id=\"fpv-grip\"",
    "id=\"povBadge\""]
  for id in removed:
    check(not page.contains(id), &"the removed element {id} is still present")

  # Above the banner is the inherited page; the banner comment itself LISTS
  # what was removed, which is the record of the edit and must stay.
  let inherited = page[0 ..< page.find(Banner)]
  for selector in ["#viewpanel", "#minimap", "#zoombar", "#zoom-slider",
                   "#zoom-read", "#povBadge", "#fpv {", ".fpv-hud", ".zbtn"]:
    check(not inherited.contains(selector),
          &"CSS or markup for the removed element {selector} is still present")
  report("every removed element and its CSS is gone")

proc testBeatMarkers() =
  ## Every kind the sim emits as a BEAT has a CSS rule, and every marker the
  ## game block draws is a <button> that seeks on click — not an unlabelled
  ## div (cogame-tandem, 2026-08-23).
  const beats = ["life_lost", "screen_clear", "record", "lane_over", "over"]
  for kind in beats:
    check(page.contains(".beat-marker." & kind),
          &"no .beat-marker.{kind} CSS rule — that beat would be invisible")
  let appended = gameBlock()
  check(appended.contains("button.beat-marker"),
        "the beat markers are not styled as buttons")
  check(appended.contains("createElement('button')"),
        "the game block does not create button markers")
  check(appended.contains("setAttribute('aria-label'"),
        "the beat markers carry no aria-label")
  check(appended.contains("CTX.send('s:' + tick)"),
        "clicking a beat marker does not seek")
  report("every beat kind has CSS; markers are labelled, clickable buttons")

proc testNoAliasCollision() =
  ## The page's chrome alias block declares the shared helpers with hoisted
  ## `var`s. A game-block function of the same name is silently swallowed by
  ## one, which is how a scrubber ends up with markers that never seek.
  var aliases: seq[string]
  let aliasStart = page.find("  var C = window.ChromeCommon(")
  let aliasEnd = page.find("// ---- core (board renderer + WS) ----")
  check(aliasStart >= 0 and aliasEnd > aliasStart, "the alias block moved")
  for line in page[aliasStart ..< aliasEnd].splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("var "):
      continue
    for part in trimmed[4 .. ^1].split(','):
      let name = part.split('=')[0].strip()
      # Only the SHARED chrome helpers matter: a one-letter loop variable is
      # not a hoisted alias anyone could shadow by accident.
      if name.len > 2 and
          name.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}):
        aliases.add(name)
  check(aliases.len > 10, &"only {aliases.len} aliases found; the block moved")
  let appended = gameBlock()
  for name in aliases:
    check(not appended.contains("function " & name & "("),
          &"the game block redeclares the aliased chrome helper `{name}`")
    check(not appended.contains("var " & name & " ="),
          &"the game block shadows the aliased chrome helper `{name}`")
  report(&"no game-block name collides with the {aliases.len} chrome aliases")

proc testLegibleAt360() =
  let appended = gameBlock()
  check(appended.contains("flex: 1 1 auto;") and appended.contains("min-width: 3.2em;"),
        ".plate-name is missing its flex/min-width rule — the plate captions " &
        "would collapse to a bare ellipsis in the 360px featured-match iframe")
  check(appended.contains("#stage.tiny .plate .a57-pts { display: none; }"),
        "the .tiny rule that collapses the raw-points line is missing")
  check(appended.contains("#stage.tiny .plate .scrchip"),
        "the .tiny rule for the screen chip is missing")
  check(appended.contains("#stage.tiny #a57-legend { display: none; }"),
        "the .tiny rule that hides the stance legend is missing")
  check(appended.contains("@media (max-width: 640px)"),
        "labels are not hidden under 640px")
  check(page.contains("Math.max(0.5, Math.min(1.6, boardW / 760))"),
        "relayout()'s --hudscale clamp is gone")
  check(page.contains("stage.classList.toggle('tiny', boardW <= 620)"),
        "#stage.tiny is no longer toggled at the 620px boundary")
  report(".plate-name survives 360px; the .tiny and 640px rules are present")

proc testNoStarterIdentifiers() =
  ## No `ctf_` / `CTF_` / `paintball` identifier survives in client/,
  ## replay-viewer/ or src/ — EXCEPT the one `window.CTF_WIRE` read inside
  ## chrome_common.js, which is copied byte-for-byte from the starter and is
  ## sha-pinned above. Every value it falls back to is already this game's.
  const files = [
    "client/replay_broadcast.html", "client/league_replayer.html",
    "client/broadcast_core.js", "replay-viewer/atari57_replay.nim",
    "replay-viewer/static_replay.js", "replay-viewer/static_replay_worker.js",
    "src/atari57.nim", "src/atari57_player.nim", "src/lane/sim.nim",
    "src/lane/server.nim", "src/lane/global.nim", "src/lane/replays.nim",
    "src/lane/wire_constants.nim"]
  for name in files:
    let body = readRepoFile(name)
    for token in ["ctf_", "CTF_", "paintball", "Paintball"]:
      var at = body.find(token)
      while at >= 0:
        # An inherited-provenance line ("coworld-ctf's src/ctf/...") is a
        # comment naming where the file came from, which must stay.
        let lineStart = body.rfind('\n', last = at) + 1
        var lineEnd = body.find('\n', at)
        if lineEnd < 0: lineEnd = body.len
        let line = body[lineStart ..< lineEnd]
        let isComment = line.strip().startsWith("#") or
          line.strip().startsWith("//") or line.strip().startsWith("##") or
          line.strip().startsWith("*") or line.contains("coworld-ctf")
        check(isComment,
              &"{name} carries a live `{token}` identifier: {line.strip()}")
        at = body.find(token, at + 1)
  check(core.contains("window.LANE_WIRE"),
        "broadcast_core.js does not read the renamed wire constants")
  report("no live ctf_/CTF_/paintball identifier outside chrome_common.js")

proc testBroadcastCoreDiffersOnlyInTheWireName() =
  ## The core is the starter's, verbatim apart from the ONE identifier.
  var restored = core.replace("window.LANE_WIRE", "window.CTF_WIRE")
  restored = restored.replace("in src/lane/sim.nim)", "in src/ctf/sim.nim)")
  check(restored.count("window.CTF_WIRE") == 2,
        "broadcast_core.js changed by more than the wire identifier")
  report("broadcast_core.js differs from the starter's in the wire name alone")

proc testStaticReplayMarkers() =
  check(staticReplay.contains("'data-replay-loaded', 'true'"),
        "static_replay.js no longer sets data-replay-loaded on its first frame")
  check(staticReplay.contains("'data-replay-error'"),
        "static_replay.js no longer sets data-replay-error on failure")
  check(staticReplay.contains("'data-replay-mismatch-tick'"),
        "static_replay.js no longer reports a hash mismatch")
  check(staticReplay.contains("atari57-static-replay"),
        "the worker was not renamed")
  check(staticReplay.contains("window.Atari57StaticReplay"),
        "the static adapter was not renamed")
  report("static_replay.js sets data-replay-loaded and data-replay-error")

proc testViewerLinkFlags() =
  ## The link flags and the JS bootstrap are a MATCHED PAIR. This lineage waits
  ## for Module.onRuntimeInitialized, so MODULARIZE / EXPORT_NAME would deadlock
  ## the viewer silently with every file present and 200 (cogame-lantern,
  ## 2026-08-23).
  check(not config.contains("MODULARIZE"),
        "replay-viewer/config.nims gained MODULARIZE — the shell would deadlock")
  check(not config.contains("EXPORT_NAME"),
        "replay-viewer/config.nims gained EXPORT_NAME — the shell would deadlock")
  for flag in ["ENVIRONMENT=web,worker,node", "ABORTING_MALLOC=1",
               "ALLOW_MEMORY_GROWTH", "FILESYSTEM=1",
               "EXPORTED_RUNTIME_METHODS=HEAPU8", "--preload-file",
               "--define:useMalloc", "--mm:arc", "--exceptions:goto"]:
    check(config.contains(flag), &"the inherited link flag {flag} is gone")
  check(config.contains("_atari57_load_replay") and
        config.contains("_atari57_frame"),
        "the exported functions were not renamed")
  let worker = readRepoFile("replay-viewer/static_replay_worker.js")
  check(worker.contains("Module.onRuntimeInitialized") or
        worker.contains("onRuntimeInitialized"),
        "the worker no longer waits for onRuntimeInitialized")
  check(worker.contains("'./atari57_replay.js'"),
        "the worker does not import the renamed module")
  report("no MODULARIZE/EXPORT_NAME; the onRuntimeInitialized bootstrap is intact")

proc testStateKeysMatchTheChrome() =
  ## The state JSON's `teams` keys are exactly red/blue/green/yellow, which is
  ## what makes the four plates lay out with no edit at all.
  let broadcast = readRepoFile("src/lane/broadcast.nim")
  check(broadcast.contains("teams[laneTeamKey(seat)]"),
        "the chrome frame no longer keys teams by lane colour")
  let types = readRepoFile("src/lane/sim_types.nim")
  check(types.contains("""LaneTeamKeys* = ["red", "blue", "green", "yellow"]"""),
        "the four team keys chrome_common pins are gone")
  for key in ["\"t\":", "\"mt\":", "\"ph\":", "\"lob\":", "\"pl\":", "\"sp\":",
              "\"mx\":", "\"st\":", "\"lp\":", "\"sk\":", "\"ff\":", "\"en\":",
              "\"mm\":", "\"bs\":", "\"pov\":", "\"teams\":", "\"roster\":",
              "\"events\":"]:
    check(broadcast.contains(key), &"the chrome frame lost the {key} key")
  report("the chrome frame keeps the starter's key names and four team keys")

when isMainModule:
  echo "test_viewer"
  testChromeCommonIsByteIdentical()
  testTransportContract()
  testKeptElements()
  testRemovedElements()
  testBeatMarkers()
  testNoAliasCollision()
  testLegibleAt360()
  testNoStarterIdentifiers()
  testBroadcastCoreDiffersOnlyInTheWireName()
  testStaticReplayMarkers()
  testViewerLinkFlags()
  testStateKeysMatchTheChrome()
  echo "test_viewer OK"
