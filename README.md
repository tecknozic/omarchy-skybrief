# SkyBrief

Aviation weather in the Omarchy bar: METAR, TAF and the flight category at a
glance, decoded or raw.

> **This is not a flight-planning tool.** SkyBrief is a convenience display of
> publicly published weather. It is not a briefing, it knows nothing about your
> aircraft or your route, and it is not a substitute for the notice products an
> official briefing carries. Obtain that briefing from your national provider
> before any flight.

## What it shows

![SkyBrief's popup open on the desktop: the VFR pill on the bar, the raw METAR
for EIDW, the folded TREND line, the TAF with its category timeline and colour
legend, the quick list with each station's category and age, and the search
field](preview.png)

A one-letter pill in the bar, one letter per flight category:

| Letter | Category | Meaning |
|--------|----------|---------|
| `V` | VFR | ceiling above 3000 ft and visibility above 5 sm |
| `M` | MVFR | ceiling 1000–3000 ft or visibility 3–5 sm |
| `I` | IFR | ceiling 500–999 ft or visibility 1–3 sm |
| `L` | LIFR | ceiling below 500 ft or visibility below 1 sm |

The letter is tinted green, blue, red or magenta — the standard aviation
category colours, deliberately not taken from the desktop theme, since a green
that changed with the wallpaper would stop meaning "VFR".

States that are not a category have their own glyph: `?` when the station has no
observation, `!` when the network is unreachable, `…` before the first answer.

Left click opens a popup: the METAR and, directly under it, the TAF with its
category timeline, then the quick list of stations. Each of the two reports has
a copy button on its own header line. The decoded TAF marks the group in force
with **NOW**, so the paragraph that applies can be found without comparing five
clock ranges. A **TREND** line folds out the earlier observations of the same
station — one METAR says what is happening, three say which way it is going.
**Details** widens the popup into the view that holds what does not fit in a
glance — wind components per runway and SIGMETs for the configured FIR — and
closes it again on a second click. Middle click refreshes; right click opens the
detail view directly. With the popup open, `r` refreshes, `c` copies the raw
METAR, `t` the raw TAF, and `d` toggles the detail view.

On the timeline, an `FM` group starts its colour at an instant, because that is
what it states. A **BECMG** does not: "BECMG 2418/2420" means the new conditions
become established *somewhere* between 18Z and 20Z, and nothing in the report
says where. Those bands are therefore drawn as a gradient from the category in
force before the change to the one it brings, so the frise shows an hour the
forecast does not commit to as the uncertainty it is, instead of pretending the
change happened on the stroke of 18Z. The band is flat again after the window
closes — the one moment the TAF does name.

The search field takes either an **ICAO code** or a **place name**. A
four-character code is used directly; anything longer is geocoded and matched
against the reporting fields around that point, and the candidates are listed
with their names to choose from. A name never switches the favourite on its own:
"Rennes" and "Brest" each cover several airfields, and only the user knows which
one was meant.

## Data sources

| Product | Source | Notes |
|---|---|---|
| METAR, TAF, SIGMET, station and runway metadata | [aviationweather.gov](https://aviationweather.gov/data/api/) (NOAA/NWS) | No key, no account, worldwide. US Government work — public domain. |

Geocoding for the "nearest station" fallback uses
[open-meteo](https://open-meteo.com/) — the same service the built-in weather
panel uses.

## Installation

```bash
omarchy plugin add https://github.com/tecknozic/omarchy-skybrief.git --enable
```

Then place the widget:

```bash
omarchy bar move io.github.tecknozic.skybrief --section right
```

## Settings

Set from the Omarchy settings UI or from the command line:

```bash
omarchy bar set io.github.tecknozic.skybrief station LFPG
omarchy bar set io.github.tecknozic.skybrief quickStations "LFPG,LFPO,LFLL,EGGD"
omarchy bar set io.github.tecknozic.skybrief fir LFFF
omarchy bar set io.github.tecknozic.skybrief showRaw false
omarchy bar set io.github.tecknozic.skybrief units imperial
omarchy bar set io.github.tecknozic.skybrief timeFormat local
omarchy bar set io.github.tecknozic.skybrief refreshMinutes 5
omarchy bar set io.github.tecknozic.skybrief maxAgeMinutes 45
omarchy bar set io.github.tecknozic.skybrief alertCategory IFR
```

| Setting | Default | Meaning |
|---|---|---|
| `station` | *(empty)* | Favourite ICAO code. Empty uses the nearest reporting field to the Omarchy weather location. |
| `quickStations` | *(empty)* | Comma-separated codes offered as one-click rows in the popup, **ten at most**. Extra codes are ignored; the header shows the count. |
| `fir` | *(empty)* | FIR identifier (`LFFF`, `EDGG`, …) whose SIGMETs are shown alongside the aerodrome's. |
| `showRaw` | `true` | Start on the raw report text rather than the decoded reading. |
| `units` | `metric` | Applies to temperature, visibility and altimeter **only**. Wind stays in knots and cloud base in feet, as it is spoken. |
| `timeFormat` | `utc` | `utc` shows `07:30Z`; `local` shows the local clock with a zone suffix. |
| `refreshMinutes` | `10` | How often the reports are re-fetched. |
| `maxAgeMinutes` | `75` | An observation older than this is flagged as stale in the popup and the tooltip. |
| `historyCount` | `3` | How many earlier observations the TREND line unfolds. `0` hides it. The API caps a response at six. |
| `alertCategory` | `off` | Send a desktop notification when the favourite station's category drops to this level or worse. |

If `station` is empty, SkyBrief reads the location set by
`omarchy-weather-location` and picks the nearest reporting field from a
bounding-box query. Coordinates are used directly; a bare place name is
geocoded. With neither available it reports the error rather than silently
falling back to some arbitrary airport.

## Removing

```bash
omarchy plugin disable io.github.tecknozic.skybrief
omarchy plugin remove io.github.tecknozic.skybrief
```

## Security notes

- Every external binary is invoked by absolute path (`/usr/bin/bash`,
  `/usr/bin/curl`, `/usr/bin/head`, `/usr/bin/timeout`,
  `/usr/bin/omarchy-notification-send`), so nothing resolves through `$PATH`.
- Every network child runs with `clearEnvironment: true`.
- Only the notification child gets an environment, and only the two variables
  D-Bus needs.
- Every response is capped **while it arrives**, not after: each request pipes
  curl into `head -c 524288`, so the moment the cap is reached the pipe closes,
  curl's write fails, and it exits 23 — the shell never buffers an unbounded
  body. `pipefail` makes that 23 (or curl's own 6/22/28) the status of the whole
  pipeline. `--max-filesize` was not usable here: it does not apply to a
  response without `Content-Length`. An overflow is reported as its own error
  ("response exceeded 512 KiB and was cut off"), not as an unreachable endpoint.
- The URL is passed to the shell as a positional argument and preceded by `--`,
  never interpolated into the command string, so it cannot be read as a flag or
  a shell word.
- No text built from a remote response is rendered as rich text. Every `Text`
  in the plugin sets `Text.PlainText` explicitly — the decoded METAR included,
  which had been left on `AutoText` — and cloud cover codes are validated
  against the known set, so endpoint-controlled bytes can neither become markup
  nor reach the display at all.
- The plugin ships no executable, runs no installer, and never pipes a download
  into a shell. The one shell in use is `/usr/bin/bash -o pipefail -c` with a
  fixed command string, and its only variable parts are positional arguments.

## Development

```bash
node --test tests/          # JavaScript unit tests
omarchy plugin validate .   # manifest, entry points, no symlinks
scripts/qmllint.sh          # QML syntax and unknown-property checks
scripts/dev-sync.sh         # copy into ~/.config/omarchy/plugins/ and rescan
```

`Model.js` is plain JavaScript with no QML types, so the parsing and
classification rules are testable under `node` alone. It is cached by the
shell's engine independently of a component rescan — after editing it, run
`omarchy restart shell`, not just `rescanPlugins`.

## Licence

MIT. See [LICENSE](LICENSE).
