# Wire protocol — the cabinet

Two sockets, one replay format, and one rule that matters more than any of
them: **a seat sees its own lane and the four-row scoreboard, and nothing
else.**

## THE PLAYER SOCKET (ws://<game>/player?slot=N&token=T)

A seat sends exactly ONE message that matters and then only receives.

1. REGISTRATION. One Sprite v1 chat frame (0x81), a JSON object:
     {"type":"register","prompt":"<strategy text or empty>",
      "scripted":"arcader"|"hoover"|null,"policy":"<free label>"}
   `prompt` non-empty makes the seat an LLM seat; `scripted` names a published
   baseline; a seat that sets neither is `arcader`, and the server LOGS THAT
   LOUDLY. The registration is re-sent for the first ~10 s of frames because a
   seat's slot may not be admissible yet; the server holds an unappliable
   registration rather than dropping it. `prompt` is capped at 4000 runes at
   the transport (truncated, never rejected) and is NEVER written to the
   replay or the results.

2. FRAMES. One binary Sprite v1 message per tick carrying THIS SEAT'S LANE
   ONLY: its whole 17x17 screen, every tile, every sprite, its avatar, its
   lives and its points. The other three quadrants are not in a player frame
   at all. Board labels carry only the colour aliases RED / BLUE / GREEN /
   YELLOW; `showPlayerLabels` is forced false on this stream.

3. READY. The seat replies with the Sprite v1 ready packet (0x85) after each
   received frame. SEATS SEND NO INPUTS: every action byte is computed
   server-side by the autopilot, so an input mask arriving on a player socket
   is discarded.

THE DECISION. Every 120 ticks (5.0 s) the GAME server composes this seat's
board view and asks the seat's policy for one STANCE. The view is the seat's
own screen as a 17-line ASCII map plus structured `threats`, `targets`,
`zones`, its own counters, and a four-row SCOREBOARD strip carrying every
rival's {alias, score, lives, screen} and nothing else. The reply is:

  {"note":"<=160 runes","mode":"clear|hunt|strike|safe|bank",
   "zone":"nw|ne|sw|se|centre|left|right|top|bottom|none",
   "risk":0.0..1.0,"lead_ticks":0..48,
   "fire":"auto|hold|never","say":"<=48 runes"}

Parsing is tolerant (markdown fences, prose prefixes, percentages, synonyms);
every field is repaired rather than rejected; two consecutive failures fall
back to the published `arcader` stance and write a `fallback` record.

## THE SPECTATOR SOCKET (ws://<game>/global) AND THE REPLAY BYTES

/global carries the same Sprite v1 board every viewer draws — the 2x2
quad-split of four 17x17 screens on one 1400x1400 board — plus ONE reserved
never-drawn 1x1 sprite (id 4090) whose LABEL is the whole JSON chrome frame.
That frame carries: `t`/`mt`/`ph`/`sp`/`mx`/`st`/`en` (the transport), `teams`
keyed red/blue/green/yellow with each lane's score, points, lives,
livesPerLane, screen, record flag and over flag, `roster` (the REAL policy
names — spectator side only), `events`, `a57` (the rom, the par, and each
lane's tiles, sprites, avatar and standing stance), `stances`, `lead` (the
momentum series), `beats`, `lulls` and, at game over, `over`.

THE REPLAY is the starter's binary COWLDA57 format and is SELF-SUFFICIENT:

  header      magic COWLDA57, format version, gameName atari-57, gameVersion 1
  config JSON seed, rom, the FULLY RESOLVED cartridge preset, the loaded map's
              17 rows verbatim and its sha256, the whole geometry table, the
              point tables, the scoring constants, the real player names and
              the in-game aliases
  joins       one per seat
  inputs      THE ACTION LOG: one action byte per seat per tick, written on
              change only. dir = cmd mod 5 (0 stay, 1 up, 2 down, 3 left,
              4 right); act = cmd div 5 (0 none, 1 fire, 2 brake); cmd >= 15
              is repaired to 0 identically on both sides
  chats       register / stance / fallback / budget_guard / stopped / result
  hashes      one gameHash per tick — the integrity chain the wasm viewer
              re-checks against its own re-simulation, every tick

The viewer is a STATIC wasm bundle (`replay_viewer.bundle =
static-replay-viewer`): it re-runs the same sim module the server ran from the
recorded action bytes and contacts no server but S3. `tools/replay_summary.py`
(Python 3 stdlib only) prints one strict-UTF-8 JSON object from a replay
file.

## The COGAME_* runtime contract

The game container is started with the platform's standard environment and
never receives `COWORLD_TIMEOUT_SECONDS` — so it assumes `episodeTimeoutSeconds`
= 1200 and settles inside 60 % of it by construction (`wallClockBudgetSeconds`
= 660, and a budget guard that switches the LLM off two turns before the stop
so the episode ends `complete/*` rather than `deadline`).

| variable | what |
|---|---|
| `COGAME_CONFIG_URI` | the episode's `game_config`, validated against `game.config_schema` |
| `COGAME_RESULTS_URI` | where `results.json` is written |
| `COGAME_SAVE_REPLAY_URI` | where the `COWLDA57` replay is written |
| `COGAME_LOAD_REPLAY_URI` | replay-server mode |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_METRICS_URI` | optional performance counters |
| `COGAME_PLAYER_FAILURE_URI` | where a lobby no-show is declared |
| `COGAME_HOST` / `COGAME_PORT` | the listener |
| `ANTHROPIC_API_KEY_URI` | `secret://coworld/atari-57/anthropic_api_key` — injected into the GAME pod, which is where every decision happens |

Routes: `GET /healthz`, `GET /player?slot=N&token=T` (websocket),
`GET /global` (websocket), `GET /replay` (websocket), `GET /client/global`,
`GET /client/player`, `GET /client/replay`, `GET /replay-data`.
`/client/global` and `/client/player` serve real pages and neither opens the
player socket — the episode runner probes both **before** starting the player
pods. The player websocket **closes on a token that does not match the seat**
(the certifier probes with a bad one), and a `Ping` is always answered with a
`Pong`. `/healthz` and `/global` keep answering for a bounded ~20 s after the
artifacts are written, because the runner pings `/global` *after* the player
pods start and a short episode can already be gone.

## Record vocabulary

**Replay chat records** (written by the server, re-applied in order at
playback):

| `k` | fields |
|---|---|
| `register` | `seat`, `alias`, `lane`, `policy` (≤ 48 runes), `kind`, `baseline` |
| `stance` | `turn`, `seat`, `alias`, `lane`, `source`, `latency_ms`, `note`, `mode`, `zone`, `risk`, `lead_ticks`, `fire`, `say` |
| `fallback` | `turn`, `seat`, `attempt`, `cause`, `detail` (≤ 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `stopped` | `tick`, `reason` — the load-bearing wall-clock stop, applied by the same proc on record and on playback |
| `result` | the whole results document, written once at game over |

**Derived broadcast events** — `pickup`, `chain`, `near_miss`, `life_lost`,
`screen_clear`, `record`, `lane_over`, `say`, `phase`, `over`. They are derived
from state deltas during playback, so they cost no replay bytes and are
identical live and in replay. **Beats** (scrubber markers) are exactly
`life_lost`, `screen_clear`, `record`, `lane_over` and `over`; `pickup`,
`chain`, `near_miss` and `say` fire hundreds of times and would bury the
scrubber.

**Rune discipline.** Every cap is measured in RUNES and every truncation lands
on a rune boundary. Slicing a string by byte index anywhere on the path to the
replay is forbidden: a byte-truncated multi-byte character renders fine in a
browser and then fails a strict UTF-8 parser.
