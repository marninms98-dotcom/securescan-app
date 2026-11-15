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

The rhythm is: **scan a room → mark it up in AR → next room**.

1. Tap **New scan**. The address fills in from GPS, so check it and fix it if
   needed. Add the claim number if you have one, then tap **Start scanning**.
2. **Scan the room.** Walk slowly round it with the phone pointed at the
   walls, following the on-screen hints until the walls, doors and windows are
   all outlined. Then tap **Room done**.
3. **Talk through the job at any time:** tap **Notes** (bottom left). It turns
   red and shows a timer while it records. Just talk normally ("skirting here
   is 38, we'll cut to 600"). It keeps recording between rooms and while you
   mark up. Tap it again to stop. Only sound is recorded, never video. The
   first time, the phone asks to use the microphone and speech recognition:
   tap **Allow**.
4. When the room is saved you get three choices: **Mark up this room** (the
   big one), **Scan next room** and **Finish**.
5. **Mark up this room.** The camera comes back with the room's walls drawn
   faintly over it. Pick what you're doing on the strip along the bottom
   (Reading · Moisture · Photo · Source · Equipment · Removal), put the
   **crosshair** on the spot, and the big button says exactly what a tap will
   do. Everything appears on the wall or floor as soon as it's logged:
   - **Reading** (*Log reading*): type the % on the number pad, pick the
     material, **Save**. A coloured pin with its number and value sits on the
     wall at that height. Turn on *Reference (dry) reading* for dry controls.
   - **Moisture** (*Hold to draw moisture line*): press and hold, and sweep the
     crosshair along the top edge of the wet area. The line draws on the wall
     as you go, shaded down to the floor; let go to finish. It can go round a
     corner onto the next wall. A single tap adds one point. **Undo stroke**
     takes the last sweep away. Switch to *Wet floor area* to trace the wet
     part of the floor the same way (hold and sweep round its edge), or tap its
     corners and **Close area**.
   - **Photo** (*Take photo*): pick a caption and **Save**.
   - **Source** (*Mark source here*): tap a label (Burst pipe, Flexi hose…).
   - **Equipment** (*Place air mover*): point at the floor where it stands;
     pick the type, add its asset number if you like, **Place**. A box stands
     there on the floor.
   - **Removal** (*Start removal here*): pick the item and **Start here** on
     where the cut starts. A red band grows from there to the crosshair; point
     at the end on the same wall and tap **End here**, pick the height and
     **Save**. For *Flooring*, tap each corner on the floor (the section fills
     in as you go), then **Done** or **Whole room**, the floor type and
     *Underlay too* if needed.
   - **Change something:** tap its marker. You can change the value, material
     or label, nudge it **5 cm higher/lower**, **Move…** it (aim at the new
     spot and tap **Move here**) or **Delete** it.
   - **Undo last** and the item list work as on the scan screen. If tracking
     is lost, logging pauses until it recovers.
   Tap **Done** (top left) to go back to the three choices.
6. **Scan next room**: stand in the doorway, tap it and scan the next room,
   then mark it up. You can still tap **Log** on the scan screen itself if you
   prefer; it works the same way without the drawing.
7. Tap **Finish**. The app joins the rooms together and builds the plan and
   the 3D model. This takes a few seconds. Your voice notes are then turned
   into text on the phone (no internet needed once the phone has its speech
   model); a small "Transcribing voice note…" message shows while it works.
8. On the **Plan** tab, tap room names to rename them and check the mark-up.
   Your spoken notes show in the site notes, in time order with the readings;
   tap one to fix a word.
9. Need to add something after the scan? Tap **Record note** at the top right
   of the job screen, talk, and tap it again to stop.
10. Tap **Export**. **Assessment report (PDF)** is the report for the insurer
   or builder: cover, findings, the marked-up plan, wall drawings, a card for
   every photo showing where it was taken, and the schedules. Tap a number on
   the plan in the PDF to jump to that photo. Your logo, colour and company
   details (set once in the report's *Details*) are remembered for every new
   job. **Job pack** makes one zip file with the summary, plans, wall
   elevations, readings, photos, the report PDF, your voice recordings and the
   3D model, and opens the share sheet so you can email it or save it to
   Files. The **3D** tab shows the readings, the moisture line and the
   source in the model, and can save a picture of it.

### Going back to the same job (return visits, or marking up later)

Open the job and use **Files › Return visit** (or the *Return visit* button
on the visit bar). The app starts a new visit if the last one was on an
earlier day.

1. First the app tries to recognise the room from the first scan by itself.
   Move the phone slowly; if it works within about 10 seconds, it says so.
2. If not, it asks for two corners. On the small plan, tap the room you are
   standing in. Corners **A** and **B** are picked for you (far apart); tap
   *Change corner A/B* and then a corner on the plan if you'd rather use
   others. Point the crosshair at corner A, where the two walls meet the
   floor, and tap **Set A**. Do the same for B.
3. Blue lines are drawn on the floor where the saved walls are. If they sit
   on the walls, tap **Looks right**.
4. You're now on the same mark-up screen as during the first scan, and new
   items go into today's visit. In **Reading** mode, aim at a saved reading
   and the big button says **Re-measure 3**: tap it, type the new value,
   **Save**. It turns green with a tick, and the bar shows "5 of 12
   re-measured". A hint at the top points to the nearest one still to do.
5. Tap an air mover's box for **Mark removed today**, or a red removal band
   for **Mark done + after photo** (the camera view is kept as the "after"
   photo).
6. If the markers drift off their spots, tap **Realign**.

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
