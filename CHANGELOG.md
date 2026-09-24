# Changelog

## 0.4.1 — 2026-09-24

- TAF change groups inherit the conditions they do not state, instead of being
  classified on their own tokens alone. AIM 7-1-29: with the exception of an FM
  group, "the new time period will include only those elements which are
  expected to change", and of a BECMG, "the omitted conditions are carried over
  from the previous time group". A BECMG carrying only a wind change therefore
  kept the visibility and sky in force before it, not nothing. Read literally it
  had no visibility, which classifies as no category at all, and the timeline
  painted those hours in the grey fallback — the OEJN 18Z–00Z band. The decoded
  group also led with "—" and could be picked as the "NOW" group with no
  category. FM groups still replace every element, as the AIM says they restate
  them. TEMPO/PROB overlays inherit the same way, from the prevailing group in
  force where they open; NSW counts as a stated value, so it clears the weather
  rather than inheriting it.

## 0.4.0 — 2026-09-24

- NOTAMs are gone from the plugin and its description. The `notamSource` and
  `notamLimit` settings, the credentials field, the autorouter client and the
  NOTAM section are removed, not switched off: the service no longer opens a
  socket to autorouter, and nothing in the manifest, the README or the panel
  mentions notices. The code stays in `Autorouter.js` with its tests, unwired,
  for the day a notice source that does not need a per-user account turns up.
- The `fir` setting remains, and now means SIGMET coverage alone.

## 0.3.2 — 2026-09-22

- Decoded reports are rendered as plain text unconditionally. `AutoText` on the
  decoded observation would have interpreted markup-shaped text as Qt rich text
  (including resource-bearing tags), and the decoded string is built from the
  remote response. Raised in the marketplace review.
- Cloud cover codes are validated against the known set instead of being carried
  through as-is, both when parsing the API response and when decoding it. An
  unknown `cover` value is now dropped rather than echoed, so endpoint-controlled
  text can no longer reach the display layer at all.

## 0.3.1 — 2026-09-22

- Enforce the response size cap while the body is being received, not after it
  has been buffered. Each request now pipes curl into `head -c 524288`, so an
  endpoint cannot make the shell hold an unbounded response. Raised in the
  marketplace review: the previous check ran on already-collected text, which
  was too late to protect memory. An oversized response now reports itself as
  such instead of looking like a network failure.

## 0.3.0 — 2026-09-22

- Search by place name as well as by ICAO code. A name is geocoded, the
  reporting fields around it are matched locally, and the candidates are listed
  with their names; picking one selects it and adds it to the quick list.
- The decoded TAF is spelled out group by group with the group in force marked
  **NOW**, instead of one running paragraph.
- TREND: the earlier observations of the station, folded out on click, with
  `historyCount` (0–6) deciding how many are kept.
- The METAR request now asks for the past three hours, so the trend needs no
  extra round trip.

## 0.2.0 — 2026-09-22

The popup now leads with both reports; the detail view is what is left over.

- TAF shown by default under the METAR, with its category timeline.
- A copy button on each report's header line — METAR and TAF — instead of one
  button at the bottom of the panel. `t` copies the TAF, next to the existing
  `c` for the METAR.
- Refresh moved to the top right of the header, beside the category pill.
- Details is now runways, SIGMET and NOTAM only, and closes on a second click;
  the separate Back button is gone.
- The WIND and CLOUD sections are removed: both were a second reading of the
  report text shown above them.
- Fixed requestRunways never being called, so runway components never appeared.

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
