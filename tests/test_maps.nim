## The three committed maps. They are CONSTANTS: there is no generator and no
## seed-derived terrain here, so a map that moves is a rules change and needs a
## GameVersion bump.

import std/[deques, strformat, strutils]
import crunchy
import lane_helpers
import lane/[sim_types, grid, maps]

proc sha256Hex(text: string): string =
  for b in sha256(text):
    result.add(toHex(int(b), 2).toLowerAscii())

proc testShape() =
  for rom in RomNames:
    let rows = mapRows(rom)
    check(rows.len == GridH, &"{rom}: {rows.len} rows, not {GridH}")
    for i, row in rows:
      check(row.len == GridW, &"{rom}: row {i} is {row.len} chars, not {GridW}")
  report("all three maps are exactly 17 strings of 17 characters")

proc testHashPins() =
  for rom in RomNames:
    let want = mapHash(rom)
    let got = sha256Hex(mapText(rom))
    check(got == want,
          &"{rom}: the committed map's sha256 is {got}, the pin says {want} " &
          "— update the pin AND bump GameVersion")
  report("every map matches its committed sha256")

proc testChomperCounts() =
  check(pelletCount(RomChomper) == 120,
        &"chomper has {pelletCount(RomChomper)} pellets, not 120")
  check(powerCount(RomChomper) == 4,
        &"chomper has {powerCount(RomChomper)} power pellets, not 4")
  check(walkableCount(RomChomper) == 127,
        &"chomper has {walkableCount(RomChomper)} walkable tiles, not 127")
  report("chomper: 120 pellets, 4 power pellets, 127 walkable tiles")

proc testChomperConnectivity() =
  ## Every walkable tile is reachable from the start tile by a flood fill that
  ## HONOURS the row-8 tunnel wrap. An unreachable pellet is a screen that can
  ## never be cleared.
  var lane: Lane
  loadMapTiles(lane, RomChomper)
  var
    seen: array[GridCells, bool]
    queue = initDeque[int]()
  let start = avatarStart(RomChomper)
  check(start == ChomperStart, &"chomper's P moved to {start}")
  seen[tileIndex(start.col, start.row)] = true
  queue.addLast(tileIndex(start.col, start.row))
  var reached = 1
  while queue.len > 0:
    let idx = queue.popFirst()
    let col = idx mod GridW
    let row = idx div GridW
    for d in 1'i32 .. 4'i32:
      let v = dirVector(d)
      var ncol = col + int(v.dx)
      let nrow = row + int(v.dy)
      if row == tunnelRow() and v.dy == 0:
        if ncol < 0: ncol = GridW - 1
        elif ncol >= GridW: ncol = 0
      if not inGrid(ncol, nrow):
        continue
      if not isWalkable(tileAt(lane, ncol, nrow)):
        continue
      let nidx = tileIndex(ncol, nrow)
      if seen[nidx]:
        continue
      seen[nidx] = true
      inc reached
      queue.addLast(nidx)
  check(reached == 127,
        &"only {reached} of 127 chomper tiles are reachable from the start")
  # And the tunnel really wraps, in both directions.
  check(isWalkable(tileAt(lane, 0, tunnelRow())), "the left tunnel mouth is wall")
  check(isWalkable(tileAt(lane, GridW - 1, tunnelRow())),
        "the right tunnel mouth is wall")
  check(wrapX(-1) == LaneSpanU - 1, "the tunnel does not wrap left to right")
  check(wrapX(LaneSpanU) == 0, "the tunnel does not wrap right to left")
  report("chomper: all 127 tiles reachable, the row-8 tunnel wraps both ways")

proc testBrickfall() =
  check(brickCount(RomBrickfall) == 60,
        &"brickfall has {brickCount(RomBrickfall)} bricks, not 60")
  var lane: Lane
  loadMapTiles(lane, RomBrickfall)
  for row in 0 ..< GridH:
    for col in 0 ..< GridW:
      if tileAt(lane, col, row) == tlBrick:
        check(row >= 3 and row <= 6, &"a brick sits on row {row}")
        check(col >= 1 and col <= 15, &"a brick sits on column {col}")
  var open = 0
  for col in 0 ..< GridW:
    if isWalkable(tileAt(lane, col, GridH - 1)):
      inc open
  check(open == GridW, "brickfall's row 16 is not an open drain")
  var total = 0'i32
  for row in 3 .. 6:
    total += brickRowPoints(row) * 15
  check(total == 1650, &"a full brickfall wall pays {total}, not 1650")
  report("brickfall: 60 bricks on rows 3..6 worth 1650, row 16 open")

proc testGallery() =
  check(bunkerCount(RomGallery) == 6,
        &"gallery has {bunkerCount(RomGallery)} bunker tiles, not 6")
  check(MarcherCols.len * MarcherRows.len == 32,
        "the gallery formation is not 4 x 8 = 32 marchers")
  for row in MarcherRows:
    check(row >= 2 and row <= 5, &"a marcher rank sits on row {row}")
  for col in MarcherCols:
    check(col >= 1 and col <= GridW - 2,
          &"a marcher column {col} starts outside the playable band")
  var lane: Lane
  loadMapTiles(lane, RomGallery)
  for col in BunkerCols:
    check(tileAt(lane, col, BunkerRow) == tlBunker,
          &"no bunker at column {col}")
  report("gallery: 6 bunkers, a 4 x 8 formation of 32 inside columns 1..15")

proc testBordersAreSealed() =
  ## No map has a walkable tile on its outer border except the two chomper
  ## tunnel mouths and brickfall's drain — a hole anywhere else lets a sprite
  ## leave the screen.
  for rom in RomNames:
    var lane: Lane
    loadMapTiles(lane, rom)
    for col in 0 ..< GridW:
      for row in [0, GridH - 1]:
        if rom == RomBrickfall and row == GridH - 1:
          continue
        check(not isWalkable(tileAt(lane, col, row)),
              &"{rom}: ({col},{row}) is an open border tile")
    for row in 0 ..< GridH:
      for col in [0, GridW - 1]:
        if rom == RomChomper and row == tunnelRow():
          continue
        if rom == RomBrickfall and row == GridH - 1:
          continue
        check(not isWalkable(tileAt(lane, col, row)),
              &"{rom}: ({col},{row}) is an open border tile")
  report("every border is sealed but the two tunnel mouths and the drain")

when isMainModule:
  echo "test_maps"
  testShape()
  testHashPins()
  testChomperCounts()
  testChomperConnectivity()
  testBrickfall()
  testGallery()
  testBordersAreSealed()
  echo "test_maps OK"
