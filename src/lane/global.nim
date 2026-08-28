## The board: four CRT quadrants, baked once at startup with pixie from the
## art this repo already ships, and emitted over the Sprite v1 protocol.
##
## Replaces `coworld-ctf`'s `src/ctf/global.nim` (8 070 lines of fog of war,
## vision cones, first-person raycast, killfeed art and item sprites) with a
## top-down tile composition. **Kept verbatim from it** — because the wasm
## viewer's load-time capacity preflight and the whole board-scale contract
## rest on them — are `RenderScale`, `MaxSupersampledMapPixels`,
## `boardRenderScaleFor`, `shoutBubbleZoomFor`, `WasmViewerBudgetBytes`,
## `predictedViewerRenderBytes`, `BroadcastChromeSpriteId`,
## `chunkSpritePacket`, `dedupObjectPlacements` and `stripSpritePixels`.
##
## ART. Nothing here is a placeholder and nothing is downloaded: the phosphor
## plates come from `data/darkbg.png` and `data/arena_floor.png`, the maze
## walls from `client/art/walls/wall_h.jpg` and `wall_v.jpg`, the points
## readout from the arcade cells of `data/ascii.png`, the lives pips from the
## four `data/heart_<colour>.png`, and every label from `data/font.ttf`.

import std/[math, os, strutils, tables]
import pixie
import bitworld/spriteprotocol
import sim

const
  MapLayerId* = 0
  MapLayerType* = 0
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  BroadcastChromeSpriteId* = 4090
    ## The reserved never-drawn 1x1 sprite whose LABEL carries the whole JSON
    ## chrome frame. It rides the binary sprite channel because that is the
    ## only channel that survives a hosted replay.

const RenderScale* {.intdefine.} = 2
  ## Board supersample factor for the spectator/replay renderer.

const MaxSupersampledMapPixels* {.intdefine.} = 8_000_000
  ## Largest board (logical map pixels) that still renders at RenderScale.
  ## Above it the board emits at 1x: the static wasm replay viewer runs in a
  ## 32-bit address space and the supersampled bakes alone would blow it.

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  if mapWidth * mapHeight > MaxSupersampledMapPixels: 1
  else: RenderScale

proc shoutBubbleZoomFor*(mapWidth, mapHeight: int): int =
  ## How many times its base footprint a board speech bubble draws at on this
  ## board, so it keeps its on-screen size as boards grow.
  max(1, int(round(max(mapWidth / 1235, mapHeight / 659))))

const WasmViewerBudgetBytes* = 1_600_000_000
  ## Working-set ceiling for the wasm32 replay viewer: the address space ends
  ## at 2 GB and the observed OOM abort lands at ~1.98 GB of heap.

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  ## Engineering estimate of the viewer's peak working set for one board.
  let
    px = int64(mapWidth) * int64(mapHeight)
    k = int64(boardRenderScaleFor(mapWidth, mapHeight))
  px * 4 * (4 * k * k + 6)

# --- sprite ids -------------------------------------------------------------
const
  PlateBands = 7
  SpritePlateBase = 100
  SpriteWall = 200
  SpritePellet = 201
  SpritePower = 202
  SpriteBrickBase = 203          ## rows 3..6
  SpriteBunkerBase = 207         ## hp 1..3
  SpriteAvatarBase = 220         ## lane * 8 + facing(0..4)
  SpriteHunterBase = 260         ## chasing / fleeing / returning
  SpriteBall = 263
  SpriteMarcher = 264
  SpriteSaucer = 265
  SpriteBoltFriendly = 266
  SpriteBoltHostile = 267
  SpriteDigitBase = 280          ## lane * 16 + digit
  SpritePipBase = 350            ## per lane
  SpritePipSpent = 360
  SpriteOverBase = 370           ## per lane
  SpriteChipBase = 400           ## per lane, re-baked when the stance changes

  ObjectPlateBase = 100
  ObjectTileBase = 1_000         ## lane * 300 + tile index
  ObjectSpriteBase = 2_400       ## lane * 20 + slot
  ObjectDigitBase = 2_600        ## lane * 8 + position
  ObjectPipBase = 2_700          ## lane * 12 + pip
  ObjectOverBase = 2_800         ## lane
  ObjectChipBase = 2_900         ## lane
  MaxLaneSpriteSlots = 20
  MaxDigits = 8
  MaxPips = 12

  ## RED, BLUE, GREEN, YELLOW — the four lane tints, and the four names
  ## `chrome_common.js` already knows.
  LaneTints: array[4, ColorRGBA] = [
    ColorRGBA(r: 255, g: 74, b: 84, a: 255),
    ColorRGBA(r: 78, g: 160, b: 255, a: 255),
    ColorRGBA(r: 86, g: 226, b: 128, a: 255),
    ColorRGBA(r: 255, g: 208, b: 68, a: 255)
  ]
  BrickTints: array[4, ColorRGBA] = [
    ColorRGBA(r: 255, g: 118, b: 92, a: 255),
    ColorRGBA(r: 255, g: 176, b: 92, a: 255),
    ColorRGBA(r: 140, g: 208, b: 255, a: 255),
    ColorRGBA(r: 160, g: 160, b: 190, a: 255)
  ]

type
  SpriteDefinition = object
    spriteId: int
    width, height: int
    label: string
    compressedPixels: seq[uint8]

  DebugOverlay* = object
    ## Kept so the replay codec's debug-sprite records stay parseable. The
    ## cabinet's seats send no overlays (§Out of scope), so this is always
    ## empty in practice.
    sprites*: Table[int, SpritePacketSpriteDef]
    objects*: Table[int, SpritePacketObject]

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    tilesSent*: seq[uint8]
    chipsSent*: array[4, string]
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    selectedJoinOrder*: int
    povSelectPending*: int
    povActive*: bool
    povJoinOrder*: int
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    fpMapSent*: bool
    spriteDefs: seq[int]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    sentPlacements*: seq[array[12, uint8]]
    pendingDebugSprites*: seq[seq[uint8]]
    debugSpriteLimitWarned*: bool
    spriteDefs: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  result.selectedJoinOrder = -1
  result.povSelectPending = -2
  result.replaySeekTick = -1
  result.tilesSent = newSeq[uint8](4 * GridCells)

proc initPlayerViewerState*(): PlayerViewerState =
  PlayerViewerState(sentPlacements: @[])

proc gameDir*(): string =
  ## Where the shipped art lives. Under emscripten the whole `data/`
  ## directory is preloaded into the module's virtual filesystem.
  getCurrentDir()

proc clientDataDir*(): string =
  ## Where the shipped art resolves from. Under emscripten the whole `data/`
  ## directory is preloaded into the module's virtual filesystem at `data`;
  ## natively the process runs with the repo root as its working directory
  ## (the Dockerfile's WORKDIR), so the same relative path works.
  gameDir() / "data"

# ---------------------------------------------------------------------------
#  The bake
# ---------------------------------------------------------------------------

var
  bakedSprites: Table[int, Image]
  bakedPlate: seq[Image]
  bakeDone = false
  boardScale = 1
  boardTypeface: Typeface

proc loadArt(path: string): Image =
  ## Reads one shipped asset, tolerating both the repo layout and the
  ## emscripten preload layout.
  let candidates = [gameDir() / path, path, clientDataDir() / extractFilename(path)]
  for candidate in candidates:
    if fileExists(candidate):
      return readImage(candidate)
  raise newException(IOError, "missing shipped art: " & path)

proc typefaceOrNil(): Typeface =
  if boardTypeface.isNil:
    for candidate in [gameDir() / "data" / "font.ttf", "data/font.ttf",
                      clientDataDir() / "font.ttf"]:
      if fileExists(candidate):
        boardTypeface = readTypeface(candidate)
        break
  boardTypeface

proc drawLabel(target: Image, text: string, x, y, size: float32,
               colour: ColorRGBA) =
  ## One label, in the shipped face. Never raises: a board that cannot find
  ## its font still draws its tiles.
  let face = typefaceOrNil()
  if face.isNil or text.len == 0:
    return
  var font = newFont(face)
  font.size = size
  font.paint = colour
  try:
    target.fillText(font, text, translate(vec2(x, y)))
  except CatchableError:
    discard

proc tinted(source: Image, colour: ColorRGBA, w, h: int): Image =
  ## One art plate, resampled to a tile and multiplied by a lane tint. The
  ## chunky arcade look comes from the resample being nearest-neighbour on a
  ## small target rather than from a filter.
  result = newImage(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        sx = min(source.width - 1, x * source.width div max(1, w))
        sy = min(source.height - 1, y * source.height div max(1, h))
        p = source[sx, sy]
      result[x, y] = rgba(
        uint8((int(p.r) * int(colour.r)) div 255),
        uint8((int(p.g) * int(colour.g)) div 255),
        uint8((int(p.b) * int(colour.b)) div 255),
        p.a)

proc solid(w, h: int, colour: ColorRGBA): Image =
  result = newImage(w, h)
  result.fill(colour)

proc scanlined(image: var Image, strength: int) =
  ## The CRT read: every other row darkened. Cheap, and it is what makes four
  ## quadrants read as four SCREENS rather than four rectangles.
  for y in countup(1, image.height - 1, 2):
    for x in 0 ..< image.width:
      var p = image[x, y]
      p.r = uint8(max(0, int(p.r) - strength))
      p.g = uint8(max(0, int(p.g) - strength))
      p.b = uint8(max(0, int(p.b) - strength))
      image[x, y] = p

proc asciiGlyph(sheet: Image, ch: char, w, h: int, colour: ColorRGBA): Image =
  ## One cell of `data/ascii.png` (7x9 cells, 18 per row, starting at ASCII
  ## 32), tinted and scaled to the arcade points face.
  result = newImage(w, h)
  let
    idx = max(0, ord(ch) - 32)
    cx = (idx mod 18) * 7
    cy = (idx div 18) * 9
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        sx = cx + min(6, x * 7 div max(1, w))
        sy = cy + min(8, y * 9 div max(1, h))
      if sx >= sheet.width or sy >= sheet.height:
        continue
      let p = sheet[sx, sy]
      if p.a > 20'u8 and int(p.r) + int(p.g) + int(p.b) > 300:
        result[x, y] = colour

proc chevron(size: int, facing: int, colour: ColorRGBA): Image =
  ## The avatar: a bright chevron pointing along `facing`. Abstract on
  ## purpose — the cabinet's sprites are arcade glyphs, not characters.
  result = newImage(size, size)
  let half = size div 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = x - half
        dy = y - half
      var inside = false
      case facing
      of 1: inside = dy >= -half + 2 and abs(dx) <= (dy + half) div 2
      of 2: inside = dy <= half - 2 and abs(dx) <= (half - dy) div 2
      of 3: inside = dx >= -half + 2 and abs(dy) <= (dx + half) div 2
      of 4: inside = dx <= half - 2 and abs(dy) <= (half - dx) div 2
      else: inside = abs(dx) + abs(dy) <= half - 2
      if inside:
        result[x, y] = colour

proc eyeGlyph(size: int, colour: ColorRGBA): Image =
  ## A hunter: a chunky eye. Reads at 175 px per lane, which is the whole
  ## reason the sprites are glyphs and not portraits.
  result = newImage(size, size)
  let
    half = size div 2
    r = half - 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = x - half
        dy = y - half
      if dx * dx + dy * dy <= r * r:
        result[x, y] = colour
      if dx * dx + dy * dy <= (r div 3) * (r div 3):
        result[x, y] = rgba(12, 12, 20, 255)

proc marcherGlyph(size: int, colour: ColorRGBA): Image =
  result = newImage(size, size)
  let q = max(1, size div 5)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        gx = x div q
        gy = y div q
      if gy == 0 and (gx == 1 or gx == 3): result[x, y] = colour
      elif gy == 1 and gx >= 1 and gx <= 3: result[x, y] = colour
      elif gy == 2 and gx >= 0 and gx <= 4: result[x, y] = colour
      elif gy == 3 and (gx == 0 or gx == 2 or gx == 4): result[x, y] = colour

proc barGlyph(w, h: int, colour: ColorRGBA): Image =
  result = newImage(w, h)
  result.fill(colour)
  for x in 0 ..< w:
    result[x, 0] = rgba(255, 255, 255, 90)
    result[x, h - 1] = rgba(0, 0, 0, 120)

proc discGlyph(size, radius: int, colour: ColorRGBA): Image =
  result = newImage(size, size)
  let half = size div 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = x - half
        dy = y - half
      if dx * dx + dy * dy <= radius * radius:
        result[x, y] = colour

proc bakeBoardPlate(scale: int): seq[Image] =
  ## The static board: four dark phosphor plates with scanlines, a tinted
  ## one-tile frame per lane with its ALIAS burned into the top edge, and the
  ## gutter between them. Emitted once per viewer as `PlateBands` horizontal
  ## bands so no single sprite message is enormous.
  let
    tile = BoardTilePx * scale
    fullW = MapWidth * scale
    fullH = MapHeight * scale
  var board = newImage(fullW, fullH)
  board.fill(rgba(6, 7, 12, 255))
  let
    dark = loadArt("data/darkbg.png")
    floorArt = loadArt("data/arena_floor.png")
  var
    plate = tinted(dark, rgba(120, 130, 150, 255), tile, tile)
    floorTile = tinted(floorArt, rgba(60, 66, 86, 255), tile, tile)
  for lane in 0 ..< 4:
    let origin = laneOriginTiles(lane)
    for row in 0 ..< GridH:
      for col in 0 ..< GridW:
        let
          px = (origin.col + col) * tile
          py = (origin.row + row) * tile
        board.draw(
          (if (col + row) mod 2 == 0: plate else: floorTile),
          translate(vec2(float32(px), float32(py))))
    # The lane frame, in that lane's colour, with the alias burned in.
    let
      tint = LaneTints[lane]
      x0 = origin.col * tile
      y0 = origin.row * tile
      w = GridW * tile
      h = GridH * tile
      thickness = max(2, scale * 2)
    for t in 0 ..< thickness:
      for x in x0 ..< x0 + w:
        board[x, y0 + t] = tint
        board[x, y0 + h - 1 - t] = tint
      for y in y0 ..< y0 + h:
        board[x0 + t, y] = tint
        board[x0 + w - 1 - t, y] = tint
    board.drawLabel(
      laneAlias(lane),
      float32(x0 + 6 * scale), float32(y0 + 13 * scale),
      float32(11 * scale), tint)
  board.scanlined(18)
  result = @[]
  let bandH = (fullH + PlateBands - 1) div PlateBands
  for band in 0 ..< PlateBands:
    let
      top = band * bandH
      height = min(bandH, fullH - top)
    if height <= 0:
      result.add(newImage(1, 1))
      continue
    var slice = newImage(fullW, height)
    slice.draw(board, translate(vec2(0, float32(-top))))
    result.add(slice)

proc bakeAll(scale: int) =
  ## Every sprite the board can ever need, baked ONCE before the listener
  ## opens: a viewer's first-message clock starts at its successful connect
  ## and the certifier allows only seconds, so nothing may be assembled
  ## inside the serve loop.
  if bakeDone and boardScale == scale:
    return
  bakedSprites = initTable[int, Image]()
  boardScale = scale
  let tile = BoardTilePx * scale

  let
    wallH = loadArt("client/art/walls/wall_h.jpg")
    wallV = loadArt("client/art/walls/wall_v.jpg")
    ascii = loadArt("data/ascii.png")
  var wallPlate = tinted(wallH, rgba(150, 150, 175, 255), tile, tile)
  block:
    # A second wall plate blended in on the vertical axis keeps long
    # corridors from reading as one flat stripe.
    let vertical = tinted(wallV, rgba(120, 125, 160, 255), tile, tile)
    for y in 0 ..< tile:
      for x in 0 ..< tile:
        if ((x div max(1, tile div 4)) + (y div max(1, tile div 4))) mod 2 == 0:
          wallPlate[x, y] = vertical[x, y]
  bakedSprites[SpriteWall] = wallPlate
  bakedSprites[SpritePellet] =
    discGlyph(tile, max(2, tile div 8), rgba(240, 236, 200, 255))
  bakedSprites[SpritePower] =
    discGlyph(tile, max(4, tile div 3), rgba(255, 236, 120, 255))
  for row in 0 ..< 4:
    bakedSprites[SpriteBrickBase + row] =
      barGlyph(tile, max(4, tile * 3 div 4), BrickTints[row])
  for hp in 1 .. 3:
    let shade = uint8(80 + hp * 50)
    bakedSprites[SpriteBunkerBase + hp - 1] =
      barGlyph(tile, tile, rgba(shade, shade, uint8(min(255, int(shade) + 30)), 255))
  for lane in 0 ..< 4:
    for facing in 0 .. 4:
      bakedSprites[SpriteAvatarBase + lane * 8 + facing] =
        chevron(tile, facing, LaneTints[lane])
  bakedSprites[SpriteHunterBase + 0] = eyeGlyph(tile, rgba(255, 96, 96, 255))
  bakedSprites[SpriteHunterBase + 1] = eyeGlyph(tile, rgba(90, 140, 255, 255))
  bakedSprites[SpriteHunterBase + 2] = eyeGlyph(tile, rgba(150, 150, 160, 255))
  bakedSprites[SpriteBall] =
    discGlyph(tile, max(3, tile div 4), rgba(255, 255, 255, 255))
  bakedSprites[SpriteMarcher] = marcherGlyph(tile, rgba(180, 255, 170, 255))
  bakedSprites[SpriteSaucer] = discGlyph(tile, max(4, tile div 3),
    rgba(255, 120, 255, 255))
  bakedSprites[SpriteBoltFriendly] =
    solid(max(2, tile div 8), max(6, tile div 2), rgba(255, 255, 190, 255))
  bakedSprites[SpriteBoltHostile] =
    solid(max(2, tile div 8), max(6, tile div 2), rgba(255, 110, 110, 255))
  for lane in 0 ..< 4:
    for digit in 0 .. 9:
      bakedSprites[SpriteDigitBase + lane * 16 + digit] =
        asciiGlyph(ascii, char(ord('0') + digit),
                   max(6, tile div 2), max(8, tile * 3 div 4),
                   LaneTints[lane])
  for lane in 0 ..< 4:
    let heart = loadArt("data/heart_" & LaneTeamKeys[lane] & ".png")
    bakedSprites[SpritePipBase + lane] =
      tinted(heart, rgba(255, 255, 255, 255), max(8, tile div 2),
             max(8, tile div 2))
  block:
    let heart = loadArt("data/heart_red.png")
    bakedSprites[SpritePipSpent] =
      tinted(heart, rgba(70, 70, 80, 255), max(8, tile div 2),
             max(8, tile div 2))
  for lane in 0 ..< 4:
    var plate = newImage(GridW * tile, 3 * tile)
    plate.fill(rgba(0, 0, 0, 190))
    plate.drawLabel("GAME OVER", float32(tile), float32(2 * tile),
                    float32(tile), LaneTints[lane])
    bakedSprites[SpriteOverBase + lane] = plate
  bakedPlate = bakeBoardPlate(scale)
  bakeDone = true

proc invalidateBoardMapCaches*() =
  ## Drops the board bakes so a switched-in replay rebuilds them.
  bakeDone = false
  bakedSprites = initTable[int, Image]()
  bakedPlate = @[]

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Bakes everything BEFORE the listener opens (paintbot's own rule).
  bakeAll(boardRenderScaleFor(MapWidth, MapHeight))

proc bakeChip(lane: int, text: string): Image =
  ## The per-lane stance chip: where the LLM becomes visible on the board.
  let tile = BoardTilePx * boardScale
  result = newImage(7 * tile div 2, tile)
  result.fill(rgba(0, 0, 0, 170))
  result.drawLabel(text, float32(tile div 6), float32(tile * 3 div 4),
                   float32(tile * 5 div 12), LaneTints[lane])

# ---------------------------------------------------------------------------
#  Packet helpers (kept from paintbot)
# ---------------------------------------------------------------------------

proc rgbaBytes(image: Image): seq[uint8] =
  result = newSeq[uint8](image.width * image.height * 4)
  var i = 0
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let p = image[x, y]
      result[i] = p.r
      result[i + 1] = p.g
      result[i + 2] = p.b
      result[i + 3] = p.a
      i += 4

proc addImageSprite(packet: var seq[uint8], spriteId: int, image: Image) =
  packet.addSprite(spriteId, image.width, image.height, rgbaBytes(image))

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one packet at MESSAGE boundaries so no websocket frame exceeds
  ## the hosted replay's 1 MiB limit. Kept from paintbot: the client
  ## accumulates sprite/object state across binary messages, so N chunks are
  ## equivalent to one packet.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    start = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        offset = packet.len
        break
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      if offset + 2 > packet.len:
        offset = packet.len
        break
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      offset = packet.len
      break
    if offset - start > maxBytes and messageStart > start:
      result.add(packet[start ..< messageStart])
      start = messageStart
  if start < packet.len:
    result.add(packet[start ..< packet.len])

proc stripSpritePixels*(packet: seq[uint8]): seq[uint8] =
  ## Rewrites every sprite definition to carry no pixel payload, for a client
  ## that asked for Sprites Off (0x87).
  result = @[]
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    let start = offset
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        break
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      if offset + 2 > packet.len:
        break
      let labelLen = packet.readU16(offset)
      let labelStart = offset + 2
      offset += 2 + labelLen
      var label = ""
      for i in 0 ..< labelLen:
        label.add(char(packet[labelStart + i]))
      result.addSprite(spriteId, width, height, [], label)
    of 0x02:
      offset += 11
      for i in start ..< offset:
        result.add(packet[i])
    of 0x03:
      offset += 2
      for i in start ..< offset:
        result.add(packet[i])
    of 0x04:
      for i in start ..< offset:
        result.add(packet[i])
    of 0x05:
      offset += 5
      for i in start ..< offset:
        result.add(packet[i])
    of 0x06:
      offset += 3
      for i in start ..< offset:
        result.add(packet[i])
    else:
      break
  if result.len == 0:
    result = packet

proc dedupObjectPlacements*(
  packet: seq[uint8], sent: var seq[array[12, uint8]]
): seq[uint8] =
  ## Drops object placements whose exact payload this viewer already holds.
  ## The protocol is retained-mode, so an unchanged placement need never be
  ## re-sent. Flat array, not a Table: the hashing was itself a hot spot.
  result = @[]
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset]
    let start = offset
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        break
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      if offset + 2 > packet.len:
        break
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
      for i in start ..< offset:
        result.add(packet[i])
    of 0x02:
      if offset + 11 > packet.len:
        break
      let objectId = packet.readU16(offset)
      var payload: array[12, uint8]
      for i in 0 ..< 11:
        payload[i] = packet[offset + i]
      payload[11] = 1
      offset += 11
      if objectId >= sent.len:
        sent.setLen(objectId + 1)
      if sent[objectId] != payload:
        sent[objectId] = payload
        for i in start ..< offset:
          result.add(packet[i])
    of 0x03:
      if offset + 2 > packet.len:
        break
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId < sent.len:
        var blank: array[12, uint8]
        sent[objectId] = blank
      for i in start ..< offset:
        result.add(packet[i])
    of 0x04:
      for value in sent.mitems:
        var blank: array[12, uint8]
        value = blank
      for i in start ..< offset:
        result.add(packet[i])
    of 0x05:
      offset += 5
      for i in start ..< offset:
        result.add(packet[i])
    of 0x06:
      offset += 3
      for i in start ..< offset:
        result.add(packet[i])
    else:
      break

proc validateDebugSpritePacket*(packet: openArray[uint8]) =
  discard packet.parseSpritePacket()

proc applyDebugSpritePacket*(
  overlay: var DebugOverlay, packet: openArray[uint8]
) =
  for message in packet.parseSpritePacket():
    case message.kind
    of spkSprite: overlay.sprites[message.sprite.id] = message.sprite
    of spkObject: overlay.objects[message.objectDef.id] = message.objectDef
    of spkDeleteObject: overlay.objects.del(message.objectId)
    of spkClearObjects: overlay.objects.clear()
    else: discard

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## Viewer input: mouse, clicks, and the replay transport commands the
  ## chrome sends as chat text. Paintbot's own parse, kept — including the
  ## whole-string `s:`/`v:` interception, so a multi-digit tick or slot is
  ## never mangled into a run of speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = (if item.hasLayer: item.layer else: MapLayerId)
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        let slot = try: parseInt(item.text[2 .. ^1]) except ValueError: -2
        if slot >= -1:
          state.povSelectPending = slot
      else:
        state.replayCommands.add(item.text)
    of SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: PlayerViewerState, message: string, inputMask: var uint8,
  pressedMask: var uint8, chatText: var string
) =
  ## A seat's own socket. **Input masks are DISCARDED**: the cabinet computes
  ## every action byte server-side, so a mask arriving here would be a second
  ## conflicting record per tick (design note, server edit 1). Only the
  ## registration chat is kept.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientDebugSpriteMessage:
      state.pendingDebugSprites.add(item.debugSprites)
    of SpriteClientInputMessage, SpriteClientMouseMoveMessage,
        SpriteClientMouseButtonMessage, SpriteClientReadyMessage:
      discard

# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

proc spriteForTile(t: Tile, hp: uint8, row: int): int =
  case t
  of tlWall: SpriteWall
  of tlPellet: SpritePellet
  of tlPower: SpritePower
  of tlBrick: SpriteBrickBase + clamp(row - 3, 0, 3)
  of tlBunker: SpriteBunkerBase + clamp(int(hp) - 1, 0, 2)
  else: 0

proc spriteForLaneSprite(sprite: LaneSprite): int =
  case sprite.kind
  of skChaser:
    case sprite.state
    of ssFleeing: SpriteHunterBase + 1
    of ssReturning: SpriteHunterBase + 2
    else: SpriteHunterBase + 0
  of skBall: SpriteBall
  of skMarcher: SpriteMarcher
  of skSaucer: SpriteSaucer
  of skBoltFriendly: SpriteBoltFriendly
  of skBoltHostile: SpriteBoltHostile
  else: 0

proc emitDefs(packet: var seq[uint8], sent: var seq[int]) =
  for id, image in bakedSprites.pairs:
    if id in sent:
      continue
    packet.addImageSprite(id, image)
    sent.add(id)

proc placeLane(
  packet: var seq[uint8],
  sim: SimServer,
  lane: int,
  state: var GlobalViewerState,
  currentIds: var seq[int],
  scale: int
) =
  ## One quadrant: its changed tiles, its live sprites, its baked points
  ## readout, its lives pips, its stance chip and — when the credit is spent
  ## — its GAME OVER plate.
  let
    laneState = sim.lanes[lane]
    tile = BoardTilePx * scale
    origin = laneOriginTiles(lane)

  # Tiles, emitted only where they CHANGED. A steady screen costs nothing.
  for row in 0 ..< GridH:
    for col in 0 ..< GridW:
      let
        idx = tileIndex(col, row)
        t = Tile(laneState.tiles[idx])
        spriteId = spriteForTile(t, laneState.bunkerHp[idx], row)
        slot = lane * GridCells + idx
        objectId = ObjectTileBase + lane * 300 + idx
      if state.tilesSent.len <= slot:
        state.tilesSent.setLen(4 * GridCells)
      let want = uint8(clamp(spriteId - SpriteWall + 1, 0, 255))
      if state.tilesSent[slot] == want:
        continue
      state.tilesSent[slot] = want
      if spriteId == 0:
        packet.addDeleteObject(objectId)
      else:
        packet.addObject(
          objectId,
          (origin.col + col) * tile,
          (origin.row + row) * tile,
          1, MapLayerId, spriteId)

  # Sprites and the avatar, in fixed slots so an id never changes owner.
  var slot = 0
  template placeSpriteAt(spriteId, x, y, z: int) =
    block place:
      if slot >= MaxLaneSpriteSlots:
        break place
      let objectId = ObjectSpriteBase + lane * MaxLaneSpriteSlots + slot
      let art = bakedSprites.getOrDefault(spriteId, nil)
      let w = (if art.isNil: tile else: art.width)
      let h = (if art.isNil: tile else: art.height)
      packet.addObject(
        objectId, x - w div 2, y - h div 2, z, MapLayerId, spriteId)
      currentIds.add(objectId)
      inc slot

  for sprite in laneState.sprites:
    if not sprite.alive:
      continue
    let spriteId = spriteForLaneSprite(sprite)
    if spriteId == 0:
      continue
    let p = boardPixelOfU(lane, sprite.x, sprite.y)
    placeSpriteAt(spriteId, p.x * scale, p.y * scale, 5)
  block avatar:
    if laneState.phase == lpOver:
      break avatar
    let p = boardPixelOfU(lane, laneState.ax, laneState.ay)
    placeSpriteAt(
      SpriteAvatarBase + lane * 8 + int(laneState.facing),
      p.x * scale, p.y * scale, 6)

  # The lane's own points, burned into the bottom edge of its frame the way
  # an arcade screen carries its score.
  let text = $int(laneState.points)
  for i in 0 ..< MaxDigits:
    let objectId = ObjectDigitBase + lane * MaxDigits + i
    if i >= text.len:
      packet.addDeleteObject(objectId)
      continue
    let digit = ord(text[i]) - ord('0')
    if digit < 0 or digit > 9:
      packet.addDeleteObject(objectId)
      continue
    packet.addObject(
      objectId,
      (origin.col * tile) + (2 * scale) + i * (tile div 2),
      (origin.row + GridH) * tile - (tile * 3 div 4) - 2 * scale,
      7, MapLayerId, SpriteDigitBase + lane * 16 + digit)
    currentIds.add(objectId)

  # Lives pips, from the shipped hearts.
  let livesPerLane = int(sim.config.preset.livesPerLane)
  for i in 0 ..< MaxPips:
    let objectId = ObjectPipBase + lane * MaxPips + i
    if i >= livesPerLane:
      packet.addDeleteObject(objectId)
      continue
    let spent = i >= int(laneState.lives)
    packet.addObject(
      objectId,
      (origin.col + GridW) * tile - (i + 1) * (tile div 2) - 2 * scale,
      (origin.row + GridH) * tile - (tile div 2) - 2 * scale,
      7, MapLayerId,
      (if spent: SpritePipSpent else: SpritePipBase + lane))
    currentIds.add(objectId)

  # The stance chip: CLEAR, HUNT.SW, STRIKE, SAFE, BANK.
  let chip = sim.seatStanceSummary(lane)
  let chipObject = ObjectChipBase + lane
  if chip.len == 0:
    packet.addDeleteObject(chipObject)
  else:
    if state.chipsSent[lane] != chip:
      state.chipsSent[lane] = chip
      packet.addImageSprite(SpriteChipBase + lane, bakeChip(lane, chip))
    packet.addObject(
      chipObject,
      origin.col * tile + 2 * scale,
      origin.row * tile + 2 * scale + tile div 3,
      8, MapLayerId, SpriteChipBase + lane)
    currentIds.add(chipObject)

  let overObject = ObjectOverBase + lane
  if laneState.phase == lpOver:
    packet.addObject(
      overObject,
      origin.col * tile,
      (origin.row + GridH div 2 - 1) * tile,
      9, MapLayerId, SpriteOverBase + lane)
    currentIds.add(overObject)
  else:
    packet.addDeleteObject(overObject)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  overlays: openArray[DebugOverlay] = [],
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false,
  replayMismatchTick = -1
): seq[uint8] =
  ## The spectator board for one viewer, at the supersampled board scale.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  nextState.povSelectPending = -2
  let scale = boardRenderScaleFor(MapWidth, MapHeight)
  bakeAll(scale)
  if nextState.tilesSent.len != 4 * GridCells:
    nextState.tilesSent = newSeq[uint8](4 * GridCells)
  if not nextState.initialized:
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, MapWidth * scale, MapHeight * scale)
    nextState.spriteDefs = @[]
    nextState.objectIds = @[]
    for i in 0 ..< nextState.tilesSent.len:
      nextState.tilesSent[i] = 0
    for lane in 0 ..< 4:
      nextState.chipsSent[lane] = ""
    result.emitDefs(nextState.spriteDefs)
    let bandH = (MapHeight * scale + PlateBands - 1) div PlateBands
    for band in 0 ..< bakedPlate.len:
      result.addImageSprite(SpritePlateBase + band, bakedPlate[band])
      result.addObject(
        ObjectPlateBase + band, 0, band * bandH, 0, MapLayerId,
        SpritePlateBase + band)
    nextState.initialized = true
  var currentIds: seq[int] = @[]
  for lane in 0 ..< 4:
    result.placeLane(sim, lane, nextState, currentIds, scale)
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  spritesOff = false
): seq[uint8] =
  ## ONE seat's frame: **its own lane only**, at 1x. The other three
  ## quadrants are not in a player frame at all, and board labels carry only
  ## the colour aliases (`showPlayerLabels` is forced false on this stream).
  result = @[]
  nextState =
    if state.isNil: initPlayerViewerState() else: state
  nextState.pendingDebugSprites = @[]
  bakeAll(boardRenderScaleFor(MapWidth, MapHeight))
  let lane = clamp(playerIndex, 0, 3)
  if not nextState.initialized:
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, GridW * BoardTilePx, GridH * BoardTilePx)
    nextState.spriteDefs = @[]
    result.emitDefs(nextState.spriteDefs)
    nextState.initialized = true
  let
    laneState = sim.lanes[lane]
    tile = BoardTilePx
  var currentIds: seq[int] = @[]
  for row in 0 ..< GridH:
    for col in 0 ..< GridW:
      let
        idx = tileIndex(col, row)
        spriteId = spriteForTile(
          Tile(laneState.tiles[idx]), laneState.bunkerHp[idx], row)
      if spriteId == 0:
        continue
      let objectId = ObjectTileBase + idx
      result.addObject(objectId, col * tile, row * tile, 1, MapLayerId, spriteId)
      currentIds.add(objectId)
  var slot = 0
  for sprite in laneState.sprites:
    if not sprite.alive or slot >= MaxLaneSpriteSlots:
      continue
    let spriteId = spriteForLaneSprite(sprite)
    if spriteId == 0:
      continue
    let objectId = ObjectSpriteBase + slot
    result.addObject(
      objectId,
      int(sprite.x * BoardTilePx div TileU) - tile div 2,
      int(sprite.y * BoardTilePx div TileU) - tile div 2,
      5, MapLayerId, spriteId)
    currentIds.add(objectId)
    inc slot
  if laneState.phase != lpOver:
    let objectId = ObjectSpriteBase + MaxLaneSpriteSlots
    result.addObject(
      objectId,
      int(laneState.ax * BoardTilePx div TileU) - tile div 2,
      int(laneState.ay * BoardTilePx div TileU) - tile div 2,
      6, MapLayerId, SpriteAvatarBase + lane * 8 + int(laneState.facing))
    currentIds.add(objectId)
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds
