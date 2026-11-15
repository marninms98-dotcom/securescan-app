# SecureScan field UX v2 — design spec

Status: binding for all iOS UI work from 15 Nov 2026. Where this conflicts with
older UI descriptions in SPEC.md, this wins. Data contracts in SPEC.md do NOT
change (plan.json, raw items, editor bridge).

## Why (first real-phone test, 15 Nov)

The owner scanned a bedroom + ensuite on an iPhone 15 Pro Max. Everything
*functioned* (LiDAR plan, wall-pinned readings, photos, voice, transcript,
relocalisation, scope ticks). His verdict: "I got the idea of what it was trying
to do, but execution was crap. Felt like a toddler app. Not professional
business grade." From his live voice notes and the saved data:

1. Wanted to remove skirting "from there to there"; the app put him in floor
   removal ("Oh, this is trying to remove the floor"). He tapped two points
   along the skirting inside the floor tool; the app later reported
   "1 removal could not be placed (The section is too small. Tap its corners
   on the floor.)" — jargon, blame, and lost work.
2. "The way you're showing the skirting begin is a bit bad." "Showing the
   flooring — this is a dot… it's more of a cohesive thing." In-progress shapes
   looked like loose dots, not one solid shape.
3. "Be nice to see the photo that we are taking… you can't tell what you've
   taken, what you haven't taken." No shutter feedback, thumbnail or count.
4. Wanted 0.5x zoom for photos. Photos were saved at 960x1280.
5. Logging anything opened a full-height sheet that hid the camera.
6. Air movers were placed twice (once while scanning, again in the scope view)
   because the first ones showed no airflow and the flows did not connect.
7. Leak source saved with the label "Unknown".
8. Bedroom + ensuite became one room called "Bedroom".
9. Chrome: several unrelated button styles/colours, paragraphs of instructions,
   stacked bars colliding on the job screen (orange bar over document buttons
   over the plan over the editor toolbar over the tab bar).

## Principles

- **The camera is the workspace.** Nothing ever covers more than the bottom
  ~42% of the screen while capturing. No full-screen sheets, no alerts with
  paragraphs. Every input happens in a compact tray docked at the bottom.
- **Aim, tap, done.** The reticle says what will happen before the tap. The app
  infers the obvious from where you aim; the user corrects with one chip.
- **Solid, cohesive marks.** Everything drawn in the world is a finished-looking
  vector shape with a label, from the first tap, live-following the reticle.
- **Always show what was captured.** Every save animates into a visible stack
  with a count; one tap reviews, edits, deletes.
- **One visual system.** One accent, one button shape, one type scale, one
  material. Colour means something or it is neutral.
- **Words: few, plain, never blaming.** Max one short line of hint. Sentence
  case. No "START"/"END" caps, no "could not be placed".

## Design system (`ios/SecureScan/UI/DS.swift`) — the only place styles live

- Colours: `ink` (near-black #0B0F14), `paper` (#FFFFFF), `accent` (#1F6FEB
  blue; brand colour replaceable later), semantic only for meaning:
  `dry` #2E9E5B, `damp` #E0A21A, `wet` #D9453A, `remove` #E5484D,
  `equip` #12A594, `source` #2F7CF6. Neutral greys from one ramp.
  Over camera: text white on `.ultraThinMaterial` dark capsules; never raw
  grey boxes.
- Type: SF Pro; numerals `.monospacedDigit()`; value readouts SF Pro Rounded
  semibold. Scale: 28 title / 20 headline / 17 body / 15 callout / 13 caption.
  Nothing below 13.
- Shape: continuous corner radius 14 (controls), 22 (trays/cards), full capsule
  only for the primary action and chips. 1 px hairline white 12% on materials.
- Controls (all in DS): `PrimaryButton` (capsule, 60 pt high, accent fill, one
  per screen), `SecondaryButton` (capsule, material), `Chip` (36 pt high,
  selected = white fill/ink text), `IconButton` (44 pt circle, material),
  `ToolTab`. Minimum target 44 pt, 12 pt gaps. No other button styles anywhere.
- Motion: 0.22 s spring for tray/selection; saved item "flies" to the stack
  (0.35 s); haptics: light on aim-lock change, medium on save, rigid on
  undo/delete, warning on can't-do.
- Light UI (lists, job screen) uses system grouped background, the same
  buttons/chips, and large clear titles. Dark UI only over the camera.

## The capture screen (one HUD for every camera screen)

`CaptureHUD` is a SwiftUI overlay used unchanged over: the classic RoomPlan
scan (RoomCaptureView), the new one-screen scan, mark-up after a room, return
visits, and "See scope on site". Engines differ; the HUD does not.

```
┌──────────────────────────────┐
│ (x)   Bedroom · 3 m²   ● 0:42│  top bar: close, room/phase capsule, rec dot+time
│                              │
│            ┌ wall · 0.32 m ┐ │  reticle label (surface · height or length)
│               ( + )          │  reticle: ring; locks/snaps with a tick
│                              │
│ [▣ 7]                 [↶ Undo]│  left: capture stack (last thumb + count)
│  Reading  Photo  Mark  Equip  Source │  tool rail (5 tools max, icons+labels)
│        (   Add reading   )   │  ONE primary action, text says what tap does
│   Next room            Finish│  quiet text buttons (scan phases only)
└──────────────────────────────┘
```

- **Top bar**: close (confirm only if unsaved room), a single capsule with the
  current room name + phase ("Scanning · Bedroom", "Marking · Ensuite",
  "Visit 2 · 4 of 9"), recording dot + elapsed when the mic is on. Tapping the
  room name renames it with chips (Bedroom, Ensuite, Bathroom, Kitchen, Living,
  Laundry, Hall, Robe, Other…); RoomPlan's section labels pre-select when
  available.
- **Reticle**: 28 pt ring with centre dot; label capsule above it shows surface
  and live measure: "Wall · 0.32 m up", "Skirting", "Floor", "Ceiling",
  "Cabinet". While a line/area is in progress the label shows running length /
  area. If nothing is under the reticle: ring goes dashed and the primary
  button text becomes the reason ("Move closer", "Point at a surface").
- **Tool rail** (replaces modes+sheets): **Reading · Photo · Mark · Equipment ·
  Source**. Selected tool = filled chip; the rail never scrolls. Work modes
  (Inspect / Scope / Monitor) remain as a small segmented control in the top
  capsule's menu only where both apply; default by context (first visit:
  everything available in one rail; return visit: rail becomes Re-measure ·
  Photo · Done · Mark · Equipment).
- **Primary button** always reads as the action on the aimed thing:
  "Add reading", "Take photo", "Start here", "End here · 2.35 m",
  "Close area · 3.2 m²", "Place air mover", "Set airflow", "Re-measure 3",
  "Mark done". 60 pt capsule, thumb zone.
- **Tray** (replaces every sheet): slides up from the bottom to at most 42% of
  the height, camera stays live above, reticle frozen on the captured point
  with its pin shown. Trays:
  - *Reading*: big value field + inline number pad (0–9, ., ⌫) with a large
    "Save" key; chips row above: material (auto from surface: Wall / Skirting /
    Floor / Ceiling / Cabinet / Other) and "Dry reference" toggle. Unit "%"
    shown. Save returns to aiming with Reading still selected. Value colours
    the pin (dry/damp/wet thresholds from the plan).
  - *Mark* (one tool for everything that is a line or an area): see next
    section.
  - *Equipment*: chips Air mover / Dehumidifier / Air scrubber / Heater; after
    placing an air mover the button becomes "Set airflow" with a live arrow;
    asset number optional chip "Add asset no." (never required).
  - *Source*: chips for cause (Shower, Flexi hose, Pipe, Roof, Window, Appliance,
    Overflow, Unknown) — the tray will not save with nothing selected; "Unknown"
    is an explicit choice. Optional note field.
  - *Photo*: no tray. Shutter flash + haptic; thumbnail flies to the stack.
- **Capture stack** (bottom-left, like the Camera app): last photo thumbnail
  with a count badge of everything captured this session. Tap = review drawer
  (same 42% tray, horizontal cards: thumbnail, type icon, value, room; tap a
  card to edit value/material/caption or delete; "Retake" for photos). The
  item being reviewed is highlighted in the world.
- **Undo**: chip appears above the rail for 6 s after each save.
- **Mic**: 44 pt icon button in the top bar; recording state always visible.
- **Coaching** (RoomPlan instructions) appears in the top capsule's second line,
  never as a banner over the centre.
- No paragraphs anywhere on this screen. First-run help = three one-line coach
  marks that dismiss on first use of each tool.

### Mark tool: lines and areas by intent, not by menu

One gesture model: **Start here → End here** (line) or **Start here → add
corners → Close area** (area). What the mark *is* is inferred from where the
user aimed, shown as a preselected chip in the tray after the shape is drawn,
changeable with one tap:

| Aim | Shape | Default meaning | Other chips |
|---|---|---|---|
| Wall within 150 mm of floor (or the floor within 150 mm of a wall), two points | line along wall | **Remove skirting** | Moisture line, Remove wall lining, Remove cabinetry |
| Wall above 150 mm, two points | line along wall | **Moisture line** (Inspect context) / **Remove wall lining** (Scope context) | the others |
| Floor away from walls, 3+ points, or "Whole room" | area | **Wet floor** (Inspect) / **Lift flooring** (Scope) | the other; floor type chips (Carpet, Timber, Vinyl, Tile, Other); underlay toggle |
| Two points on the floor not near a wall | line | ask: "Skirting run or floor area?" — offer "Add corners" to continue the area, or pick Skirting (snaps to nearest wall) |

- A two-point floor "area" is never an error: it becomes a line and the tray
  asks what it is. Nothing is ever dropped later with a message; anything the
  processor cannot place is shown in review with "Tap to fix", in plain words.
- Wall lining height: chips 300 / 600 / 1200 / Full, preselected from how high
  the End tap was aimed. Skirting has no height question.
- "Whole wall" / "Whole room" chips appear when the reticle is on a known wall /
  inside a known room.
- Snapping to wall ends/corners within 150 mm with a tick; the snapped end shows
  a small square cap.

### What is drawn in the world (`OverlayRenderer`)

All marks are drawn as **2D vectors projected from world space every frame**
(SwiftUI `Canvas` over the camera), not SceneKit geometry. This gives crisp,
uniform, legible graphics on every engine (including Apple's RoomCaptureView,
where we cannot add 3D nodes) and makes the whole look testable off-device.

- `Projector` protocol: world point → screen point (+ behind-camera flag).
  `ARCameraProjector` wraps `ARCamera.projectPoint(_:orientation:viewportSize:)`;
  `PinholeProjector` (pure maths) is used by tests and the Studio harness.
- Polygons/lines are clipped against the near plane before projection.
- Styles:
  - **Reading pin**: 30 pt circle, fill by threshold colour, white 2 pt ring,
    value in rounded semibold ("18"), small sequence tag below ("R2"); a 1 pt
    stem to the surface point. Reference readings: hollow ring.
  - **Photo**: 22 pt rounded square camera glyph, white on dark; selected shows
    its thumbnail in a callout.
  - **Source**: blue drop marker with a pulsing ring (2 s), label capsule
    ("Shower leak").
  - **Line in progress**: 4 pt solid line from the start cap to the reticle with
    a centred length capsule ("2.35 m"); start cap = 10 pt white dot with ring.
    Finished skirting removal: 8 pt red line hugging the wall base with end
    ticks and tag capsule ("Skirting · 2.35 m"). Wall lining: translucent red
    band from floor to cut height (fill 28%, 2 pt outline, diagonal hatch),
    tag at top-left. Moisture line: blue 3 pt line with small wave ticks.
  - **Area in progress**: filled translucent polygon from the first tap
    (fill 22%), outline 3 pt, live edge to the reticle, corner dots 8 pt,
    area capsule at the centroid; closing snaps to the first corner. Finished
    wet floor = blue fill; lift flooring = red hatch fill with tag
    ("Carpet · 3.2 m²").
  - **Equipment**: 34 pt rounded square with a clear glyph (fan / droplet-box /
    filter / flame) in `equip` teal, asset tag capsule; air mover airflow = a
    tapered arrow on the floor 1.2 m long. Planned = outline only; placed =
    solid.
  - Labels never overlap the reticle; off-screen selected item shows an edge
    arrow chip ("R3 ←").
- During the classic scan the overlay is drawn over RoomCaptureView the same
  way (camera from `captureSession.arSession.currentFrame`).

### Flow fixes

- Equipment placed while scanning is the same equipment in the scope view: no
  second placement. If it has no airflow yet, aiming at it offers "Set airflow".
  The scope view never creates a duplicate within 0.5 m of an existing unit of
  the same type — it selects the existing one.
- Photos: use `ARSession.captureHighResolutionFrame` when available (fallback:
  current frame); store full resolution JPEG (quality 0.85), keep a 960 px
  preview for the plan. If the device/session offers an ultra-wide video format
  (`ARWorldTrackingConfiguration.supportedVideoFormats` with
  `.builtInUltraWideCamera`) outside an active RoomPlan capture, show a
  "0.5x" toggle next to the shutter for Photo; if not available, do not show
  it (no dead control). Report in the round notes what the API actually allows.
- Room naming: on "Room done", a tray asks the name with chips (no keyboard
  unless "Other"). If RoomPlan reports several sections (e.g. bedroom +
  bathroom) offer "Bedroom + Ensuite" as one name; splitting rooms is out of
  scope.
- Errors: any processing problem becomes an item in the review drawer with a
  plain sentence and a fix action. `job.json.note` strings are rewritten to
  plain language ("1 mark needs a quick fix — open Items").

## The rest of the app

- **Jobs list**: large title "Jobs"; cards (plan thumbnail 64 pt, address,
  "3 rooms · 22 m² · 7 readings", last visit date, status chip: Inspecting /
  Quoted / Drying · day 3 / Complete). One PrimaryButton "New job" docked at the
  bottom. Search in the nav bar. Empty state: one line + New job. Settings via
  a gear IconButton.
- **New job**: one screen, two fields (address prefilled from location with a
  small "Use current location" row, job/claim ref optional), PrimaryButton
  "Start". Location permission is requested only when the user taps "Use
  current location" (never as a pop-up on open). Scan engine choice is NOT on
  this screen (Settings only).
- **Job screen**: nav bar = back, address (2 lines max), `…` menu. Below: a
  segmented control **Plan · 3D · Items · Files**. The plan/editor gets the
  full remaining height — no native bars floating over it. Bottom dock (one
  row, material): PrimaryButton that depends on state ("Continue on site" /
  "Start visit 2" / "See scope on site") + an IconButton "Documents" opening a
  menu: Inspection report, Quote or Scope of works (by price setting),
  Monitoring/Final report, Job pack. The mic button moves into the dock
  (IconButton). Nothing else is pinned to this screen.
- **Items tab** (new): everything captured, grouped by room, as cards with
  thumbnails; tap to edit; filter chips (Readings, Photos, Marks, Equipment);
  "Needs a fix" group at the top when present. This replaces hunting in Files.
- **Settings**: grouped list; plain labels; scan engine switch lives here.
- The web editor inside the app keeps its own toolbar; native UI must not
  overlap it.

## Studio harness (how the UI is reviewed without a phone)

Debug/simulator only (`#if DEBUG`, launch env `SECURESCAN_STUDIO=<scene>`):
shows the real `CaptureHUD` + `OverlayRenderer` over a synthetic camera view
(an `SCNView` rendering the demo job's walls/floor/door with plain lit
materials — NO real photos), using a `PinholeProjector` matching that SCNView's
camera, with scripted state. Scenes, each screenshotted by CI into
`ci-screenshots/studio-*.png`:

`aim-wall`, `aim-skirting`, `aim-nothing`, `reading-tray` (value 18 typed),
`reading-saved` (pins dry/damp/wet + undo chip + stack count),
`line-progress`, `line-tray-skirting`, `lining-band-done`, `area-progress`
(3 corners + live edge), `area-tray`, `photo-taken` (stack thumbnail),
`review-drawer`, `equipment-place`, `equipment-airflow`, `source-tray`,
`room-name-tray`, `scan-coaching`, `visit-remeasure`, `scope-on-site`,
`needs-fix`. Plus light-UI screenshots: jobs list (3 demo jobs), new job, job
screen on each tab, documents menu, settings.

Acceptance for every screenshot: no overlapping controls or clipped text; one
primary button; nothing covering the top 58% except the top bar and world
marks; text ≥ 13 pt; consistent paddings (16 pt screen margins).
