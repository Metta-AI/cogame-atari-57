## Frozen numeric policies use only the ordinary private lane view.
import std/json
import stances

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
  var mode = "clear"
  var zone = "none"
  var risk = 0.5
  var lead = 10
  var fire = "auto"
  var note = "take the nearest scoring thing"
  var say = "clearing"
  let you = view["you"]
  if you["state"].getStr() == "over":
    return %*{"mode":"safe", "zone":"none", "risk":0.0,
      "lead_ticks":12, "fire":"never", "note":"the credit is spent", "say":"backing off"}
  if you["power_ticks_left"].getInt() > 48:
    mode = "strike"; risk = 0.85; lead = 10
    note = "power window open: cash the chain"; say = "chain time"
  elif view["threats"].len > 0 and view["threats"][0]["eta_ticks"].getInt() >= 0 and view["threats"][0]["eta_ticks"].getInt() <= 20:
    mode = "safe"; risk = 0.15; lead = 8
    note = "threat inside 20 ticks: survive first"; say = "backing off"
  else:
    var bestValue = -1
    var powerFound = false
    var powerZone = "none"
    for target in view["targets"]:
      let distance = target["dist_ticks"].getInt()
      if target["kind"].getStr() == "power" and distance >= 0 and distance <= 72 and not powerFound:
        powerFound = true; powerZone = target["zone"].getStr()
      if target["value"].getInt() > bestValue:
        bestValue = target["value"].getInt(); zone = target["zone"].getStr()
    if powerFound:
      mode = "hunt"; zone = powerZone; lead = 16
      note = "power pellet in reach"; say = "power up"
    else:
      lead = 14
  if you["lives"].getInt() == 1:
    risk = risk / 2
    if mode == "hunt": mode = "clear"
    say = "screen's mine"
  %*{"mode":mode, "zone":zone, "risk":risk, "lead_ticks":lead,
    "fire":fire, "note":note, "say":say}
