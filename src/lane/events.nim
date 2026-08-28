## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
##
## `coworld-ctf`'s `src/ctf/events.nim`, kept: one JSON-lines row per event
## plus the MANDATORY trailing summary row, which is how a reader
## distinguishes "this episode had no events" from "the file was truncated",
## and which carries the `GameVersion` the events were produced under.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect
## determinism.

import std/json
import ./sim

export eventKindKey, jsonRow

proc eventsJsonl*(
    events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
