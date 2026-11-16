# MARKING.md — marking in the AR view (components, scrubbing, removal visuals)

Status: v1, round "marking" on branch `ux2`. Supersedes the two-tap "Start here / End here"
flow as the main way to mark; two taps remain the fallback while no geometry is known yet.

The idea: the room is already understood (RoomPlan walls, openings, objects; on return
visits the saved plan). Marking is therefore **selecting and painting components**, not
drawing free lines: the reticle highlights the component under it, a tap takes the whole
component, a finger scrub paints part of it, and the paint never leaves the component.

Data contracts do not change (SPEC.md: `removals` with `item` / `wallId` / `t0` / `t1` /
`heightMm`, `affected`, moisture lines as `kind: "boundary"` readings, `sources`,
`equipment`). The only additions are optional fields, listed at the end.

---

## A. The component index

Built live from RoomPlan geometry (classic and live engines, `ScanWorld`) and, on return
visits, from plan.json (walls, `objects`, openings). Pure code in `Core/Components.swift`.

| Component | Built from | Geometry |
|---|---|---|
| Wall face | each wall | quad from the base edge to the top edge (wall height) |
| Wall segment | a wall split at doors and floor-reaching openings | `t0…t1` along the wall a→b |
| Skirting segment | the base edge of a wall segment | line at floor height, `t0…t1` |
| Opening | doors, windows, openings | `t0…t1` on its wall, bottom and top heights |
| Floor | the room outline | polygon at floor height |
| Object | RoomPlan objects | box: centre, size (w, h, d), yaw; category |

Windows do not split skirting (they don't reach the floor); doors and floor-reaching
openings do. Segments shorter than 0.10 m are dropped.

Object categories (RoomPlan): storage, sink, oven, dishwasher, refrigerator, stove,
washerDryer, toilet, bathtub, table, bed, sofa, chair, television, fireplace, stairs.

- **Cabinetry** = storage, sink, oven, dishwasher, stove.
- **Appliance** (removable with cabinetry, labelled "appliance") = refrigerator, washerDryer.
- **Water-entry candidates** = sink, toilet, bathtub, washerDryer, dishwasher, plus every
  window sill and the ceiling.

## B. Hover highlight

As the reticle moves, the component under it is highlighted **before any tap**, in the
current mode's style. A light haptic (`DS.Haptic.lock`) fires when the highlighted
component changes (not on every frame).

| Mode / kind | What is hovered | Highlight |
|---|---|---|
| Strip-out · Skirting | skirting segment of the wall under the reticle (or the wall nearest a floor aim within 0.35 m) | the base edge glows: 6 pt white at 45 % with a 3 pt blur (bloom) under a 1.5 pt white dashed line (3 on, 5 off); square end ticks (10 pt, 2 pt white) at the segment ends; length chip |
| Strip-out · Wall | wall segment | thin white outline (1.5 pt, 85 %) of the face quad |
| Strip-out · Cabinets | cabinetry / appliance box hit by the reticle ray | white edge outline (1.5 pt) of the box + soft white fill 10 % |
| Strip-out · Floor | the room's floor | the room outline traced on the floor: 5 pt white at 50 % with bloom |
| Moisture · Moisture line | wall segment | as Wall, but outline in `#64D2FF` |
| Moisture · Wet floor | the room's floor | as Floor |
| Source | water-entry candidates in view | a subtle ring (24 pt radius, 1.5 pt white 55 %); the hovered one 2 pt, 90 % |

## C. Gestures

| Gesture | Effect |
|---|---|
| Tap the round action button | takes the **whole** hovered component (segment, face, cabinet, room floor) |
| Tap a component on screen | the same, for the component under the finger |
| Press and scrub (one finger) | paints along / over the hovered component only (constrained, below) |
| Drag the cut line (strip-back) | moves the cut height; readout chip follows ("600 mm") |
| Drag the airflow fan's tip | aims the air mover's airflow (floor point under the finger) |
| Two-finger tap | undoes the last scrub step (or the last point of a two-tap line) |
| Two-finger twist on an air mover | turns it (as before) |

Constrained scrubbing (the finger's screen point is turned into a world ray, then
projected onto the component):

- **Skirting**: onto the wall's base line (ray ∩ wall plane, else ray ∩ floor projected to
  the wall). The run snaps to segment ends, corners and door jambs within 0.15 m. A scrub
  never leaves its segment; at a **corner** (segment end = wall end) it continues onto the
  neighbouring wall only when the finger is deliberately moved onto that wall (the ray
  meets the neighbour's plane at least 0.10 m past the corner); scrubbing back onto the
  previous wall takes the extra piece off again. At a door jamb it stops. The chip next to
  the head says how far is left: "0.6 m to wall end".
- **Wall strip-back**: onto the wall plane. The scrubbed t-range is the stretch; the
  highest point reached sets the cut height (snapped, see D). The cut line can then be
  dragged up or down.
- **Floor**: onto the floor plane, inside the room only. A 0.25 m brush paints 0.10 m
  cells; the area readout is live. Saved as the outline of the painted cells (convex hull,
  clipped to the room) in the existing flooring / affected polygon fields.
- **Moisture tide line**: along the wall base, then up: the run's samples (one per 0.10 m
  along the wall) keep the last height scrubbed at that spot; the line is the samples in
  wall order. Saved as moisture-line points (`kind: "boundary"`) every 0.25 m.

## D. Removal and inspection visuals

Consistent across AR, the 3D tab and reports. Colours (sRGB):

| Token | Value | Use |
|---|---|---|
| removal red | `#FF453A` | every removal |
| removal casing | black 35 % | 12 pt under red lines |
| moisture blue | `#0A84FF` | moisture wash, sources, labels |
| tide line | `#64D2FF` | the wavy top edge of a moisture wash |
| glass | `#1C1C1E` at 62 % (+ 0.5 pt white 24 % hairline) | neutral chips |
| airflow teal | `#64D2B4` | airflow fan, coverage cone |

- **Skirting** — red 7 pt line on the wall base over a 12 pt black 35 % casing; white
  vertical "cut" ticks (2 pt, 9 pt long, 90 %) every 0.5 m; white end caps (8 pt radius,
  ringed red at the start). Label (red chip): **"Skirting · 2.35 m"**.
- **Wall strip-back (flood cut)** — the wall face from the floor to the cut line: red fill
  26 % + white diagonal hatch (45°, 9 pt pitch, 1.4 pt, 50 %); red 2 pt outline; the cut
  line itself a crisp white **dashed** line (2.5 pt, 9 on 6 off) with a white drag handle
  (34 × 22 pt capsule, chevrons up/down). Height chips under the camera:
  **300 / 600 / 900 / 1200 / Full** (selected = white fill, ink text). Readout chip
  "600 mm" beside the line while dragging. Label: **"Strip wall to 600 · 2.8 m²"**.
  Snapping: to 300 / 600 / 900 / 1200 within 40 mm, otherwise to 50 mm.
- **Cabinetry** — the cabinet box as a red wireframe (2 pt) with a 25 % red fill on its
  visible faces and a small white "×" badge (18 pt red circle, white ×) at the top front
  corner. Label: **"Remove cabinetry · base 1.8 m"** (length along the wall). Chip
  **"Kick board only"** turns it into the bottom 150 mm band (saved `heightMm: 150`,
  note "Kick board only").
- **Flooring by material** — red fill 30 % and a 2.5 pt red outline, with a white pattern:
  - Carpet: soft stipple (dots 1.1 / 0.9 pt radius, 55 % / 40 %, 7 pt cell) + "underlay"
    toggle (label "Carpet + underlay");
  - Vinyl / LVP: fine diagonal hatch (45°, 9 pt pitch, 1.4 pt, 50 %);
  - Timber: plank lines (parallel lines 14 pt apart along the room's long axis, with
    staggered butt joints every 60 pt, 1.2 pt, 50 %);
  - Tile: square grid (16 pt, 1 pt, 45 %).
  Label: **"Carpet + underlay · 4.6 m²"**. "Whole room" pill takes the room outline.
- **Moisture extent (inspection, not removal)** — on walls a blue wash (`#0A84FF` 32 %)
  from the floor up to the tide line, whose top edge is a soft **wavy** line (`#64D2FF`
  2.5 pt; amplitude 4 pt, wavelength 28 pt on screen). On floors a blue area at 30 % with
  a soft edge. Label (glass chip): **"Moisture to 450 mm"**.
- **Water source** — a blue drop pin (white 2.5 pt stroke) on the surface with a slow
  ripple (2 s period). **Suspected** = outlined ripple rings; **Confirmed** = a solid
  filled disc behind the drop. Label (blue chip): **"Shower mixer · Suspected"**.
- **Equipment** — the 3D models (EquipmentModels.swift). Airflow is aimed by dragging the
  floor fan's tip (or "Set airflow"). Coverage is a faint floor cone (teal 10 %, ±30°,
  2.5 m) shown in Equipment mode only.

Labels: noun bold 13 pt + detail 12 pt at 72 %, capsule, 0.5 pt white hairline; they
avoid each other, pins, glyphs, the reticle and the torch / 0.5× controls; a mark with
less than 80 pt on screen gets no label.

## E. Suggestions

One chip at a time, glass, above the sub-picker: text + a blue action ("Yes" / "Add") and
a dismiss ×. Never applied automatically; dismissed suggestions don't come back for the
same wall / area / source in the session.

| After | Condition | Suggestion | Action |
|---|---|---|---|
| a reading | value ≥ wet threshold (default 20) at ≤ 0.15 m on a wall with no skirting removal | "Mark skirting along this wall?" | Strip-out · Skirting with that wall's base selected |
| a tide line | highest point H mm | "Moisture reached H — cut at C?" | Strip-out · Wall with that wall preselected at C |
| a wet floor area | the room's floor type is carpet (or the area is aimed on carpet) | "Lift carpet + underlay in this area?" | flooring removal of the same polygon, carpet + underlay |
| a source | within 0.8 m of a sink or storage (vanity) | "Remove cabinetry: vanity?" | Strip-out · Cabinets with that box selected |

Cut height C = the smallest of 300 / 600 / 900 / 1200 that is at least H + 150 mm; above
1200 → Full.

## F. Studio and tests

Studio scenes: hover-skirting, scrub-skirting, strip-back-dragging, cabinet-hover,
cabinet-selected, floor-carpet, floor-vinyl, floor-timber, floor-tile, moisture-tideline,
source-suspected, source-confirmed, airflow-drag, suggestion-chip. The Studio room gains a
kitchen run on the right wall (base cabinets, a sink cabinet, an oven) and a vanity on the
left wall. Unit tests: component index (segments split at doors, cabinetry filter),
constrained scrub projection, snapping, run continuation round a corner and back,
floor painting area, tide line, cut-height rule, suggestion rules.

## H. Walls have two sides

Nothing may show through a wall, and a mark on a wall belongs to one face of it.

**H1. Sidedness in data.** Every wall-attached item records its `wallId` and a `side`:

- `"a"` — the side the wall's left normal points to: for a wall from `a` to `b` (plan
  x, y), normal = (−(b.y − a.y), b.x − a.x), normalised; `"b"` — the other side.
- `"cavity"` — inside the wall (a leak in the cavity, a pipe, a wet frame): stored with its
  position along the wall (`wallT`) and `height`, no face.

The side is decided when the item is captured, from the camera position (the side the camera
is on): readings, photos, moisture-line points, sources and wall removals (skirting, strip-back,
cabinetry). Stored as optional `"side"` on `readings-raw.json` records and on
`markup.readings[]`, `markup.sources[]` and `markup.removals[]` in plan.json (absent = unknown:
older jobs; such items are drawn from both sides, as before). `cam` stays as it was.

**H2. Visibility in AR.**

- 3D layer: the scanned walls are added as invisible **depth-only occluders**
  (`colorBufferWriteMask = []`, `writesToDepthBuffer = true`, rendering order −100), split at
  doors, openings and windows (lintels and sills kept), so a unit in the next room disappears
  behind the wall. On return visits the plan's walls are used, aligned by relocalisation.
  Furniture occlusion from ARKit scene depth is **not** used yet: RoomPlan runs its own session
  configuration (see the round report).
- 2D overlay: each mark's sample points (first, last, centroid), lifted 3 cm towards the camera,
  are raycast from the camera against the wall quads; a wall more than **5 cm** in front of all of
  them hides the mark. Doors, openings and windows don't block.
- Side test: a one-sided mark is drawn only when the camera is on its side:
  dot(camera − wallPoint, sideNormal) > 0.
- Cavity marks are drawn on whichever face you are looking at, at the same position along the
  wall and the same height (2 cm off that face): the drop pin inside a faint dashed outline
  (white 75 %, 4 on 4, 10 pt corners, moisture blue 12 % fill), label **"Leak · inside wall"**.
  They read the same from both rooms without poking through.

**H4. Placing.** Aimed at a wall, the side is taken from where you stand — a reading or a
strip-out goes on your side automatically. The Source tray has **On the surface / Inside the
wall** chips; it defaults to *Inside the wall* when the source is aimed at a wall away from
fixtures (no sink / toilet / bath / washer / window sill within 0.6 m), else *On the surface*.

**H5. Studio:** through-wall-hidden, cavity-leak-side-a, cavity-leak-side-b,
strip-out-other-side-hidden. Unit tests: the side test, the cavity point on both faces, the
occlusion raycast (incl. through a doorway).

**For the 3D tab (Job/ModelTab.swift, Job/LabelLayout.swift) — rule to implement there:** in
the dollhouse, one-sided marks are drawn on their face only and hidden when that face points
away from the camera (dot(cameraPosition − wallPoint, sideNormal) ≤ 0); cavity marks are drawn
inside the wall's thickness, visible from both sides through the cut top of the wall. Items
without `side` are drawn as today.

## Optional data additions (documented here and in SPEC.md terms)

- `readings-raw.json` source records and `markup.sources[]` items: optional
  `"status": "suspected" | "confirmed"` (absent = suspected).
- `markup.removals[]` / raw removal records: optional `"note": "Kick board only"` is used
  for the toe-kick choice (the field already exists; no new field).
- `markup.objects[]` is read on return visits for the component index (already in SPEC.md).
- `side`: `"a" | "b" | "cavity"` on raw records and on `markup.readings[]`, `markup.sources[]`
  and `markup.removals[]` (section H).
