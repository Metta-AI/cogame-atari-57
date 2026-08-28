## The preset machinery: defaults -> the named preset -> any explicitly
## supplied key, in that order and no other.

import std/[json, strformat]
import lane_helpers
import lane/[sim_types, rom, observation]

proc testApplicationOrder() =
  ## The certification fixture ships `rom: "chomper"` together with
  ## `livesPerLane: 9`, and 9 must win over the preset's 3. If the order were
  ## preset-last, the fixture would silently play a different game.
  var config = defaultGameConfig()
  config.update("""{"rom":"chomper","livesPerLane":9}""")
  check(config.preset.livesPerLane == 9,
        &"explicit livesPerLane lost to the preset ({config.preset.livesPerLane})")
  check(config.preset.parScore == 2600, "the preset's parScore was lost")

  var plain = defaultGameConfig()
  plain.update("""{"rom":"chomper"}""")
  check(plain.preset.livesPerLane == 3,
        "the preset default was overridden by nothing at all")

  var swapped = defaultGameConfig()
  swapped.update("""{"rom":"gallery"}""")
  check(swapped.preset.livesPerLane == 3, "gallery lost its preset lives")
  check(swapped.preset.fireEnabled, "gallery lost fireEnabled")
  check(not swapped.preset.brakeEnabled, "gallery gained brakeEnabled")
  report("defaults -> preset -> explicit, in that order")

proc testEveryRomRow() =
  ## Each named ROM resolves to exactly its row of the design note's table.
  const rows = [
    (RomChomper, 3'i32, 1500'i32, 2600'i32, false, true, 500'i32, 1060'i32),
    (RomBrickfall, 3'i32, 2200'i32, 1800'i32, false, false, 350'i32, 1150'i32),
    (RomGallery, 3'i32, 1900'i32, 2000'i32, true, false, 300'i32, 1200'i32)
  ]
  for (rom, lives, speed, par, fire, brake, bonus, ramp) in rows:
    var config = defaultGameConfig()
    config.update(&"""{{"rom":"{rom}"}}""")
    let p = config.preset
    check(p.rom == rom, &"{rom}: the preset names {p.rom}")
    check(p.livesPerLane == lives, &"{rom}: livesPerLane {p.livesPerLane}")
    check(p.avatarSpeed == speed, &"{rom}: avatarSpeed {p.avatarSpeed}")
    check(p.parScore == par, &"{rom}: parScore {p.parScore}")
    check(p.fireEnabled == fire, &"{rom}: fireEnabled {p.fireEnabled}")
    check(p.brakeEnabled == brake, &"{rom}: brakeEnabled {p.brakeEnabled}")
    check(p.screenClearBonus == bonus, &"{rom}: bonus {p.screenClearBonus}")
    check(p.rampPermille == ramp, &"{rom}: ramp {p.rampPermille}")
    check(p.avatarMode == (if rom == RomChomper: amFreeGrid else: amRailBottom),
          &"{rom}: the wrong avatar mode")
  report("all three ROM rows resolve exactly")

proc testEveryVariantRunsClean() =
  ## EVERY variant's game_config is constructed and STEPPED, not just the
  ## fixture: a config-scaled resource that only blows up on one variant is
  ## exactly how a league schedules episodes that all die (collab-cooking
  ## 0.1.1, 2026-08-25).
  let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
  for variant in manifest{"variants"}:
    var node = variant{"game_config"}.copy()
    node["startWaitTicks"] = %0
    node["minPlayers"] = %1
    var config = defaultGameConfig()
    config.update($node)
    let id = variant{"id"}.getStr()
    let run = runScripted(config, maxTicks = 600)
    check(run.reason == "" or run.reason == ReasonComplete,
          &"variant {id} ended {run.reason}")
    var scored = false
    for seat in 0 ..< 4:
      if run.finalPoints[seat] > 0:
        scored = true
    check(scored, &"variant {id} scored nothing in 600 ticks")
  report("all three variants construct and step 600 ticks with four arcaders")

proc testDisabledActionsAreNoOps() =
  ## `fireEnabled: false` makes an `act == 1` byte a no-op with NO observable
  ## effect on the hash; `brakeEnabled: false` makes `act == 2` one; and a
  ## `railBottom` ROM ignores up/down entirely.
  for rom in RomNames:
    let config = testConfig(rom, 11)
    let preset = config.preset

    proc walk(actFor: proc (tick: int): int32): seq[uint64] =
      var lane: Lane
      initLane(lane, preset, config.seed)
      for tick in 0 ..< 240:
        let dir = int32(1 + (tick mod 4))
        discard stepLane(lane, encodeAction(dir, actFor(tick)), preset, tick,
                         preset.parScore)
        var h = 0'u64
        laneHash(h, lane)
        result.add(h)

    let plain = walk(proc (tick: int): int32 = 0)
    if not preset.fireEnabled:
      check(walk(proc (tick: int): int32 = 1) == plain,
            &"{rom}: a fire byte changed the state with fireEnabled false")
    if not preset.brakeEnabled:
      check(walk(proc (tick: int): int32 = 2) == plain,
            &"{rom}: a brake byte changed the state with brakeEnabled false")

    if preset.avatarMode == amRailBottom:
      var lane: Lane
      initLane(lane, preset, config.seed)
      let startY = lane.ay
      for tick in 0 ..< 60:
        discard stepLane(lane, encodeAction(int32(1 + tick mod 2), 0), preset,
                         tick, preset.parScore)
      check(lane.ay == startY, &"{rom}: up/down moved a railBottom paddle")
  report("disabled actions are no-ops; a rail ignores up and down")

proc testObservationRulesMatchWhatIsPaid() =
  ## The point table a policy is TOLD must be the point table the sim pays.
  for rom in RomNames:
    let config = testConfig(rom, 5)
    var game = seatedSim(config)
    let view = parseJson(laneViewJson(game, 0, 0, 24, DefaultStance, false))
    let rules = view{"rules"}
    check(rules{"lives_per_lane"}.getInt() == int(config.preset.livesPerLane),
          &"{rom}: the view reports the wrong lives")
    check(rules{"par_score"}.getInt() == int(config.preset.parScore),
          &"{rom}: the view reports the wrong par")
    check(rules{"points"}{"pellet"}.getInt() == int(PelletPoints),
          &"{rom}: the view reports the wrong pellet value")
    check(rules{"points"}{"power"}.getInt() == int(PowerPoints),
          &"{rom}: the view reports the wrong power value")
    check(rules{"points"}{"screen_clear"}.getInt() ==
            int(config.preset.screenClearBonus),
          &"{rom}: the view reports the wrong clear bonus")
    let chain = rules{"points"}{"chain"}
    check(chain.len == ChainPoints.len, "the chain table is the wrong length")
    for i in 0 ..< ChainPoints.len:
      check(chain[i].getInt() == int(ChainPoints[i]),
            &"{rom}: chain[{i}] disagrees with what the sim pays")
    check(view{"rom"}.getStr() == rom, "the view names the wrong rom")
  report("the observation's rules block equals the table the sim pays")

proc testUnknownRomIsRejected() =
  var raised = false
  var config = defaultGameConfig()
  try:
    config.update("""{"rom":"pitfall"}""")
  except LaneError:
    raised = true
  check(raised, "an unknown rom name was accepted")
  report("an unknown rom is rejected with a clean error")

when isMainModule:
  echo "test_rom"
  testApplicationOrder()
  testEveryRomRow()
  testEveryVariantRunsClean()
  testDisabledActionsAreNoOps()
  testObservationRulesMatchWhatIsPaid()
  testUnknownRomIsRejected()
  echo "test_rom OK"
