# Changelog

## 0.1.0 — 2026-09-22

Initial release.

- Bar pill showing one letter per flight category (VFR / MVFR / IFR / LIFR),
  coloured with the aviation standard colours.
- Popup with the METAR, a TAF timeline and a quick-station list; a Details view
  adds the decoded reports, runway wind components, cloud layers and SIGMETs.
- Raw or decoded report text, metric or imperial display units, UTC or local
  times, all persisted in `shell.json`.
- Optional NOTAMs through the user's own autorouter.aero account. Off by
  default; no request is made until credentials are saved.
- Desktop notification when the flight category drops to a configured level.
