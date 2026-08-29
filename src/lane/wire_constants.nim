## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. `coworld-ctf`'s `src/ctf/wire_constants.nim`,
## kept — rendered ONCE from the same Nim consts the engine runs on, spliced
## into every served client page by `server.nim` and emitted for the static
## wasm bundle by `tools/gen_wire_constants.nim`. Clients read
## `window.LANE_WIRE`.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.LANE_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",grid:" & jsIntArray([GridW, GridH]) &
  ",boardTiles:" & $BoardTiles &
  ",turnTicks:" & $DefaultTurnTicks &
  ",maxSayRunes:" & $MaxSayRunes &
  ",maxNoteRunes:" & $MaxNoteRunes &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.LANE_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
