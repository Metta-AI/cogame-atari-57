## Frozen numeric policies use only the ordinary private lane view.
import std/json
import stances, baselines

const
  NumericFeatures* = 435
  NumericActions* = 51
  Zones = ["none", "nw", "ne", "sw", "se", "centre", "left", "right", "top", "bottom"]

proc features*(view: JsonNode): JsonNode =
  result = newJArray()
  for name in ["chomper", "brickfall", "gallery"]:
    result.add(%(if view["rom"].getStr() == name: 1 else: 0))
  for key in ["turn", "of"]: result.add(view[key])
  result.add(view["clock"]["left_s"])
  let you = view["you"]
  for key in ["lives", "points", "score", "screen"]: result.add(you[key])
  for key in ["col", "row", "x", "y", "speed_tiles_s"]:
    result.add(you["avatar"][key])
  for key in ["power_ticks_left", "chain", "best_chain", "par"]:
    result.add(you[key])
  result.add(%(if you["record"].getBool(): 1 else: 0))
  for player in view["scoreboard"]:
    for key in ["score", "lives", "screen"]: result.add(player[key])
  for zone in ["nw", "ne", "sw", "se", "centre"]:
    for key in ["value", "min_threat_eta"]:
      result.add(view["zones"][zone][key])
  for line in view["screen_map"]:
    for ch in line.getStr(): result.add(%ord(ch))
  for index in 0 ..< 12:
    if index < view["targets"].len:
      let target = view["targets"][index]
      for key in ["col", "row", "value", "dist_ticks"]:
        result.add(target[key])
      result.add(%(if target["safe"].getBool(): 1 else: 0))
      var zoneIndex = 0
      for position, zone in Zones:
        if target["zone"].getStr() == zone: zoneIndex = position
      result.add(%zoneIndex)
    else:
      for _ in 0 ..< 6: result.add(%0)
  for index in 0 ..< 8:
    if index < view["threats"].len:
      let threat = view["threats"][index]
      for key in ["col", "row", "eta_ticks", "dist_tiles"]:
        result.add(threat[key])
    else:
      for _ in 0 ..< 4: result.add(%0)
  doAssert result.len == NumericFeatures

proc candidateStance*(view: JsonNode, choice: int): JsonNode =
  doAssert choice in 0 ..< NumericActions
  if choice > 0:
    let code = choice - 1
    let mode = Mode(code div Zones.len)
    return %*{"mode": $mode, "zone": Zones[code mod Zones.len],
      "risk": (if mode in [mdSafe, mdBank]: 0.2 else: 0.55),
      "lead_ticks": 12, "fire": "auto", "note": "numeric stance", "say": ""}
  let stance = arcaderStance(view)
  %*{"mode": $stance.mode, "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0, "lead_ticks": stance.leadTicks,
    "fire": $stance.fire, "note": stance.note, "say": stance.say}
