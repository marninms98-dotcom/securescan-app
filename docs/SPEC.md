# SecureScan — design spec (v1)

Owner: Marnin, SecureWorks WA (Perth). Water-damage restoration / make-safe work.
Device: iPhone 15 Pro Max (LiDAR, iOS 17+).

## What it is

A free replacement for the part of Polycam Marnin uses: walk a property with the
phone, get a clean **dimensioned floor plan** and a **3D model**, saved per job
with the street address. On top of that, a simple **restoration markup** layer so
the plan can show where the water came in, how far it spread, where the moisture
readings were taken, and which walls are being removed. The marked-up plan is
exported as an image and dropped into his report.

Guiding rule: **super simple.** One-handed, on site, no training. Few screens,
big buttons, sensible defaults, nothing that needs configuring before it works.

## Architecture — two parts, one contract

```
ios/   SwiftUI app. THIN. RoomPlan capture -> plan.json + model.usdz, job storage,
       GPS address, 3D viewer, hosts the editor in a WKWebView, share/export.
web/   The plan editor. ONE self-contained file: web/editor.html (vanilla JS + SVG,
       no network, no build step, no dependencies). Renders the floor plan,
       all markup tools, exports. Runs inside the app AND standalone in a browser.
```

Why split this way: the Swift cannot be compiled in the build environment, so
keep Swift small and conventional. All rendering/markup logic lives in the web
editor, which can be tested here in headless Chrome.

The iOS build copies `web/editor.html` into the app bundle as a resource.

## Contract 1 — plan document (JSON)

All lengths in **metres**. 2D plan coordinates: `[x, y]`, x to the right, y
**down** the page. From RoomPlan world space (y up): `planX = worldX`,
`planY = worldZ`. Angles in radians.

```jsonc
{
  "version": 1,
  "id": "UUID",
  "address": "30 Sample Cr, Testwood, WA",
  "jobRef": "",                       // optional free text (claim / job number)
  "createdAt": "2026-11-12T14:20:00Z",
  "updatedAt": "2026-11-12T14:20:00Z",
  "walls": [
    { "id": "w1", "a": [0, 0], "b": [3.45, 0], "height": 2.4 }
  ],
  "openings": [
    // type: "door" | "window" | "opening". a/b are the opening's ends in plan
    // coords (they lie on the wall line). wallId may be null if unknown.
    { "id": "o1", "type": "door", "wallId": "w1", "a": [0.4, 0], "b": [1.22, 0],
      "height": 2.04, "sill": 0 }
  ],
  "rooms": [
    // polygon: floor outline, closed implicitly. area optional (editor computes).
    { "id": "r1", "name": "Bedroom", "polygon": [[0,0],[3.45,0],[3.45,2.8],[0,2.8]] }
  ],
  "objects": [
    // furniture / fixtures footprint. category is RoomPlan's category name:
    // bed, sofa, chair, table, storage, refrigerator, stove, sink, toilet,
    // bathtub, washerDryer, dishwasher, oven, fireplace, television, stairs
    { "id": "ob1", "category": "bed", "center": [2.6, 1.0], "size": [1.5, 2.0],
      "rotation": 0 }
  ],
  "markup": {
    "sources":  [ { "id": "s1", "pos": [3.3, 3.4], "label": "Burst flexi hose" } ],
    "affected": [ { "id": "a1", "polygon": [[..],[..]], "label": "" } ],
    "removals": [
      // a stretch of one wall. t0/t1 are 0..1 along wall a->b.
      // item: "plasterboard" | "skirting" | "cabinetry" | "flooring" | "other"
      { "id": "x1", "wallId": "w1", "t0": 0.2, "t1": 0.8, "item": "plasterboard",
        "heightMm": 600, "note": "" }
    ],
    "readings": [
      // n: display number (1,2,3…). photo: JPEG data URL, downscaled to max
      // 1280px long edge, quality ~0.7, or null.
      { "id": "m1", "n": 1, "pos": [3.4, 3.0], "value": 24.5, "material": "skirting",
        "note": "", "photo": "data:image/jpeg;base64,...", "takenAt": "ISO8601" }
    ],
    "thresholds": { "damp": 15, "wet": 20 }   // % — editable, these are defaults
  }
}
```

Rules:
- The editor must tolerate missing optional fields and an absent `markup`
  (create it with empty arrays and default thresholds).
- The editor owns `markup`, room `name`, `address`, `jobRef`, `updatedAt`.
  The app owns geometry. The editor never changes wall/opening/object geometry.
- Reading status: `value < damp` = dry (green), `damp <= value < wet` = elevated
  (amber), `value >= wet` = wet (red). Thresholds are a display aid only; the
  defaults are NOT an industry standard and the UI must not claim they are.

## Contract 2 — host bridge (editor <-> app)

The editor detects the host with
`window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.host`.

Editor -> host: `window.webkit.messageHandlers.host.postMessage(msg)` where msg is:

| msg.type     | fields                                   | meaning |
|--------------|------------------------------------------|---------|
| `ready`      | —                                        | editor loaded; host replies by calling `SecureScan.load(plan)` |
| `save`       | `plan` (object)                          | persist the document (editor autosaves, debounced ~800 ms) |
| `export`     | `filename`, `mime`, `base64`             | host shows the iOS share sheet for this file |
| `close`      | —                                        | user tapped Done/back |

Host -> editor (via `evaluateJavaScript`):
- `window.SecureScan.load(planObject)` — load a document.
- `window.SecureScan.getPlan()` — returns the current document (object).

Standalone (no host): the editor loads a built-in sample plan (or the last
document from localStorage, wrapped in try/catch), `save` writes localStorage,
`export` triggers a normal browser download, and there is an "Open plan.json"
file picker.

Photos are taken entirely inside the editor with
`<input type="file" accept="image/*" capture="environment">` (works in WKWebView
with camera permission) and stored in the document as downscaled data URLs.

## Editor — look and behaviour

Reference images (READ THEM): `reference/polycam-plan-small.jpg`,
`reference/polycam-plan-large.png`. Match that drawing style closely:

- White sheet. Title "Floorplan", address line, "Approximately N m² total".
- Walls: thick solid slate (`#5b5f7b`-ish), ~0.12 m drawn thickness, mitred/clean
  joins at corners. Openings cut a gap in the wall: doors and plain openings show
  thin jamb ticks and a thin threshold line; windows show a thin double line in
  the gap.
- Rooms: very pale tinted fill, different tint per room; centred label with name
  and area ("Bedroom" / "9.7 m²").
- Furniture/fixtures: thin light-grey outline footprints (simple rectangles are
  fine; a couple of recognisable symbols like bed pillows, sink bowl, toilet are
  a nice touch but optional).
- Exterior dimension lines: thin black line offset outside the walls with end
  ticks and the length centred ("3.45 m", 2 decimals). One dimension per
  straight outer wall run; avoid overlapping labels. Do not dimension every
  internal wall by default.
- Scale bar "1 m" bottom-left.
- Works for non-rectangular plans and walls at any angle (see large reference).

Markup layer (must still look professional, like a consultant's drawing — muted,
consistent colours, a tidy legend, no clip-art):

1. **Water source** — a marker (blue droplet/target) with a short label
   ("Burst flexi hose"). Several allowed; usually one.
2. **Affected area** — the extent of water spread. Tap points to draw a polygon
   (and/or a quick "whole room" option by tapping a room). Rendered as
   semi-transparent blue with a diagonal hatch and a dashed edge; shows its area
   in m². If a source exists, draw subtle flow arrows from the source toward the
   far edges of the area to show direction of spread.
3. **Wall removal** — tap a wall, then drag (or tap two points) along it to mark
   the stretch. Choose item (plasterboard / skirting / cabinetry / flooring /
   other) and height in mm (default 600 for plasterboard, quick chips: 300, 600,
   1200, full height). Rendered as a bold red dashed line laid over that part of
   the wall with a small tag ("Remove 1.8 m · 600 mm"). Legend totals lineal
   metres and m² (length × height) per item.
4. **Moisture reading** — tap the spot, type the meter value (%), pick material
   (skirting / wall / floor / ceiling / cabinetry), optionally take a photo of the
   meter. Rendered as a numbered circle coloured by status. Numbers match the
   readings table.

Legend: drawn on the sheet, only listing what is actually used.

Interaction: touch first. Bottom toolbar with 5 big buttons: Select/Move, Source,
Area, Removal, Reading. Pinch zoom + two-finger pan on the sheet. Tap an existing
item to edit or delete it. Undo. Tap a room label to rename the room (offer
common names: Bedroom, Bathroom, Ensuite, Laundry, Kitchen, Living, Dining,
Hallway, WC, Garage, Robe, Study). Tap the address to edit it. Autosave.

Layers toggle: Plan only / Plan + markup, plus individual on/off for dimensions,
furniture, readings, removals, affected area.

Export (one "Export" button, a short sheet of choices):
- **Floor plan PNG** — clean plan, no markup (the Polycam equivalent).
- **Marked-up plan PNG** — plan + markup + legend.
- **Moisture & scope sheet PDF/print view** — page 1 marked-up plan with legend;
  then readings table (No., location/room, material, value, status, note) with
  photo thumbnails; then removal schedule (wall/room, item, length, height, m²)
  with totals. Header: SecureWorks WA, address, job ref, date. Plain and clean.
  Standalone: open the print view and call `window.print()`. Hosted: send the
  print-view HTML as an `export` with mime `text/html` and filename ending
  `.html`; the app converts it to PDF.
- PNGs at >= 2000 px on the long edge, white background.

## iOS app — screens

1. **Jobs** (home): list of saved jobs — address, date, thumbnail, room count.
   Big "New scan" button. Swipe to delete (with confirm). Search by address.
2. **New scan**: address pre-filled from GPS reverse geocode (editable, never
   blocks if location is denied), optional job ref. "Start scanning".
3. **Scan**: RoomPlan `RoomCaptureView` full screen with coaching. Buttons:
   "Next room" (finish this room, keep the AR session running so rooms stay
   aligned, continue into the next) and "Finish". Multi-room merge with
   `StructureBuilder` -> `CapturedStructure`.
4. **Job**: three tabs — **Plan** (the editor), **3D** (USDZ viewer you can orbit
   and walk around, with AR Quick Look), **Files** (share plan.json / model.usdz,
   "Add rooms" to continue scanning into the same job is a stretch goal).

Storage: `Documents/Jobs/<uuid>/` containing `plan.json`, `model.usdz`,
`rooms/<n>.json` (the encoded `CapturedRoom` for each room, so plans can be
regenerated later), `thumb.png`. Expose in the Files app
(`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).

No accounts, no network calls, no analytics, no third-party packages.

---

# ADDENDUM v1.1 — moisture capture during the scan + wall elevations

Owner request: a simple, intuitive way to capture where the moisture is (and the
level) while doing the LiDAR capture, producing something he can put in the
insurer report that nobody else provides. Keep it small.

## The idea: one-tap AR readings -> automatic plan pins + wall elevation maps

On site he holds the moisture meter against the wall/skirting, points the phone
at it, taps **Log reading**. In that one tap the app records where in 3D space
the reading was taken (so: which wall, how far along it, how high above the
floor) and grabs the camera frame as the photo. He types the meter value. Later
those readings appear automatically on the floor plan AND on a per-wall
**elevation drawing** that shows readings at their true heights, colour coded,
with the planned removal extent drawn over it. That elevation is the
differentiator: it shows how far up the wall the moisture has travelled and
justifies the cut height.

## Contract 1 changes (additive, all optional)

Each item in `markup.readings` may also carry:

```jsonc
{
  "height": 0.15,      // metres above floor level; null/absent if unknown
  "wallId": "w3",      // wall the reading sits on; null/absent if on floor/unknown
  "wallT": 0.42,       // 0..1 along that wall a->b
  "reference": false,  // true = dry control reading taken in an unaffected area
  "source": "ar"       // "ar" (logged during scan) | "manual" (added in editor)
}
```

`markup.meter` (string, optional): the meter used, e.g. "Ozito digital moisture
meter". Editable in the editor, printed on the sheet.

Existing documents without these fields must keep working. `pos` is still always
present (for a wall reading it is the point on the wall line).

## iOS — scan screen

- A **Log reading** button on the scan screen, usable while scanning a room and
  between rooms (the AR session stays alive). A small crosshair in the centre of
  the camera view shows what will be recorded.
- On tap, from the room capture session's ARSession current frame: store the
  camera transform (position + forward direction), a raycast hit from the screen
  centre if one is available (prefer existing plane geometry, fall back to
  estimated plane), and a JPEG of the captured frame (correctly oriented for
  portrait, downscaled to max 1280 px long edge, quality ~0.7).
- Then a compact sheet: big number pad for the value (%), material chips
  (skirting / wall / floor / ceiling / cabinetry), "Reference (dry) reading"
  toggle, Save. Show a brief confirmation ("Reading 3 logged · 24%") and a
  running count. It must take seconds, not interrupt the scan, and never lose a
  reading if the scan later fails.
- Persist pending readings with their raw world-space data in the job folder
  (`readings-raw.json`) so plans can be regenerated.
- In PlanBuilder (pure maths, unit tested): transform each reading into plan
  space with the SAME rotation/translation used for the walls. Resolve the point:
  intersect the camera ray (in plan, 2D) with the walls and take the nearest hit
  within 3 m in front of the camera; if none, use the raycast hit; if neither,
  use the camera position. If the resolved point is within 0.3 m of a wall, snap
  onto the wall line and set `wallId` / `wallT`. `height` = hit world Y minus
  floor Y (floor Y = the lowest floor surface / wall base), clamped to
  0..wall height. Material "floor" readings are not snapped to walls.
  "Regenerate plan" must keep manual readings and rebuild AR ones from raw.

## iOS — 3D tab shows the readings

- The 3D tab renders model.usdz in a SceneKit view (SCNView, allowsCameraControl,
  sensible default lighting and camera framing) instead of only Quick Look, and
  adds a marker for every reading that has a 3D position: a small sphere coloured
  by status (green / amber / red, grey for reference) with a billboarded label
  "3 · 24%". Marker positions come from readings-raw.json world coordinates (the
  USDZ is exported in the same world space). A toggle hides/shows markers.
- "Save image" button: snapshot of the current 3D view to the share sheet, so a
  3D moisture view can go in the report. Keep an "Open in AR Quick Look" button.
- Live rendering of pins inside the RoomPlan camera view during scanning is NOT
  required (RoomCaptureView does not accept custom content); the confirmation
  toast and running count are enough.

## Editor

- AR readings show on the plan like any other reading. Reference readings get a
  distinct look (hollow/grey ring, "R" suffix) and appear in the legend as
  "Reference (dry) reading".
- Reading sheet gains: "Height above floor" quick chips when the reading is on a
  wall (Skirting 50 mm / 300 / 600 / 1200 / custom) and the Reference toggle.
  A manual reading tapped within 0.3 m of a wall snaps to it (sets wallId/wallT).
- **Wall elevations**: for every wall that has at least one reading with a
  height, or a removal, draw an elevation: wall length x wall height to scale,
  floor line, that wall's openings (door/window outlines at their position, sill
  and height), light height guides every 300 mm with labels, readings as numbered
  status-coloured circles at (wallT x length, height) with the value beside them,
  and each removal on that wall as a red hatched band from the floor to its
  height between t0..t1 with a dimension. Title e.g. "Elevation A — Laundry
  (3.45 m)". Walls with elevations get a small letter tag (A, B, C…) on the plan
  so the two drawings cross-reference.
- Subtle "wet wall" highlight on the plan: a thin amber/red band along the room
  side of a wall for 0.5 m either side of each elevated/wet wall reading. Legend
  entry "Elevated / wet reading zone (indicative)". Do NOT interpolate moisture
  between distant readings or imply measurement where none was taken.
- Exports: add **Wall elevations PNG**; include the elevations in the Moisture &
  scope sheet after the plan. The sheet's readings table gains Height and a
  Reference marker, and prints the meter name plus a one-line note: "Readings
  are as displayed by the meter and are comparative; reference readings are
  taken from unaffected areas of the same material."

---

# ADDENDUM v1.2 — tape marks and photo notes (from the owner's real site photos)

See `reference/wall-blue-tape-marks.jpg`, `reference/reading-with-tape-measure.jpg`,
`reference/inspection-opening.jpg`. On site he (a) holds a tape measure up the
wall so the photo shows the reading's height, (b) sticks small squares of blue
tape on the wall tracing the upper edge of the moisture across the wall, and
(c) takes photos that are not readings: room overviews, inspection openings.

## Contract 1 change (additive, optional)

Each item in `markup.readings` may carry `"kind"`:

- `"reading"` (default when absent) — a meter value, as before.
- `"boundary"` — a tape mark on the moisture line. `value` is null. Has
  pos / wallId / wallT / height like a reading. Photo optional.
- `"photo"` — a pinned photo note. `value` is null; `note` is the caption
  (e.g. "Inspection opening — pipework in brickwork"). Photo expected.

Numbering: readings are numbered 1,2,3… (`n`) among kind "reading" only.
Photo notes are numbered separately and displayed "P1, P2…". Boundary marks are
not numbered. Old documents (no `kind`) behave exactly as before.

## iOS

The Log sheet opens with three large segment choices: **Reading** (default) /
**Tape mark** / **Photo**. Tape mark: one tap, no number, saves immediately
(optionally keeps the frame as its photo). Photo: caption field with quick
chips (Overview, Inspection opening, Damage, Source, Other), Save. Same raw
capture (camera transform, raycast hit, frame JPEG) for all three; PlanBuilder
resolves position/wall/height identically and sets `kind`. In the 3D tab,
boundary marks are small blue cubes and photo notes small grey markers "P1".

## Editor

- Tool sheet for "Reading" gains the same three-way choice, so marks and photo
  notes can be added or fixed by hand.
- Plan: boundary marks = small blue squares on the wall (like his tape); photo
  notes = small numbered camera glyph "P1". Legend entries only when used.
- Elevation: boundary marks drawn as small blue squares at (wallT x length,
  height). When a wall has 2+ boundary marks, connect them in wallT order with a
  dashed blue line labelled "Moisture line (as marked on site)" and lightly tint
  the wall area below the line between the first and last mark. Do not
  extrapolate the line beyond the outermost marks. A wall with boundary marks
  gets an elevation even if it has no readings.
- Moisture & scope sheet: readings table lists kind "reading" only; add a
  "Site photos" section — a tidy grid of photo notes (P-number, caption,
  room/wall) — after the removal schedule. Readings' own photos stay as
  thumbnails in the readings table.
- Update the samples (embedded + sample-plan.json): add 4 boundary marks
  stepping down along one bedroom wall (heights ~1.5, 1.3, 1.1, 0.9 m) and 2
  photo notes (no image data). Extend tests/screenshots accordingly.

---

# ADDENDUM v1.3 — import a Polycam floor-plan model (.glb)

The owner supplied a real Polycam "floor plan" export: `private-fixtures/polycam-example.glb`
(a client's house — never commit it, never embed it in samples or published pages).
It is a parametric model, not a photo mesh: one glTF 2.0 binary, no node
transforms (geometry is baked into vertex positions, metres, Y up), with a
named hierarchy:

    Polycam > Floor_1 > Walls (Wall_N boxes 0.1 m thick, Joint_N corner posts)
                      > Openings > Doors (Door_N flat quads), Windows (Window_N)
                      > Floors (Floor_<Room_Name> polygons, e.g. Floor_Living_Room, Floor_Other_2)
                      > Ceilings
                      > Objects > Appliances / Fixtures / Furniture (stove_0, sofa_rect_1, sink_0 …)

Feature: the editor gets **Import 3D model (.glb)** (standalone file picker, and
callable by the host). A pure module `web/glb-import.js` exposes
`SecureScanGLB.toPlan(arrayBuffer, {address}) -> plan document (Contract 1)`.
This lets him mark up scans he already has, and gives real-house test data.
It is inlined into editor.html at integration time.

---

# ADDENDUM v1.4 — source dot, moisture line drawing, voice notes, job pack

Owner's direction (13 Nov): one hand holds the phone scanning, the other holds
the meter. He taps to pin readings, points at the leak source and taps to mark
it, takes photos without leaving the app, and talks through the job out loud.
Everything is time-stamped so the spoken notes line up with what he was doing.
One **Export** gives a "job pack" he can hand to an AI to write the report.
Evidence from the first simulator run is in `ci-screenshots/` (the 3D tab is
visibly broken there — see iOS section).

## Naming

- UI label for kind `"boundary"` is now **Moisture line** (not "Tape mark");
  tape is optional. The data value stays `"boundary"`.
- Never label anything "for Claude" / "for AI". The pack item is "Job pack".

## Contract 1 changes (additive, optional)

- `markup.sources[]` items may also carry `height`, `wallId`, `wallT`,
  `source` ("ar" | "manual") and `takenAt` (ISO 8601), exactly like readings.
- `readings[].takenAt` is always written for new items (already in the schema).
- New `markup.notes` — spoken or typed site notes, in time order:

```jsonc
"notes": [
  { "id": "n1",
    "t": "2026-11-13T01:02:03Z",      // when this was said (start)
    "end": "2026-11-13T01:02:09Z",    // optional
    "text": "Skirting here is reading 38 percent, we'll rip up about 4 metres.",
    "source": "voice",                // "voice" | "typed"
    "audio": "audio/001.m4a",         // optional: file in the job folder
    "audioOffset": 12.4,              // optional: seconds into that file
    "edited": false }                 // true once the user corrected the text
]
```

The app owns creating voice notes; the editor may edit `text` (sets
`edited: true`), delete notes and add typed notes. Old documents without
`notes` behave as before. Unknown fields still round-trip.

## Contract 2 changes

- Editor -> host new message: `{ type: "exportPack", files: [ { filename, mime, base64 } ] }`.
  The editor sends everything it can generate (see Editor below). The host
  writes those files into a temporary folder, adds the job's own files
  (`plan.json`, `audio/*.m4a`, `model.usdz` when present), zips the folder and
  presents the share sheet with `<address>-job-pack.zip`.
- No other bridge changes. `ready/save/export/close` are unchanged.

## Editor

1. **Draw the moisture line on a wall.** In the Elevations view a "Moisture
   line" tool: tap points on a wall's elevation to add `kind: "boundary"` marks
   at that wallT/height (source "manual"); drag a point to move it; tap a point
   to delete it. Same rendering as before (points joined in wallT order, tint
   below, never extrapolated). It must feel like drawing on the wall: big hit
   areas, immediate line preview. On the plan the tool sheet says "Moisture
   line" instead of "Tape mark".
2. **Source** items logged in AR (with wallId/height) render like manual ones;
   when a source has a height on a wall it also appears on that wall's elevation
   as the source glyph.
3. **Site notes.** A "Notes" view (third segment beside Plan / Elevations, or a
   panel — designer's choice, keep it simple): notes in time order, interleaved
   with the timestamped events (readings, moisture-line marks, photos, sources)
   as a single timeline, so it reads as the story of the inspection. Tap a note
   to correct its text; add a typed note; delete. Spoken notes show a small mic
   glyph and the time.
4. **Job summary (Markdown).** `SecureScan.summaryMarkdown()` returns one
   Markdown document that an AI (or a person) can write the report from, with
   no other context: job header (address, job ref, date, meter, thresholds),
   rooms with area and each wall's length, openings, water source(s), affected
   area(s) with m², the full timeline in time order (spoken notes verbatim,
   readings with number / room / wall tag / material / height / value / status
   / reference, moisture-line points, photo captions with file names), a
   readings table, the removal schedule with totals, and a list of the files in
   the pack. Plain, factual, no invented content.
5. **Export sheet**: add **Job pack** first in the list.
   - Hosted: post `exportPack` with files: `summary.md`, `floor-plan.png`,
     `marked-up-plan.png`, `wall-elevations.png` (when there are any),
     `schedule.csv`, `moisture-scope-sheet.html`, and every embedded photo as
     `photos/reading-<n>.jpg` / `photos/P<n>.jpg` / `photos/source-<n>.jpg`
     (decoded from the data URLs; names must match the ones used in summary.md).
   - Standalone / published page: build the same pack as a single .zip in the
     browser with a small dependency-free store-only ZIP writer (correct CRC-32,
     UTF-8 names) and deliver it like any other export (the published page's
     save prompt accepts .zip).
6. The Moisture & scope sheet gains a "Site notes" section (time, text) after
   the readings table when notes exist.

## iOS

1. **Fix the 3D tab** (see `ci-screenshots/03-demo-3d.png`: camera inside the
   model, black faces, no visible markers). Frame the whole model from an
   elevated three-quarter view with margin, sensible near/far planes, double-
   sided or correctly wound wall geometry, even lighting, markers visible and
   legible. Draw each wall's moisture line as a coloured polyline with a light
   translucent fill below it, and sources as a blue marker. Verify with the
   simulator screenshot loop.
2. **Log sheet** choices: Reading (default) / Moisture line / Photo / **Source**.
   Source = one tap + optional short label (chips: Burst pipe, Flexi hose, Roof
   leak, Shower, Appliance, Unknown) -> `markup.sources` via PlanBuilder with the
   same position resolution as readings.
3. **Voice notes.** A clear record toggle on the scan screen (and a "Record
   note" button on the job screen for notes after the scan). Audio only, no
   video: AAC mono to `audio/NNN.m4a`, recording start time stored. Must coexist
   with the running RoomPlan/ARKit session and survive Next room. When a
   recording stops, transcribe it on the device (Apple Speech framework, on-
   device recognition, en-AU; verify the right API for long recordings on
   current iOS against Apple's docs) into time-stamped segments, group into
   notes at natural pauses, and merge into plan.json `markup.notes` with
   absolute times. If transcription is unavailable or fails, keep the audio,
   add a note with empty text marked as not transcribed, and offer "Transcribe
   again" on the Files tab. Never lose audio. Info.plist usage strings for
   microphone and speech recognition. A recording indicator with elapsed time.
4. **Job pack**: handle `exportPack` per Contract 2 (zip natively without third-
   party packages, e.g. NSFileCoordinator with `.forUploading` on a folder) and
   share.
5. Demo job: include a handful of notes, one AR source and a drawn moisture
   line so the simulator screenshots exercise all of it.

---

# ADDENDUM v1.5 — the report PDF ("Assessment report")

Owner's direction (13 Nov): the deliverable to the insurer / builder is a PDF.
His real problem: "it's hard to get grounded and hard to know how photos link
with the spaces in the room." He wants the PDF to tie every photo and reading
to its place on the plan, with light interactivity (click a pin, land on the
photo), and to look beautiful: "the more beautiful and good quality we can
present the actual report, the better it's going to look for us for the
insurance." Do not clutter it.

Decisions already made with him:
- PDF only (no hosted HTML). Internal links (pin -> evidence card -> back to
  plan) are the interactivity. NO pop-ups, JavaScript, hover effects, embedded
  media or anything that only works in Adobe Acrobat. The report must read
  perfectly when printed on paper: every link is also a visible number.
- Every evidence card carries its own small **locator map** so the reader never
  has to flip back to find where a photo was taken.

This replaces the "Moisture & scope sheet" as the main export (keep the item
name "Assessment report (PDF)" first in the Export sheet, after Job pack).

## Contract 1 changes (additive, optional)

- AR-logged readings/sources may carry `cam: [x, y]` — camera position in plan
  coordinates when the item was captured. Used to draw "taken from here, looking
  this way" on locator maps (a small eye/camera dot at `cam` and a soft view
  cone toward `pos`). Absent for manual items.
- New `markup.report` (all optional, editor-owned, edited in a "Report details"
  sheet): `{ "title": "Water Damage Assessment", "preparedBy": "", "preparedFor": "",
  "claimRef": "", "summary": "", "recommendations": "", "include": { "roomPages": true,
  "notes": true, "readingsTable": true, "method": true } }`.
  `summary` and `recommendations` are free text he types or pastes (e.g. written
  by an AI from the job pack). When empty, those blocks are simply omitted —
  never fill them with generated prose.
- New `markup.brand` (optional): `{ "name": "SecureWorks WA", "tagline": "",
  "accent": "#1f4e79", "logo": "data:image/png;base64,…", "contact": "" }`.
  Defaults: name "SecureWorks WA", a restrained deep-blue accent, no logo (a
  clean text wordmark is used). The logo can be picked from a file in the
  Report details sheet and is remembered for future jobs (localStorage in the
  browser; the host persists it — see iOS).

## Page design (the look matters as much as the content)

Fixed pages, A4 portrait, each page an explicit box of exactly 595 x 842 CSS px
(1 px = 1 pt) so pagination is fully controlled and identical everywhere.
Consultant-grade and calm: generous margins (about 42 px), one accent colour,
slate text on white, thin hairline rules, a consistent small header (brand
wordmark/logo left, report title right) and footer (address · job ref · "Page
x of y"), consistent type scale (system fonts; body about 9.5 px, captions 8 px,
headings 14/11 px, cover title large). No boxes-inside-boxes, no drop shadows,
no gradients, no clip-art. Status colours (dry green / elevated amber / wet red /
reference grey / moisture-line blue / removal red) are used sparingly and
identically to the plan. Photos have a hairline border and square corners or a
2 px radius. Nothing may overflow a page box; long text shrinks or continues on
a new page.

Page sequence (omit a page type when it has nothing to show):

1. **Cover.** Logo/wordmark, report title, property address (large), claim /
   job ref, inspection date, prepared by / prepared for. A hero image: the
   clean floor plan with the affected area tinted. A key-facts strip of 3–4
   figures computed from the data only: water source (label + room), affected
   area (m², number of rooms), readings (count, highest value and where),
   removal (lineal m and m²).
2. **Summary.** "What was found" as a short factual list generated strictly
   from the document (source and its location; rooms affected with areas;
   highest reading per affected room; reference reading value(s); highest
   moisture-line point per wall; removal items with totals). Then the user's
   own `summary` and `recommendations` text when present. No invented causes,
   opinions or recommendations.
3. **Marked-up plan** (full page): numbered pins only — details live on the
   cards. Every pin is a link to its card or table row. Legend.
4. **Room pages** (optional): one per room that has items — an enlarged crop of
   that room from the plan with its pins, the room's dimensions and area, and a
   compact index of its items (number, type, value, page) with links.
5. **Wall elevations**: two per page, with the moisture line, readings at
   height and removal zones, as already drawn; pins link to cards.
6. **Evidence cards** — the heart of the report. One card per item that has a
   photo (readings with a photo, photo notes, sources with a photo), two cards
   per page. Each card: the photo (large, uncropped aspect preserved); a
   **locator map** beside it (crop of the plan around the room with only this
   pin highlighted, other pins faint, plus the camera dot + view cone when `cam`
   is known, and the wall-elevation letter when it has one); a title line
   ("Reading 3 · Laundry · Wall A"); the value as a status-coloured badge;
   height above floor; material; time taken; the caption/note; and the spoken
   note said nearest to that moment when one exists (the note whose time range
   contains the item's time, else the closest within 20 s), in quotes with a
   small mic glyph. A "Back to plan" link. Cards are ordered by room, then by
   number.
7. **Readings table** (optional): every reading (with or without photo): no.,
   room, wall, material, height, value, status, reference, page of its card.
   Rows link to cards.
8. **Removal schedule** with totals per item.
9. **Site notes** (optional): the timeline of spoken/typed notes.
10. **Method and limitations**: meter name; the comparative-readings sentence;
    the thresholds statement (display aid, not an industry standard);
    dimensions are from a LiDAR scan and are approximate; date generated.

## Editor

- A **Report** view (fourth segment, or reached from Export — keep navigation
  simple) showing the real pages as a scrollable preview at screen width, so he
  can check the report before exporting. A "Report details" sheet edits
  `markup.report` and `markup.brand` (logo file picker, accent colour swatches).
- `SecureScan.reportHTML()` -> a complete self-contained HTML document of the
  page boxes (inline CSS, data-URL images, `@page { size: 595px 842px; margin: 0 }`
  so browser print-to-PDF yields exactly one PDF page per box).
- `SecureScan.reportLinks()` -> `{ pages: N, pageSize: [595, 842], links: [ { page, rect: [x, y, w, h], targetPage, targetY } ] }`
  in page-box pixel coordinates (origin top-left), computed from the laid-out
  DOM. This is how the app makes the PDF clickable without depending on how
  WebKit handles anchors. The HTML also carries ordinary `<a href="#id">`
  anchors so Chrome/Safari print-to-PDF produce working links.
- Export sheet: "Assessment report (PDF)". Hosted: post
  `{ type: "exportReport", html, links }` (links = the reportLinks object).
  Standalone browser: open the print view (the page boxes) and call
  `window.print()`. Published page: save the self-contained HTML (printing is
  blocked there), as today.
- The job pack includes `assessment-report.html` (and the app adds the PDF).
- Tests: render the sample and the large house; assert no page box overflows
  (scrollHeight/Width equal the box), every pin on the plan page has exactly one
  link with a target that exists, every photo item has a card, locator maps
  highlight the right pin, numbers in the summary equal the legend/schedule
  totals; produce a real PDF with headless Chrome (page.pdf) into web/test/out/
  and check its page count equals the number of page boxes; save PNGs of every
  page type and LOOK at them — iterate on spacing, alignment and type until it
  looks like a document a consultancy would be proud to send. Use the owner's
  real site photos in reference/ as sample photos in a test-only document so
  the cards are judged with real imagery (do not embed them in the shipped
  sample).

## iOS

- Handle `exportReport`: load `html` in an off-screen WKWebView exactly 595 px
  wide; when loaded (and images decoded), create one PDF page per page box with
  `WKWebView.createPDF(configuration:)` using `rect` = that box (verify the API
  and that output is vector text), merge with PDFKit into one A4 document, then
  add PDFKit link annotations from `links` (PDFAnnotation subtype link with a
  PDFActionGoTo / PDFDestination; note PDF coordinates have a bottom-left
  origin). Write `<address>-assessment-report.pdf`, share it, and include it in
  the job pack. Show progress; never block the main thread on large documents.
- Persist `markup.brand` (logo, accent, name) app-wide so new jobs start with
  it; expose nothing else new.
- Verification without a device: launching with `SECURESCAN_EXPORT_REPORT=1`
  generates the demo job's report automatically and writes the PDF plus a small
  `report-check.txt` (page count, link-annotation count, page size, file size)
  into the app's Documents folder; the CI simulator step copies both out
  (`xcrun simctl get_app_container … data`) into `ci-screenshots/` so the real
  PDF produced by WebKit + PDFKit can be inspected.

---

# ADDENDUM v1.6 — return visits, drying progress, equipment, scope of works

Owner's direction (13 Nov, after seeing the report): "we're capturing a picture
of what's happening on site". The same job is visited several times. On each
return the trade re-measures moisture at the SAME spots, so the report can show
clearly where moisture is reducing and where it is not. Drying equipment
(dehumidifiers, air movers) is placed on the map. Reports follow the job:
first visit report, monitoring visit reports, final report and sign-off. The
first report should double as the scope of works / quote: what we propose to
do and where, broken down into a quote table he can send.

## Contract 1 changes (additive, optional — old documents must keep working)

```jsonc
"markup": {
  "visits": [
    { "id": "v1", "n": 1, "type": "initial",    "label": "Initial assessment", "date": "2026-11-12", "by": "" },
    { "id": "v2", "n": 2, "type": "monitoring", "label": "Monitoring visit",   "date": "2026-11-19", "by": "" }
    // type: "initial" | "monitoring" | "final"
  ],
  "currentVisit": "v2",          // the visit being recorded; absent => the last visit, or an implicit v1
  "target": { "mode": "value", "value": 15 },   // drying goal for display: {mode:"value",value} or {mode:"reference",margin:2}
                                                // default: value = thresholds.damp. A display aid, not a standard.
  "equipment": [
    { "id": "e1", "type": "airMover",            // "airMover" | "dehumidifier" | "airScrubber" | "heater" | "other"
      "label": "AM-03", "pos": [2.1, 3.4], "placed": "v1", "removed": null,
      "placedAt": "ISO8601", "removedAt": null, "note": "" }
  ],
  "scope": {
    "items": [
      // auto: a stable key when the line is generated from the markup, else null for manual lines.
      { "id": "sc1", "auto": "equipment:airMover", "desc": "Air mover hire", "qty": 2, "unit": "ea", "days": 7,
        "rate": null, "include": true, "note": "" },
      { "id": "sc2", "auto": null, "desc": "Scrape back and seal wall, laundry", "qty": 1, "unit": "item", "rate": 180 }
    ],
    "gst": 0.1, "validDays": 30, "terms": ""
  }
}
```

- Every item may carry `"visit": "<visit id>"` = the visit it was created in
  (readings, moisture-line points, photo notes, sources, removals, notes).
  Absent => v1.
- A reading (kind "reading") is a persistent **point**. Re-measurements are
  stored in `history: [ { "visit": "v2", "value": 21.5, "takenAt": "…", "photo": "…", "note": "" } ]`
  with one entry per visit (including the first). `history` is authoritative
  when present; the top-level `value` / `takenAt` / `photo` / `note` are kept
  as a mirror of the latest entry so older readers still work. A document with
  no `history` means: the top-level value is the visit-1 entry.
- Moisture-line points belong to their `visit`; a wall can therefore have one
  moisture line per visit.
- Removals may carry `"status": "proposed" | "done"` (default proposed) and
  `visit` / `doneVisit`.
- An app-wide **rate card** (unit rates by auto key and saved manual lines) is
  remembered like the brand; rates live in the document once applied so a quote
  never changes retroactively.

## Editor

1. **Visits.** A visit chip in the top area ("Visit 2 · 19 Nov") opens a sheet:
   list of visits, "Start new visit" (type, label, date today, by), switch the
   visit being viewed. Viewing an earlier visit shows the job as it was then
   (that visit's values, moisture line and equipment on site) read-only-ish
   with a clear "Viewing visit 1" banner.
2. **Re-measure flow** (the core of a return visit; must be very fast for a
   trade with a meter in one hand): in a monitoring/final visit every point
   shows its previous value faded until re-measured. Tap a point (or "Re-measure
   all") -> a sheet showing where it is in plain words ("Laundry · Wall A ·
   1.20 m from the left corner as you face the wall · 300 mm above the floor"),
   the first-visit photo of that spot if there is one (the best locator), the
   previous values, a big number input, optional new photo -> Save -> auto-advance
   to the next un-measured point in walking order (by room, then along the
   walls). A progress line "5 of 12 re-measured". New points can still be added.
3. **Trend on the plan.** Pins are coloured by the viewed visit's value and get
   a small trend mark versus the previous visit: down (drying), level (within
   1 point), up (rising). A pin at or below the drying goal gets a tick.
   Legend entries only when used. Do not interpolate or predict.
4. **Moisture line per visit** on elevations: current visit solid, earlier
   visits fainter with the date, so a receding line is visible.
5. **Equipment.** A tool to place equipment on the plan (type, optional
   label/asset number), drag to move, mark as removed in a later visit. Simple
   consistent plan symbols (not clip-art) with a legend that counts each type
   on site for the viewed visit. Fit the extra tool into the bottom toolbar
   without breaking the 44 px targets at 402 px width (regroup tools if needed).
6. **Scope of works.** A "Scope & quote" sheet/view: lines generated from the
   markup (equipment by type with quantity and days on site or a planned
   number of days; removals by item with lm / m²; affected area m² as a
   treatment/drying line; monitoring visits) plus manual lines he adds
   ("Scrape back wall here", "Mould treatment"). He can edit descriptions,
   quantities, exclude lines, and enter unit rates. Auto lines update their
   quantity from the markup unless he has overridden them (show a small
   "edited" mark and a way to reset). With rates: totals ex GST, GST, total inc
   GST. Without any rates: a quantities-only scope of works — never print $0 or
   empty price columns. Currency AUD.
7. **Reports by visit** (extends v1.5; same page design language):
   - *Initial assessment* (visit type initial): as v1.5, plus a **Drying plan**
     page (plan with equipment positions and counts) and a **Proposed scope of
     works** page (and a **Quotation** table when rates exist: reference, date,
     validity, lines, subtotal, GST, total, terms).
   - *Monitoring report* (visit n): cover with drying-progress key facts (points
     drying / unchanged / rising, points at the goal, days since first visit);
     plan with trend pins; a **Drying progress** page — a table of points (rows)
     by visits (columns) with status-coloured cells and the change since the
     previous visit, plus a small line chart per point or per room showing
     value over visits with the goal line (label axes; dates on x); elevations
     with the moisture line per visit; evidence cards for this visit's photos,
     showing the first-visit photo of the same point small beside it when both
     exist; equipment on site and days running.
   - *Final report*: the same progress pages over all visits, a factual
     completion statement generated only from the data ("11 of 12 points were at
     or below the drying goal of 15% on 3 Dec 2026; point 6 read 17%.
     Reference reading 9.5%."), equipment removed dates, work completed
     (removals marked done), and a sign-off block (prepared by / client or
     builder name, signature and date lines). Do not call it a certificate and
     do not claim compliance with any standard.
   The report type follows the viewed visit's type and can be overridden in
   Report details.
8. `summaryMarkdown`, the Schedule CSV and the job pack include visits,
   per-point history, equipment and scope.
9. Samples: extend the small sample to three visits (initial, monitoring,
   final) with believable drying curves — most points drying, one stalling —
   equipment placed on visit 1 and removed on visit 3, and a scope with a mix
   of auto and manual lines; keep a single-visit document in the tests to prove
   nothing changes for single-visit jobs.

## iOS (small)

- Log sheet gains **Equipment** (type chips, optional label) -> `markup.equipment`
  with `pos` from the same position resolution (floor point under the crosshair),
  `placed` = current visit.
- Persist the rate card app-wide alongside the brand.

## Planned next, NOT in this round: finding the same spots through the camera

On a return visit the trade should see the saved points floating on the walls
through the phone. Planned approach: a quick re-scan of the room with RoomPlan,
rigid 2D alignment of the new walls to the saved plan (rooms do not change
shape), then an AR view on the same AR session that draws each saved point at
its wall position and height; tapping Log near a marker selects that point for
re-measurement. This depends on the scan flow being proven on a real device
first, and always falls back to the plan-based re-measure flow above.

---

# ADDENDUM v1.7 — visual experiments: unfolded room and isometric cutaway

Owner (13 Nov): the floor plan is nice, but "we could take it to another level
in terms of how we visualise the moisture readings on the different walls and
propose what we're going to demo, lift up, remove or strip back" — the capture
is AR-quality (every item has a wall, a position along it and a height), so how
do we display that quality in a PDF? "Is it worth doing a 3D mock-up?"

Position taken: a PDF is flat and cannot be orbited (3D PDFs only work in
desktop Acrobat), so 3D must be rendered into designed, fixed views — vector,
drawn from the data, never screenshots. Two new drawing types, both built from
the existing document (no new capture needed), both as report pages and as
PNG/SVG exports:

## A. Unfolded room ("room net") — the proposed new centrepiece

For each room that has wall items: the room's floor polygon drawn in plan in
the centre, and every wall of that room folded outward flat around it, hinged
on its floor edge, to scale (wall length x wall height). Read like a box
unfolded: one drawing shows which wall, where along it and how high.
- On each wall face: openings (doors/windows at true sill/height), readings as
  numbered status pins at true position and height (viewed visit's value, trend
  mark), the moisture line with its tint below — and because adjacent walls
  share a corner, the line reads continuously around the room — sources,
  removal zones as red hatched bands with height and length dimensions and a
  short tag ("Remove plasterboard to 600"), and small photo markers where a
  photo was taken of that wall (optional: tiny photo thumbnails pinned to the
  spot, as a variant to judge).
- On the floor: affected area hatch, floor readings, equipment, flooring
  removals, the camera/view cones are NOT shown here (too busy).
- Wall letters (A, B, C…) match the elevations and the plan. Height ticks at
  300/600/1200 on one wall edge. A small key plan in the corner shows which room
  this is in the house. Scale bar. Legend only for what is used.
- Must work for non-rectangular rooms (L-shapes, angled walls): each wall folds
  out perpendicular to its own floor edge; where folded walls would overlap at
  a concave corner, offset the shorter wall outward on a leader line or split
  the room into two nets — pick one approach, make it robust, and test it on
  the L-shaped hallway and on the large house's angled rooms.
- This drawing doubles as the **scope drawing**: a variant "Proposed works"
  that mutes moisture data and emphasises removals / strip-back / lift areas
  with quantities, to sit beside the Proposed scope of works table.

## B. Isometric cutaway ("dollhouse") — one orientation image per report

A vector isometric (or dimetric) view of the affected rooms or the whole floor:
floor polygons, walls extruded to their height with the two nearest walls of
each room drawn low/ghosted so interiors are visible, openings cut out, wet
zones (below the moisture line) and removal zones painted on the wall faces,
reading pins as small status-coloured markers on the wall at height, equipment
symbols on the floor, the source marker. Choose the view corner automatically
so the walls with the most items face the viewer. Calm, architectural, light
shading only (two wall tones + floor), no perspective distortion, no textures.
Use as the cover hero (replacing the plain plan when there are wall items) and
as a full page "Overview". It is for orientation, not measurement — say so in
the caption.

## C. Fix: room attribution on shared walls

A wall item's room is currently guessed. When the item has `cam`, attribute it
to the room containing `cam` (the side the person stood on), and draw the
elevation from that side. Applies to titles ("Reading 1 · Bedroom · Wall A"),
room pages, locator maps, summary, tables and the unfolded room. Keep the old
guess only when there is no `cam`. Add an optional `side` (+1 / -1 relative to
wall a->b) written by the editor when the user places or moves an item by hand,
so manual items are stable too.

## Deliverable for the owner to choose from

Produce, for the three-visit small sample and for the large house: the unfolded
room in two or three clearly different visual treatments (e.g. pins only /
with photo thumbnails / "Proposed works" emphasis) and the isometric in two
treatments (whole floor / affected rooms only), as PNG pages and one PDF
"visual-options.pdf" with each option labelled A1, A2, A3, B1, B2 and a
one-line description, so he can pick. Wire the chosen defaults into the report
behind `report.include` toggles (unfolded rooms on by default, isometric cover
on by default); elevations and plan stay.
