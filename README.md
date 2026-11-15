# SecureScan

A free replacement for the Polycam floor-plan feature, built for SecureWorks WA.

Walk a property with an iPhone that has LiDAR (your 15 Pro Max does). The app
scans each room, and you can log moisture readings, the moisture line, photos
and the water source as you go. Each one is pinned to the exact spot on the
wall where the phone was pointing. You can also talk as you go: the app records
your voice and turns it into written site notes. For every job it saves:

- a clean **floor plan with dimensions**, plus your markup: water source, the
  affected area, walls to cut out, and moisture readings
- **wall elevations** showing how high up the wall the moisture reached
- a **3D model** with the readings shown in it
- a **Moisture & scope sheet** PDF for the insurer
- your **site notes** (what you said, as text, with the time you said it)
- a **Job pack**: one zip with everything above plus a written summary, ready
  to hand over for writing the report

Jobs are filed by street address. Everything stays on the phone, and you can
also see the files in the Files app under *On My iPhone › SecureScan*. There are
no accounts and no cloud.

> **Status:** the code compiles and its tests pass on GitHub's Macs, and it runs
> on the iPhone Simulator with a demo job. Scanning, the microphone and
> sharing have not yet been tried on a real iPhone.

---

## Getting it onto your phone

### Option A: a Mac with Xcode and your free Apple ID

1. On a Mac, install **Xcode** from the App Store. Then open Terminal and run
   `brew install xcodegen` (this needs [Homebrew](https://brew.sh)).
2. In Terminal, go to this folder and run `cd ios && xcodegen generate`. Then
   open `ios/SecureScan.xcodeproj`.
3. In Xcode go to **Settings › Accounts** and add your Apple ID.
4. Click the **SecureScan** target, then **Signing & Capabilities**. Set **Team**
   to your name ("Personal Team"). If Xcode says the bundle ID is taken, change
   `com.secureworkswa.securescan` to something unique.
5. Plug in the iPhone and pick it at the top of the Xcode window. Press **Run** (▶).
6. The first time, the iPhone will ask you to trust the developer. Go to
   **Settings › General › VPN & Device Management**, trust your Apple ID, and
   turn on **Developer Mode** if the phone asks for it.

Limits of a free Apple ID, according to Apple's membership comparison page:

- the app **stops opening after 7 days**, and you have to plug in and press
  Run again to renew it
- no more than **3 apps** installed this way per device
- you can't send the app to anyone else

### Option B: no Mac, using GitHub

1. Push this folder to a GitHub repository.
2. The workflow in `.github/workflows/ios-build.yml` runs by itself on Apple's
   build machines. It compiles the app and runs the maths tests. A green tick
   means the code compiles. If it fails, the error log is attached to that run
   as `xcodebuild-logs`.
3. **That green tick does not put anything on your phone.** An iPhone will only
   install an app that Apple has signed. Without a Mac, the usual way to get
   it signed is **TestFlight**, and that needs:
   - a paid **Apple Developer Program** membership: **US$99 a year** (about
     **A$149** per an Australian provider's FAQ; Apple shows the local price
     when you enrol)
   - extra setup that has **not** been done here: signing certificates and an
     App Store Connect API key stored as GitHub secrets, plus a workflow step
     that uploads the build. Expect a developer to need an hour or two for
     this the first time.
   - *Not verified here:* TestFlight builds stay installable for about 90
     days, and then a new build has to be uploaded.

   Paid membership also removes the 7-day limit from Option A.

### Option C: no Mac, a Windows PC and a USB cable (free)

Every build on GitHub also produces **SecureScan.ipa**, an unsigned copy of the
app. A sideloading tool on a PC signs it with your own Apple ID and installs it.

1. On this repository's page open **Releases** and download `SecureScan.ipa`
   (`build-stable` is the last tested version; `build-main` is the newest work).
2. On the PC install Apple's **iTunes** and **iCloud** (from Apple's website,
   not the Microsoft Store), then a sideloading tool such as **Sideloadly**.
   This is a third-party tool, not Apple's; it asks for your Apple ID to sign
   the app.
3. Plug in the iPhone, tap **Trust** on the phone, drag `SecureScan.ipa` into
   the tool, enter your Apple ID and start.
4. On the iPhone: **Settings › General › VPN & Device Management**, trust your
   Apple ID; then **Settings › Privacy & Security › Developer Mode**, turn it
   on (the phone restarts).

The same free Apple ID limits as Option A apply: the app stops opening after
**7 days** (install it again the same way; your jobs stay on the phone) and at
most **3 apps** per device. *Not yet tried with this app on a real phone.*

---

## Using it on site

### Aim and tap

Everything you log is aimed with the **crosshair** in the middle of the
screen. Before you tap, the label under it says what you're on and how high:
"Wall · 1.20 m · Kitchen", "Floor", "Ceiling · 2.41 m", "Cabinet · 0.85 m".
If there's nothing to hit, the big button says why ("Point at a wall", "Move
slowly") instead of doing nothing. All the buttons are in the bottom third,
big enough for gloves. Each save gives a little buzz, the pin appears where you
aimed (readings coloured green / orange / red for dry / damp / wet), and an
**Undo** button shows for 6 seconds.

| To log | Taps |
|---|---|
| A reading | big button, type the number, **Save** (2 taps + digits). The tool stays picked, so the next one is the same again. |
| A moisture-line point | 1 tap (or hold and sweep in mark-up) |
| A photo | 1 tap; **Add caption** on the message afterwards if you want |
| The source | 2 taps (button, label) |
| Equipment | 2 taps (button, **Place**); air movers: aim the airflow, 1 more |
| A wall strip-out | 4 taps (start, **End here**, height, **Save**); aimed within 15 cm of a corner it snaps to the corner, and aiming the end at the cut height pre-picks the height (snapped to 300 / 600 / 1200 / full) |
| A whole wall strip-out | **Whole wall** (when the crosshair is on a wall), height, **Save** — 3 taps |
| A floor section | 1 tap per corner, then **Done**, floor type, **Save** |

**Scan and mark together (new).** On the New scan screen, **Scan and mark
together** scans the room and lets you log everything above on the same
screen while you walk round (Inspect: Reading · Moisture · Photo · Source;
Scope: Equipment · Wall removal · Floor removal · Photo). The walls appear as
they're found; a banner says "Slow down", "Move closer" or "More light" when
RoomPlan asks. If no walls turn up, **Use the classic scan** takes you back
with everything you logged. Make it the default in **Settings › Mark while
scanning** once you've tried it. It is new and hasn't been tested on a phone
yet.

Tap any item in the list to change its value, material or caption, or delete
it; swipe to delete.

**Nothing is lost if the app closes.** Every item is written to the phone the
moment you save it, and its photo a moment later. Rooms are saved when you tap
Room done. If the app is killed mid-room you keep every item and every photo
that had finished saving, and the rooms already done; you lose the walls of the
room you were in. When you open the job again a banner says "12 items from an
unfinished room were kept" — tap **Place them** and they are placed against the
saved rooms (or by position).

If you switch from Scan and mark together to the classic scan, anything logged
so far is removed first (you're asked): the classic scan has its own camera
session, so those items couldn't be placed reliably.


SecureScan works the way a job does, in three modes:

- **Inspect** — what's wet and why: readings, the moisture line, photos and
  the source. This makes the **Inspection report**.
- **Quote** — what we'll do about it: air movers, dehumidifiers and the other
  gear, and what gets ripped out (walls and floors). This adds up the
  **Quote**.
- **Monitor** — every visit after that: re-measure the same points, redraw the
  line, mark gear removed and work done. This makes the **Monitoring
  report**, and the **Final report** on the last visit.

The rhythm on site is: **scan a room → mark it up in AR → next room**.

### First visit

1. Tap **New scan**. Check the address (it fills in from GPS) and add the
   claim number if you have one, then **Start scanning**.
2. **Scan the room.** Walk slowly round it with the phone pointed at the walls
   until the walls, doors and windows are outlined, then tap **Room done**.
3. **Talk any time:** tap **Notes** (bottom left) and just talk ("skirting
   here is 38, we'll cut to 600"). It keeps recording between rooms and while
   you mark up; tap again to stop. Only sound is recorded.
4. When the room is saved, tap **Mark up this room** (or **Scan next room** /
   **Finish**).
5. **Mark up in AR.** The camera shows the room with its walls drawn faintly.
   Pick **Inspect** or **Quote** at the top; the strip at the bottom shows
   that mode's tools, and the big button always says exactly what a tap does.
   Put the **crosshair** on the spot:
   - **Inspect**
     - *Reading* — **Log reading**, type the %, pick what you're reading
       (Skirting, Wall, Floor, Ceiling, Cabinet / vanity, Other), **Save**.
       A coloured pin with its number and value appears where you pointed:
       on the wall, or on the floor, ceiling, cabinet or whatever else you
       pinned it to. The photo of that spot is attached; tap **Photo added**
       to leave it off. Turn on *Reference (dry) reading* for dry controls.
     - *Moisture* — press and hold **Hold to draw moisture line** and sweep
       along the top of the wet area; let go to finish. It can turn a corner
       onto the next wall. A tap adds one point; **Undo stroke** takes the
       last sweep away. Switch to *Wet floor area* to trace the wet floor the
       same way (or tap its corners and **Close area**).
     - *Photo* — **Take photo**, pick a caption. *Source* — **Mark source
       here**, tap a label (Burst pipe, Flexi hose…).
   - **Quote** (a tally at the top keeps count: "2 AM · 1 DH · 2.6 m² lining
     · 3.2 m² flooring"; tap it to see the list)
     - *Equipment* — pick Air mover, Dehumidifier, Air scrubber or Heater,
       point at the floor where it goes and tap **Place air mover**. A box
       stands there. For an air mover, then point the phone the way the air
       should blow (an arrow follows you) and tap **Set airflow direction**.
       Tap the box later and **Re-aim airflow** to change it.
     - *Wall removal* — pick Plasterboard, Skirting, Cabinetry or Other, aim at
       where the cut starts and tap **Start … removal here**. A red band grows
       to the crosshair; aim at the end on the same wall, **End here**, pick
       the height, **Save**.
     - *Floor removal* — aim at the first corner and tap **Start floor
       removal**, then **Add corner** at each corner (the section fills in),
       **Done** or **Whole room**, then the floor type and *Underlay too*.
     - *Photo* — as in Inspect.
   - **Change something:** tap its marker to change the value, material or
     label, nudge it **5 cm higher/lower**, **Move…** it (aim, **Move here**)
     or **Delete** it. **Undo last** and the item list work as everywhere.
     If tracking is lost, logging pauses until it recovers.
   Tap **Done** (top left) to go back to the three choices.
6. **Scan next room** and mark that one up. (You can still tap **Log** on the
   scan screen itself; it has every type.)
7. Tap **Finish**. The app joins the rooms, builds the plan and the 3D model,
   and turns your voice notes into text on the phone.

### For the crew: scoping without prices

Phones start with prices hidden. The crew can do the whole scope — readings,
equipment, airflow, strip-outs — and the app shows quantities only: in AR the
mode is called **Scope**, the tally reads "2 AM · 1 DH · 2.6 m² lining", and
the job screen offers **Scope of works** instead of the Quote. No rates or
totals appear anywhere on that phone.

The office turns prices on in **Jobs › ⋯ › Settings › Show prices**. The first
time, it asks you to set an **office PIN** (4–8 digits); after that, turning
prices on needs that PIN. Turning them off needs nothing. The PIN is a
convenience lock to keep prices off the crew's screens, **not security**.

Until the plan editor update that can hide prices is in the app, a phone with
prices hidden can't export the report, scope or job pack (the buttons say
*after update*), because those could include prices.

### Arriving on site: see the scope

If someone has already scoped the job, open it and tap **See scope on site**
(it shows how many items are done, e.g. "3 of 7 done").

1. The app lines the camera up with the saved scan (by itself, or with two
   corners, as for a return visit).
2. Everything in the scope appears in the room: red hatched bands on the
   walls to strip out and hatched floor sections to lift, each with its tag
   (X1, F1… the same as on the documents), and ghost boxes where the
   equipment goes with its asset tag, plus an arrow showing which way each
   air mover blows.
3. Aim at something: the bottom shows what it is ("X1 · remove plasterboard,
   wall w3, 2.20 × 1.20 m") and one button: **Mark placed: AM-03** once the
   gear is down, or **Mark done + after photo** once the strip-out is done.
   The **3 of 7 done** chip opens the whole list.
4. Nothing can be changed by accident here; **Edit scope** switches to the
   Scope tools if something really needs changing.
5. Can't line the camera up? Tap **Use the list instead**: the same list
   with a small plan, where things can be marked placed or done (the after
   photos can be added later).

### Getting the documents

At the top of the job screen are the documents this job can produce:
**Inspection report**, **Quote** (**Scope of works** when prices are hidden),
and after more than one visit **Monitoring report** (or **Final report** once the last visit is the final one). Tap one:
the app makes the PDF and opens the share sheet to email or save it. If a
button says *after update*, the plan editor in this build can't make that
document yet; nothing you marked up is lost.

On the **Plan** tab you can rename rooms and check or fix any mark-up; your
spoken notes are in the site notes, in time order. **Export › Job pack** makes
one zip with everything (plans, readings, photos, the report, recordings and
the 3D model). Need to add a note later? **Record note** at the top right.

### Later visits (Monitor)

Open the job and tap **Files › Return visit** (or *Return visit* on the visit
bar). A new visit starts if the last one was on an earlier day.

1. The app tries to recognise the room from the first scan by itself (move
   the phone slowly, up to about 10 seconds).
2. If not, it asks for two corners: tap the room you're in on the small plan,
   aim at corner **A** where two walls meet the floor and **Set A**, then B.
3. Blue lines show the saved walls on the floor. If they sit on the walls,
   tap **Looks right**.
4. You're in **Monitor** (Inspect and Quote are there too):
   - *Re-measure* — aim at a saved reading; the button says **Re-measure 3**.
     Type the new value, **Save**; it gets a tick and the bar shows "5 of 12
     re-measured". A hint points to the nearest one still to do.
   - *Moisture* — draw today's line; last visit's line is shown fainter.
   - *Photo* as usual.
   - *Done / removed* — aim at an air mover's box: **Mark removed**; aim at a
     red removal band: **Mark done + after photo**.
5. If the markers drift off their spots, tap **Realign**.

Everything is saved as you go. No LiDAR, or the camera won't line up? Use
**Re-measure on the plan** to do the same re-measuring on the plan.

If the scan or the merge fails, your rooms, readings and recordings are still
saved. Open the job and use **Files › Regenerate plan**. Regenerating keeps all
your markup and notes. If a voice note couldn't be turned into text, its
recording is still kept: open **Files**, find it under *Voice notes* and tap
**Transcribe again**.

**No LiDAR, or trying it on the Simulator?** Use **⋯ › Create demo job**. It
builds a 3-room house from a simulated scan, with readings, a moisture line,
a water source, drying equipment, a few demo photos and some spoken notes, so you can try the Plan, 3D and Files
tabs without scanning anything.

---

## If you open the project in Xcode yourself

The committed `ios/SecureScan.xcodeproj` is only regenerated by CI. On a branch CI hasn't built, run
`brew install xcodegen && cd ios && xcodegen generate` first, then open `ios/SecureScan.xcodeproj`.

## For a developer

- `ios/project.yml` is the XcodeGen spec (iOS 17+, no third-party packages).
  `web/editor.html` is bundled as a resource. The app has its own icon.
- `ios/SecureScan/Core/PlanBuilder.swift` converts the RoomPlan scan into
  plan.json. It's pure maths and has unit tests in `ios/SecureScanTests`.
  `SimulatedScan.swift` builds the test house.
- The data contracts are in `docs/SPEC.md`.
- CI (`.github/workflows/ios-build.yml`) runs on GitHub's `macos-26` image with
  the newest Xcode 26 on it. If the build fails, the "Summarise compiler errors"
  step lists the `error:` lines; the full logs are attached as `xcodebuild-logs`.
- Permissions the app asks for: camera (scanning, photos in the editor),
  location (address, once), microphone and speech recognition (voice notes,
  transcribed on the device only), and "add to photo library" (only when you
  pick *Save Image* in a share sheet). The app declares background audio so a
  voice note keeps recording when the screen locks.
- Voice notes: recorded as 16 kHz WAV while recording (so a crash loses
  nothing), converted to AAC mono `audio/NNN.m4a` when stopped; index in
  `voice.json`. Transcription uses SpeechAnalyzer/SpeechTranscriber on iOS 26+
  and on-device SFSpeechRecognizer otherwise (`Storage/Transcriber.swift`).
- Job pack: the editor posts `exportPack`; the app adds plan.json, audio,
  model.usdz and the report PDF and zips with `NSFileCoordinator`
  (`Storage/JobPack.swift`).
- Report PDF (`Job/ReportPDF.swift`): the editor's report HTML is laid out in an
  off-screen 595 pt wide WKWebView as tall as the document, one
  `createPDF(configuration:)` per page box, merged with PDFKit, then link
  annotations are added from `reportLinks`. CI runs it on the simulator
  (`SECURESCAN_EXPORT_REPORT=1`) and commits `ci-screenshots/assessment-report.pdf`
  and `report-check.txt`.
- App-wide settings (`Core/AppSettings.swift`): `markup.brand` and
  `markup.rateCard` are remembered on save and added to plans without them
  before they load.
- Return visits (`Revisit/`, maths in `Core/Alignment.swift` and
  `Core/Revisit.swift`): plain ARKit world tracking in an ARSCNView. The first
  scan saves `worldmap.bin` (ARWorldMap) next to `plan-frame.json`. A return
  visit relocalises onto it, or aligns from two or three wall corners with a
  rigid 2D fit. Re-measurements go into each reading's `history`. Raw events
  of every visit are in `revisit-log.json`. **This screen has not yet run on
  a device.**
- The 3D tab uses SceneKit, which Apple deprecated in the iOS 26 SDK. Expect
  deprecation warnings; it still builds and runs.
