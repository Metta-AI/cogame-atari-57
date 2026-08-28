## The three committed cartridge maps.
##
## Each is exactly 17 strings of 17 characters and is CONSTANT: there is no
## generator, no pool and no seed-derived terrain in this coworld (the
## paintbot machinery that produced those — `arena.nim`, `map_pool.nim`,
## `mapgen_styles.nim` — was deleted, not ported). The sha256 pins below are
## re-derived and compared by `tests/test_maps.nim`; a map edited without
## updating its pin fails there, and a map edited at all needs a
## `GameVersion` bump because every recorded replay re-simulates against it.
##
## Legend, shared by all three:
##   `#` wall      `.` pellet   `o` power pellet   `=` brick
##   `X` bunker    `_` paddle   `P` avatar start   ` ` tunnel mouth
##   `,` plain floor

import sim_types, grid

const
  MapsChomper*: array[GridH, string] = [
    "#################",
    "#o.............o#",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    "#...............#",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    " ............... ",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    "#.......P.......#",
    "#.##.###.###.##.#",
    "#.##.###.###.##.#",
    "#o.............o#",
    "#################"
  ]

  MapsBrickfall*: array[GridH, string] = [
    "#################",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#===============#",
    "#===============#",
    "#===============#",
    "#===============#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,_,,,,,,,,#",
    "                 "
  ]

  MapsGallery*: array[GridH, string] = [
    "#################",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,XX,,XX,,XX,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#,,,,,,,_,,,,,,,#",
    "#,,,,,,,,,,,,,,,#",
    "#################"
  ]

  ## sha256 of the 17 rows joined with '\n', per map. Re-derived by
  ## tests/test_maps.nim with crunchy; a mismatch means the map moved.
  MapHashChomper* =
    "28d2c606ef1a197e4f186ef21f8d2220e0d86b4cc09f46c2f21b7159c452ce6b"
  MapHashBrickfall* =
    "0d086ff31c5bafdb89d181a7b5dfaf64fd55e73c5c1c628e1dd91feaf23fec43"
  MapHashGallery* =
    "85d5ce00f1ff745e19231895c677b0a11e1bc23a9840c8774c00a8fd580d56de"

  BunkerHpFull* = 3'u8
  BunkerCols*: array[6, int] = [3, 4, 7, 8, 11, 12]
  BunkerRow* = 12
  ## The formation's eight columns. The design note lists 1, 3, 5, 7, 9, 11,
  ## 13 and 15; that spread is FLUSH against the note's own "would leave
  ## columns 1..15" bounds rule, so the body would step DOWN on every single
  ## march tick and breach row 13 in 160 ticks — a wave nothing could clear.
  ## The eight columns are therefore adjacent and centred, which leaves the
  ## body four tiles of room to the left and three to the right (a drop every
  ## ~7 march steps, ~1120 ticks to a breach) — the pacing every other number
  ## in the note is sized for. Everything else about the formation is the
  ## note's: 8 x 4, rows 2..5, one tile per step, reverse-and-drop at the
  ## edge, and `marchTicks` shortening per eight kills.
  MarcherCols*: array[8, int] = [5, 6, 7, 8, 9, 10, 11, 12]
  MarcherRows*: array[4, int] = [2, 3, 4, 5]
  GalleryPaddleRow* = 14
  BrickfallPaddleRow* = 15
  BrickfallDrainY* = int32(16 * TileU)  ## the top of row 16.
  ChomperStart*: tuple[col, row: int] = (8, 12)
  ChaserHome*: tuple[col, row: int] = (8, 4)
  ChaserStarts*: array[4, tuple[col, row: int]] = [
    (8, 4), (4, 8), (12, 8), (8, 1)
  ]

proc mapRows*(rom: string): array[GridH, string] =
  ## The 17 committed rows of one cartridge.
  case romText(rom)
  of RomBrickfall: MapsBrickfall
  of RomGallery: MapsGallery
  else: MapsChomper

proc mapHash*(rom: string): string =
  case romText(rom)
  of RomBrickfall: MapHashBrickfall
  of RomGallery: MapHashGallery
  else: MapHashChomper

proc mapText*(rom: string): string =
  ## The map as one newline-joined string — what the sha256 pin covers and
  ## what the replay config JSON carries verbatim.
  let rows = mapRows(rom)
  for i, row in rows:
    if i > 0:
      result.add('\n')
    result.add(row)

proc tileOfChar*(ch: char): Tile =
  case ch
  of '#': tlWall
  of '.': tlPellet
  of 'o': tlPower
  of '=': tlBrick
  of 'X': tlBunker
  of ' ': tlTunnel
  else: tlFloor

proc loadMapTiles*(lane: var Lane, rom: string) =
  ## Stamps one cartridge's committed map into a lane. Bunker hit points are
  ## reset with it; pellets, bricks and destroyed marchers are NOT restored
  ## by a respawn, only by a screen clear (which calls this).
  let rows = mapRows(rom)
  for row in 0 ..< GridH:
    let line = rows[row]
    for col in 0 ..< GridW:
      let ch = (if col < line.len: line[col] else: '#')
      let t = tileOfChar(ch)
      lane.tiles[tileIndex(col, row)] = uint8(t)
      lane.bunkerHp[tileIndex(col, row)] =
        (if t == tlBunker: BunkerHpFull else: 0'u8)

proc pelletCount*(rom: string): int =
  let rows = mapRows(rom)
  for row in rows:
    for ch in row:
      if ch == '.':
        inc result

proc powerCount*(rom: string): int =
  let rows = mapRows(rom)
  for row in rows:
    for ch in row:
      if ch == 'o':
        inc result

proc brickCount*(rom: string): int =
  let rows = mapRows(rom)
  for row in rows:
    for ch in row:
      if ch == '=':
        inc result

proc bunkerCount*(rom: string): int =
  let rows = mapRows(rom)
  for row in rows:
    for ch in row:
      if ch == 'X':
        inc result

proc walkableCount*(rom: string): int =
  let rows = mapRows(rom)
  for row in rows:
    for ch in row:
      if isWalkable(tileOfChar(ch)):
        inc result

proc avatarStart*(rom: string): tuple[col, row: int] =
  ## Where the avatar respawns. `freeGrid` uses the map's `P`; the two
  ## `railBottom` cartridges use the paddle row's `_`.
  let rows = mapRows(rom)
  for row in 0 ..< GridH:
    let line = rows[row]
    for col in 0 ..< GridW:
      if col < line.len and (line[col] == 'P' or line[col] == '_'):
        return (col, row)
  (GridW div 2, GridH div 2)
