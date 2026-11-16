# SecureScan — the moisture model

Owner's brief (Nov 2026): one leak point that shows through both sides of a wall,
"some kind of normal physics, like Minecraft, so water just flows how we know it
to flow, and then we can tweak it based on the moisture readings — the app works
out the moisture, but you can also tweak it. A really intelligent partnership
between the app's physics, the moisture readings, and the scoper's tweaks."

This document is the design and the data contract. Code: `ios/SecureScan/Core/Moisture/`
(pure Swift, Foundation + simd, no UIKit). Tests: `ios/SecureScanTests/Moisture*Tests.swift`.

## Honest by design

The model is a **guide**. Every number it produces is labelled:

| provenance  | meaning |
|-------------|---------|
| `measured`  | within 0.4 m of a moisture reading on the same surface (same wall face, same room's floor), or 0.2 m of a moisture-line mark. The reading wins there. |
| `estimated` | physics only. Never print it as a measurement. |
| `scoper`    | set by the scoper's own correction (brush, dragged tide line, dragged floor outline). |

Reports must keep the three apart (every area and length comes as a
`MoistSplit { measured, estimated, scoper }`), show the confidence of each area,
and present strip-out items as **suggestions**. Meter thresholds stay what the
spec says they are: a display aid, not an industry standard.

## Wall sides (shared with docs/MARKING.md)

A wall runs `a -> b`. Its direction is `d = (b - a)/|b - a|` and its normal is
`n = (-d.y, d.x)` — the editor's `perp(d)` (plan y points down the page).

- side **"a"** = the `+n` side = the editor's `side: +1`
- side **"b"** = the `-n` side = the editor's `side: -1`
- **"cavity"** = inside the wall

Readings and sources may carry `side` as `"a"`, `"b"`, `"cavity"`, `+1` or `-1`.
Without it, the side comes from `cam` (the side the person stood on), else from
the only side that has a room, else `"a"`. A reading on a wall with
`side: "cavity"` is an inspection-hole reading.

## Cells

Everything is discretised at **0.10 m** (fitting runs on a 0.20 m copy):

- **Floor cells**: a square grid over the plan; a cell exists when its centre is
  inside a room (the smallest room if they overlap). Covering from
  `markup.floors` (smallest zone containing the centre); with no zone, rooms
  called bath / ensuite / shower / laundry / WC / toilet / powder are tile, others
  "other".
- **Wall face cells**: per wall, per side that faces a room (probed 0.15 m off
  the wall, per column), `along x height` up to **1.2 m** (`maxWallHeight`).
  Moisture rarely goes higher; if it does, the face reports `reachesModelTop`
  and the suggestion says to measure higher.
- **Cavity cells**: per wall, same columns and rows, inside the wall. The bottom
  row is the bottom plate (or the base of a masonry wall).
- Door / opening cells are removed (both faces and the cavity, for their sill to
  head); windows remove the cells above the sill.

## Connections

Two kinds, built once per grid:

**Wicking links** (capillary diffusion, conductance `k = D / h²` with
`D = wick² / dryHours`, harmonic mean across materials):

| link | notes |
|------|-------|
| floor ↔ floor (4-neighbour) | same room, open plan, or **through a doorway** (door / opening with sill < 0.3 m). Never through a solid wall. Threshold factor: `markup.floorThresholds` type (`none` 1, `strip` 0.35, `ramp` 0.25, `step` 0.10, `sealed` 0.02), else 0.7 for a doorway with the same covering both sides and 0.35 for a change of covering. Scoper barriers cut the link. |
| face ↔ face along / up / down | per lining. Up = capillary rise; down = rise + a small gravity drift. |
| cavity ↔ cavity | air gap: weak along, strong gravity down; along the plate: water runs. |
| face ↔ cavity | through the lining, `toCavity` x the face's rise conductance (plasterboard 0.4, tiles on membrane 0.02). |
| face base ↔ plate | `toPlate` (the lining stands on the plate: plasterboard 1.0, tiled 0.12). |
| face base ↔ floor beside it | `toFloor` (plasterboard 1.0, tiled 0.08). |
| plate ↔ floor each side | "under the skirting", `underSkirting` (plasterboard 0.5, tiled/membrane 0.04). |

**Free-water edges** (where liquid water can run, with a cost in metres):
down every face and cavity column (cost 0 — water falls), along the bottom
plate (cost = column width), out under the skirting (`h + (1/underSkirting − 1) x 1 m`),
back in under it from a floor (`x 3 m` — getting under a wall is much harder
than coming out of one), off a face onto the floor (`h`), across the floor
including diagonals (`h` or `h√2`, plus `(1/threshold − 1) x 0.5 m` at a
threshold: strip 0.9 m, step 4.5 m, sealed 25 m). Water never runs up.

## Physics

Two steps, both simple, stable and explainable.

1. **Free water — the "Minecraft" step.** From each source, a Dijkstra flood over
   the free-water edges: water goes the cheapest way first and every cell it
   reaches holds its capacity (litres/m²) before water runs on, until the
   source's volume is used. Cells at the same cost fill together (no side is
   favoured). Inside a stud wall the cells water only trickles past on its way
   down are wet to 0.5; the plate it collects on, to 1. A cavity leak therefore falls straight to the plate, runs along it,
   and comes out under the skirting into **both** rooms — less on a side whose
   lining is waterproofed. A threshold holds water back until the near side is
   full; a barrier stops it. Flooded cells are fixed at their material's
   "wet level".
2. **Wicking and drying.** From the flooded cells moisture spreads by capillarity
   and is lost by drying; the steady state of

   `Σ_j k_ji w_j − (Σ_j k_ij + 1/dryHours_i + 1/hours) w_i = 0`

   is solved by projected SOR (ω 1.85 on floors, 1.6 on faces, 1.1 in cavities —
   gravity makes the cavity one-sided and higher ω oscillates there; cells in
   index order, fixed caps and tolerances), wetness `w` kept in `[lo_i, hi_i] ⊂ [0, 1]`. The `1/hours` term
   is the Laplace-transform form of "only `hours` have passed since the event":
   at `s = 1/t` a diffusion that started t hours ago has the same reach as a
   steady state with extra loss `s`, so a fresh flexi-hose burst has not wicked as
   far, or risen as high, as a month-old shower leak. Spread from wet material
   falls off by e every `wick` metres; capillary rise reaches an equilibrium height
   set by wetness and material.

Only cells within `reach` (4.5 m of graph hops) of a wet seed are iterated.

### Materials (defaults, MoistureMaterials.swift)

Floors — wick length (m), drying time constant (h), free water held (L/m²), wet level:

| covering | wick | dry h | holds | wet | why |
|----------|------|-------|-------|-----|-----|
| carpet (+ underlay) | 1.10 | 72 | 4.0 | 1.0 | wicks far, holds a lot |
| timber | 0.50 | 96 | 3.5 | 0.9 | boards wick along the grain, slow to dry |
| laminate | 0.60 | 96 | 3.5 | 0.9 | water spreads under the planks |
| vinyl | 0.45 | 72 | 4.0 | 0.75 | spreads under the sheet, little into it |
| tile | 0.30 | 36 | 5.0 | 0.6 | water sits on the surface, is mopped or drains; little gets into the bed |
| concrete | 0.40 | 120 | 4.0 | 0.8 | |
| other | 0.55 | 72 | 3.5 | 0.85 | |

Wall linings — along / up wick (m), dry h, couplings (cavity, floor, plate, under skirting):

| lining | along | up | dry h | cavity | floor | plate | skirting |
|--------|-------|----|-------|--------|-------|-------|----------|
| plasterboard | 0.35 | 0.45 | 48 | 0.4 | 1.0 | 1.0 | 0.5 |
| tiled (membrane) | 0.15 | 0.10 | 48 | 0.02 | 0.08 | 0.12 | 0.04 |
| render (masonry) | 0.35 | 0.55 | 96 | 0.8 | 0.8 | 1.0 | 0.3 |

Plasterboard at steady state with a wet base gives a damp boundary around
300–600 mm (the owner's experience); `rise` is fitted when readings or tape
marks say otherwise. A face is **tiled** when a reading on it has a material
containing "tile", or by the scoper's `lining` tweak. Walls are **stud**
(cavity, timber plate; free water runs along the plate and under the skirting)
unless the scoper sets `construction: masonry` (solid core, no free path under
the wall, higher rise, render faces).

### Sources

| type | placed | volume at "moderate" | typical age |
|------|--------|----------------------|-------------|
| flexiHose | floor | 40 L | 24 h |
| appliance | floor | 25 L | 24 h |
| shower | cavity | 1.5 L | 720 h (slow leak, a month) |
| pipe | cavity | 6 L | 72 h |
| roof | face | 4 L | 48 h |
| window | face | 2 L | 48 h |
| unknown | floor | 8 L | 72 h |

"Volume" is the free water the building **retained** (what soaked in), not what
came out of the pipe. Intensity: light x0.35, moderate x1, heavy x3, severe x8.
Type comes from `markup.sources[].type` or is inferred from the label ("Shower
mixer" → shower, "Burst flexi hose" → flexiHose, …). Placement: `side: "cavity"`
→ inside the wall, `"a"/"b"` → on that face, else by type; a floor source given
on a wall line steps 0.2 m into the room. The time horizon is
`moistureModel.hoursSinceEvent`, else the oldest source type's typical age.

## Readings → constraints

Meter value ↔ wetness (`MoistScale`): the dry baseline (median of reference
readings, else ⅔ of the damp threshold) = 0, **damp threshold = 0.2**, **wet
threshold = 0.4**, soaked (`wet + 2(wet − damp) + 10`, 40 % at 15/20) = 1,
linear between. So the job's own thresholds decide the states, exactly as on the
plan.

| evidence | constraint |
|----------|-----------|
| wet / damp reading | target = its wetness ± 0.06; interval = its state's band ∩ (target ± 0.05) |
| dry reading (incl. reference) | wetness ≤ 0.17 — dry readings carve the boundary |
| moisture-line mark (`kind: "boundary"`) | 0.2–0.3 at the mark, ≥ 0.22 0.12 m below, ≤ 0.17 0.15 m above |
| scoper brush | wet ≥ 0.55 / damp 0.22–0.38 / dry ≤ 0.05 over the brush radius (hard) |
| scoper tide line | ≥ 0.22 below the line, ≤ 0.18 above, sampled every 0.2 m (hard) |
| scoper floor outline | ≥ 0.22 inside, ≤ 0.18 in a 0.4 m band outside (hard) |

Readings are taken for one visit: `history[visit]` when the reading has history,
else its top-level value if it belongs to that visit. With no visit given, the
top-level (latest) values and, per wall, the latest visit's moisture-line marks.

## Fitting

On the 0.20 m grid, a bounded coordinate descent on log-parameters:

- each source's volume (unless the scoper fixed its intensity), ±10x around the
  type's default, prior σ = 1.5 (in ln);
- `floorSpread` (floor wick length multiplier), `rise` (capillary rise
  multiplier), both 0.4…2.5, σ 0.5;
- `lining` (face ↔ cavity permeability multiplier) 0.4…2.5, σ 0.8.

A multiplier is fitted only when some evidence can see it (`rise` and `lining`
need a wall reading or mark).

Objective: Σ weight x violation² over readings and scoper marks (physics alone,
no projection) + 0.005 x Σ((θ − θ₀)/σ)². Steps 0.8, 0.4 (two passes) and 0.2
(one pass) in ln units, first improvement accepted, stop when every constraint
is met. Warm-started, fixed iteration caps: deterministic. Typically 10–35 solves.

### "Second source likely"

After the fit, a wet or damp reading the physics still can't reach (physics well
below it) is **unexplained**. Unexplained readings are clustered (1.5 m, strongest
first); for each cluster the model tries a trial source in the wall cavity just
above the strongest reading (or at it, on a floor) at 0.5 / 2 / 8 / 32 L and
reports how much of the misfit it explains (`improvement`), with a message such
as *"Reading 4 is wetter than the marked source can explain. A second source is
likely in the Room B, inside wall e about 2.0 m along. Check plumbing, seals and
anything above this spot."* With no source marked at all it says so. The final
answer still honours the reading (see below), so the map shows the wet patch
around it, marked measured.

## Final solve

On the 0.10 m grid with the fitted parameters, starting from the coarse answer:
reading cells are projected into their interval, scoper regions into theirs
(scoper overrides readings, later tweaks override earlier ones). Then every cell
within 0.4 m of a reading (0.2 m of a moisture-line mark), on the same surface,
is pulled into the reading's interval with a smoothstep falloff (1 at the reading,
0 at the radius) and labelled measured. **The model never contradicts a reading.**

## Outputs (`MoistResult`, `result.report()`)

- per cell: `wetness` 0…1, `provenance`, state (dry / damp / wet);
- per wall face (`MoistFaceReport`): **tide line** (polyline segments of
  (metres along a→b, height) — the highest damp-or-wet point of each column,
  interpolated to the 0.2 contour), wet m² and soaked m² (split), skirting lm
  (split), max height, `reachesModelTop`, confidence;
- per wall cavity (`MoistCavityReport`): wet runs along the wall, wet length,
  max height, confidence (never measured unless there is an inspection reading);
- per room (`MoistFloorReport`): **wet floor polygons** (marching squares on the
  floor grid at the damp contour, one Chaikin pass, fill even-odd — inner rings are
  dry islands carved by readings), m² per covering (split), confidence;
- totals: wall lining m², floor m² (per covering), skirting lm — each
  measured / estimated / scoper — and cavity lm;
- **suggestions** (never decisions): `stripLining` per wet run on a lining face
  (extended 300 mm each side, cut = the run's typical tide height — 80th
  percentile of its columns, so one damp stripe doesn't set the cut for the
  whole wall — + 300 mm, rounded up to 600 / 900 / 1200; a local peak above the
  cut is named in the note, and above 1.2 m the note says to measure higher), `removeSkirting`
  runs, `liftFlooring` (carpet + underlay over the wet outline), `inspectCavity`
  (tiled faces, or wet inside a wall with no face suggested). Each suggestion
  carries the confidence of the area it comes from;
- **confidence** per area: `0.6 x coverage + 0.4 x agreement`, where coverage is
  the mean over the area's wet cells of `exp(−distance to nearest reading / 1 m)`
  (scoper cells count as covered; readings on either face count for the cavity
  behind, at 60 %) and agreement is the share of the area's readings the physics
  explained on its own (0.5 when none). No readings on the surface caps it at 0.3.
  High ≥ 0.66, medium ≥ 0.4, low below;
- fit report: parameters, objective before / after, number of solves, and for
  every reading the measured state, the physics' wetness and whether it was
  explained;
- `MoistDebug.wall / floor / summary`: text heatmaps for logs (the tests print
  the owner's ensuite case into the CI log).

## plan.json — `markup.moistureModel` (optional, additive)

```jsonc
"moistureModel": {
  "version": 1,
  "visit": "v1",                 // optional: whose readings to use (default: latest values)
  "hoursSinceEvent": 48,         // optional: time horizon; default from the source types
  "tweaks": [                    // the scoper's corrections, applied in order (later wins)
    { "id": "k1", "kind": "brush", "surface": "floor", "points": [[3.1, 1.2], [3.3, 1.25]],
      "radius": 0.25, "state": "dry", "at": "ISO8601" },
    { "id": "k2", "kind": "brush", "surface": "face", "wallId": "w3", "side": "b",
      "points": [[1.20, 0.30]], "radius": 0.2, "state": "wet" },          // wall points = [metres along a->b, height]
    { "id": "k3", "kind": "tideLine", "wallId": "w3", "side": "b",
      "points": [[0.2, 0.45], [1.4, 0.38], [2.3, 0.30]] },               // dragged tide line
    { "id": "k4", "kind": "floorOutline", "points": [[2, 0], [3.1, 0], [3.0, 1.6], [2, 1.7]] },  // dragged wet floor outline
    { "id": "k5", "kind": "barrier", "points": [[2.0, 1.5], [2.0, 2.3]] }, // "no spread past here" (sealed threshold)
    { "id": "k6", "kind": "source", "sourceId": "s1", "intensity": "heavy",  // or a number; fixes it (not fitted)
      "type": "shower", "placement": "cavity" },                           // optional overrides
    { "id": "k7", "kind": "lining", "wallId": "w3", "side": "a", "value": "tiled" },   // plasterboard | tiled | render
    { "id": "k8", "kind": "construction", "wallId": "w3", "value": "masonry" }         // stud | masonry
  ],
  "params": {                    // written by the solver: what the fit chose (informational)
    "floorSpread": 0.82, "rise": 1.15, "lining": 1.0, "volumes": { "s1": 1.9 }
  },
  "solved": {                    // written by the solver: last result, ready to draw
    "engine": "1.0", "inputsHash": "9f2c…", "cellSize": 0.1, "hours": 720, "fitted": true,
    "secondSourceLikely": false,
    "totals": { "wallLiningM2": {"measured":…, "estimated":…, "scoper":…, "total":…},
                "floorM2": {…}, "skirtingLm": {…}, "cavityLm": 1.6,
                "floorByCovering": [ { "covering": "carpet", "m2": {…} } ] },
    "faces":    [ { "wallId": "wS", "side": "b", "roomId": "r2", "lining": "plasterboard",
                    "wetM2": {…}, "skirtingLm": {…}, "maxHeight": 0.42, "reachesModelTop": false,
                    "tideLine": [[[0, 0.41], [0.05, 0.41], …]],
                    "confidence": { "score": 0.81, "level": "high", "readings": 4 } } ],
    "cavities": [ { "wallId": "wS", "runs": [[0, 1.5]], "wetLm": 1.5, "maxHeight": 1.1, "confidence": {…} } ],
    "floors":   [ { "roomId": "r2", "polygons": [[[2.0, 0.0], …]], "wetM2": {…}, "byCovering": […], "confidence": {…} } ],
    "hints":    [ { "readingIds": ["m4"], "surface": "cavity", "wallId": "e", "along": 2.0, "height": 0.35,
                    "pos": [8, 2], "roomId": "B", "improvement": 0.97, "message": "…" } ],
    "suggestions": [ { "kind": "stripLining", "suggestion": true, "wallId": "wS", "side": "b",
                       "from": 0, "to": 1.8, "cutHeightMm": 900, "m2": 1.62, "lm": 1.8, "note": "…" } ]
  }
}
```

- The **inputs** are the plan (walls, openings, rooms, `markup.floors`,
  `markup.floorThresholds`, `markup.sources`, `markup.readings`,
  `markup.thresholds`, `markup.visits`) plus `moistureModel.visit`,
  `hoursSinceEvent` and `tweaks`. The solver is deterministic, so any phone gets
  the same answer from the same inputs. `solved.inputsHash` (FNV-1a 64 of a
  canonical description of the inputs) tells a reader whether `solved` is stale.
- `params` and `solved` are **outputs**; the fit always starts from the material
  defaults, never from stored params, so results don't drift with history.
- Sources may carry the optional `type` (MoistSourceType raw value),
  `intensity` (name or number) and `placement: "floor"`; readings and sources
  `side` as above. Old documents need none of it.
- Swift: `MoisturePlan.input(plan:visit:options:)`, `MoistModel.run(input)`,
  `result.report()`, `MoisturePlan.modelJSON(result, report:, previous:)`,
  `MoisturePlan.adding(tweak, to: plan)`.

## Determinism and speed

No randomness, no dictionary iteration in any output path (Swift hashing is
seeded per process), fixed iteration caps and tolerances, ties in the flood
broken by filling equal-cost cells together. `testSameInputSameOutput` checks
bit-identical results. Target: < 50 ms for a typical 3–6 room job in a release
build on the phone. The test suite runs an unoptimised (Debug) build on a CI
simulator, so its bound is looser; it prints the measured time and cell count
for a synthetic 5-room, 9 x 7.5 m house.

## Limits and caveats

- **It's a model.** Material constants are reasonable defaults from restoration
  practice, not lab measurements; the fit adjusts four kinds of multiplier and
  nothing else. Where there are no readings, results are physics guesses — that
  is what `estimated` and the confidence are for.
- Floors are flat: no falls, no slab cracks, no subfloor voids; water does not
  run downhill across a floor.
- Only up to 1.2 m of wall is modelled; roof and ceiling leaks are approximated
  as a face source at that height. Ceilings are not modelled.
- Walls are one stud or masonry layer; double-brick cavities, wet-area
  membranes on floors (other than through the tiled lining and tile covering),
  hidden cabinetry, kickboards and the like are not modelled.
- Coincident duplicate walls from a scan (one per room) would each get faces;
  the plan builder normally merges them.
- Threshold factors and free-water costs are judgement; the scoper's barrier
  and threshold types correct them.
- Meter readings are comparative and material-dependent; the scale treats all
  materials alike, using the job's thresholds and reference readings.
- "Second source likely" is a pointer for investigation, not a finding.
