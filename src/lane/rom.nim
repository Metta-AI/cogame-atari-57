## The three cartridge presets and the STRICT application order they are
## resolved through: **schema defaults -> the named `rom` preset -> any
## explicitly supplied config key**.
##
## That order is the whole point of the module and `tests/test_rom.nim` pins
## it: the certification fixture ships `rom: "chomper"` together with
## `livesPerLane: 9`, and 9 must win over the preset's 3.

import std/json
import sim_types

const
  ChomperPreset* = RomPreset(
    rom: RomChomper,
    livesPerLane: 3,
    avatarMode: amFreeGrid,
    avatarSpeed: 1_500,
    parScore: 2_600,
    fireEnabled: false,
    brakeEnabled: true,
    screenClearBonus: 500,
    rampPermille: 1_060,
    latchTicks: LatchTicks,
    powerTicks: 144,
    marchTicks0: 20,
    fireChancePermille: 0,
    ballSpeedMax: BallSpeedMax
  )
  BrickfallPreset* = RomPreset(
    rom: RomBrickfall,
    livesPerLane: 3,
    avatarMode: amRailBottom,
    avatarSpeed: 2_200,
    parScore: 1_800,
    fireEnabled: false,
    brakeEnabled: false,
    screenClearBonus: 350,
    rampPermille: 1_150,
    latchTicks: LatchTicks,
    powerTicks: 0,
    marchTicks0: 20,
    fireChancePermille: 0,
    ballSpeedMax: BallSpeedMax
  )
  GalleryPreset* = RomPreset(
    rom: RomGallery,
    livesPerLane: 3,
    avatarMode: amRailBottom,
    avatarSpeed: 1_900,
    parScore: 2_000,
    fireEnabled: true,
    brakeEnabled: false,
    screenClearBonus: 300,
    rampPermille: 1_200,
    latchTicks: LatchTicks,
    powerTicks: 0,
    marchTicks0: 20,
    fireChancePermille: 18,
    ballSpeedMax: BallSpeedMax
  )

  ## The point tables. Both the sim and the observation's `rules` block read
  ## THESE, so a policy is never told a number the engine does not pay
  ## (`tests/test_rom.nim` asserts the two agree).
  PelletPoints* = 10'i32
  PowerPoints* = 50'i32
  ChainPoints*: array[4, int32] = [100'i32, 150, 200, 250]
  BrickRowPoints*: array[4, int32] = [50'i32, 30, 20, 10]  ## rows 3,4,5,6
  MarcherRowPoints*: array[4, int32] = [30'i32, 20, 10, 10] ## top row first
  SaucerPoints* = 100'i32
  SaucerChancePermille* = 12'i32
  SaucerCooldownTicks* = 240'i32
  ScatterMinTicks* = 360'i32
  ScatterMaxTicks* = 600'i32
  BallServeTicks* = 24'i32
  BrickSpeedStep* = 50'i32
  BrickSpeedCap* = 1_400'i32
  BrickHitsPerStep* = 8'i32

proc presetFor*(rom: string): RomPreset =
  ## The named cartridge. An unknown name resolves to `chomper` rather than
  ## failing: a malformed config still plays a real game.
  case romText(rom)
  of RomBrickfall: BrickfallPreset
  of RomGallery: GalleryPreset
  else: ChomperPreset

proc brickRowPoints*(row: int): int32 =
  ## Bricks pay by row, top row worth most. Rows outside the wall pay the
  ## bottom rate rather than nothing, so a future taller wall cannot pay 0.
  if row >= 3 and row <= 6: BrickRowPoints[row - 3] else: BrickRowPoints[3]

proc marcherRowPoints*(row, topRow: int): int32 =
  ## Marchers pay by their rank within the formation, not by absolute row:
  ## a wave that starts one row lower must pay the same as the wave above it.
  let rank = row - topRow
  if rank >= 0 and rank < MarcherRowPoints.len: MarcherRowPoints[rank]
  else: MarcherRowPoints[MarcherRowPoints.high]

proc chainPoints*(chain: int32): int32 =
  ## 100 / 150 / 200 / 250 by chain position inside ONE power window; a fifth
  ## eat in the same window (impossible with four hunters) pays the cap.
  if chain < 0: ChainPoints[0]
  elif chain >= int32(ChainPoints.len): ChainPoints[ChainPoints.high]
  else: ChainPoints[chain]

proc applyPreset*(config: var GameConfig, explicitKeys: JsonNode) =
  ## Resolves `config.preset` in the design note's exact order. `config` has
  ## already been through `update` (so it carries schema defaults plus every
  ## explicitly supplied key); `explicitKeys` is the raw config object, which
  ## is how a key that HAPPENS to equal a default is still known to have been
  ## supplied. That distinction is the whole reason this takes two arguments.
  var preset = presetFor(config.rom)
  preset.rom = romText(config.rom)
  config.rom = preset.rom

  template explicit(name: string): bool =
    not explicitKeys.isNil and explicitKeys.kind == JObject and
      explicitKeys.hasKey(name)

  if explicit("livesPerLane"): preset.livesPerLane = int32(config.livesPerLane)
  if explicit("parScore"): preset.parScore = int32(config.parScore)
  if explicit("avatarSpeedMilli"):
    preset.avatarSpeed = int32(config.avatarSpeedMilli)
  if explicit("latchTicks"): preset.latchTicks = int32(config.latchTicks)
  if explicit("powerTicks"): preset.powerTicks = int32(config.powerTicks)
  if explicit("screenClearBonus"):
    preset.screenClearBonus = int32(config.screenClearBonus)
  if explicit("rampPermille"): preset.rampPermille = int32(config.rampPermille)
  if explicit("fireEnabled"): preset.fireEnabled = config.fireEnabled
  if explicit("brakeEnabled"): preset.brakeEnabled = config.brakeEnabled
  if explicit("marchTicks0"): preset.marchTicks0 = int32(config.marchTicks0)
  if explicit("fireChancePermille"):
    preset.fireChancePermille = int32(config.fireChancePermille)
  if explicit("ballSpeedMaxMilli"):
    preset.ballSpeedMax = int32(config.ballSpeedMaxMilli)

  # Bounds are enforced HERE, not at the call site: a config that arrives
  # from the platform is untrusted input and a rom preset is what the whole
  # sim reads.
  preset.livesPerLane = int32(clamp(int(preset.livesPerLane), 1, 12))
  preset.parScore = int32(clamp(int(preset.parScore), 100, 20_000))
  preset.avatarSpeed = int32(clamp(int(preset.avatarSpeed), 500, 4_000))
  preset.latchTicks = int32(clamp(int(preset.latchTicks), 0, 24))
  preset.powerTicks = int32(clamp(int(preset.powerTicks), 0, 480))
  preset.screenClearBonus = int32(clamp(int(preset.screenClearBonus), 0, 2_000))
  preset.rampPermille = int32(clamp(int(preset.rampPermille), 1_000, 1_500))
  preset.marchTicks0 = int32(clamp(int(preset.marchTicks0), 4, 60))
  preset.fireChancePermille =
    int32(clamp(int(preset.fireChancePermille), 0, 100))
  preset.ballSpeedMax = int32(clamp(int(preset.ballSpeedMax), 2_000, 6_000))

  config.preset = preset
  # Mirror the resolved values back onto the flat config keys so the replay's
  # config JSON carries the FULLY RESOLVED preset and playback never has to
  # re-run this function to agree with the recording.
  config.livesPerLane = int(preset.livesPerLane)
  config.parScore = int(preset.parScore)
  config.avatarSpeedMilli = int(preset.avatarSpeed)
  config.latchTicks = int(preset.latchTicks)
  config.powerTicks = int(preset.powerTicks)
  config.screenClearBonus = int(preset.screenClearBonus)
  config.rampPermille = int(preset.rampPermille)
  config.fireEnabled = preset.fireEnabled
  config.brakeEnabled = preset.brakeEnabled
  config.marchTicks0 = int(preset.marchTicks0)
  config.fireChancePermille = int(preset.fireChancePermille)
  config.ballSpeedMaxMilli = int(preset.ballSpeedMax)

proc presetJson*(preset: RomPreset): JsonNode =
  ## The resolved preset, as it is written into the replay config JSON.
  %*{
    "rom": preset.rom,
    "livesPerLane": preset.livesPerLane,
    "avatarMode": (if preset.avatarMode == amFreeGrid: "freeGrid"
                   else: "railBottom"),
    "avatarSpeed": preset.avatarSpeed,
    "parScore": preset.parScore,
    "fireEnabled": preset.fireEnabled,
    "brakeEnabled": preset.brakeEnabled,
    "screenClearBonus": preset.screenClearBonus,
    "rampPermille": preset.rampPermille,
    "latchTicks": preset.latchTicks,
    "powerTicks": preset.powerTicks,
    "marchTicks0": preset.marchTicks0,
    "fireChancePermille": preset.fireChancePermille,
    "ballSpeedMax": preset.ballSpeedMax
  }
