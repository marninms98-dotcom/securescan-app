# SecureScan ↔ SecureSuite sync

Every job scanned in SecureScan is saved to SecureSuite (the company's Supabase
project), linked to its SecureSuite job when one is picked. Other phones can
open it, and Claude (in chat) can read it to write the report, quote or invoice.
This replaces SPEC.md's "no accounts, no network calls" for builds that have
sync configured; without it the app is exactly as before (local only).

Code: `ios/SecureScan/Sync/` (pure logic and its tests: `Sync/Logic/`,
`ios/SecureScanTests/SyncTests.swift`).

## Configuration

| Where | Name | Value |
|---|---|---|
| Repository secret | `SUPABASE_URL` | `https://<project>.supabase.co` |
| Repository secret | `SUPABASE_ANON_KEY` | the project's publishable (anon) key |
| Build setting (project.yml, default `""`) | `SUPABASE_URL`, `SUPABASE_ANON_KEY` | passed by `.github/workflows/testflight.yml` to `xcodebuild archive` |
| Info.plist | `SECURESCAN_SUPABASE_URL`, `SECURESCAN_SUPABASE_KEY` | `$(SUPABASE_URL)`, `$(SUPABASE_ANON_KEY)` |

Nothing is in source. Empty values (every CI simulator build, a local Xcode
build) = sync off: no sign-in screen, Settings shows "Cloud sync: Not
configured", no network calls.

## Signing in

SecureSuite accounts (Supabase Auth, email + password:
`POST /auth/v1/token?grant_type=password`). The session (access + refresh
token) is kept in the Keychain on this iPhone only and refreshed two minutes
before it runs out (one refresh at a time; Supabase rotates refresh tokens).
First launch shows "Sign in with your SecureSuite account" with a quiet "Use
without signing in"; Settings › SecureSuite signs in or out and shows the
name and role (`public.users`: `name`, `role`, `org_id`).

## What is stored where

**Row**: `public.scan_jobs`, one per job, `id` = the app's job id (the folder
name in `Documents/Jobs/`, lower-case).

| Column | From the app |
|---|---|
| `id` | the job id |
| `org_id` | filled by SecureSuite (`auth_org_id()`) |
| `job_id` | the linked SecureSuite job (`public.jobs.id`), or null |
| `title` | `<address> · <job/claim ref>` |
| `site_address` | the address as typed on the phone |
| `plan` | the whole `plan.json` (Contract 1 in SPEC.md); `{}` before the first scan |
| `files` | the manifest: `[{path, kind, bytes, sha256, updated_at}]` |
| `revision` | bumped by SecureSuite on every update; the app writes only with `revision=eq.<the one it read>` |
| `deleted_at` | set by an admin on the web (archive); the app then stops sending |

**Files**: private bucket `scan-files`, object path
`<org_id>/<scan job id>/<path in the job folder>`, for example
`2c9a…7e42/6b1f…9c10/photos/r3-full.jpg`.

| `kind` | Paths |
|---|---|
| `photo` / `photo_full` | `photos/<id>.jpg` (1280 px, the plan's) / `photos/<id>-full.jpg` (full resolution) |
| `audio` | `audio/NNN.m4a` voice notes |
| `transcript` | `voice.json` (recordings index; the text itself is in `plan.markup.notes`) |
| `readings` | `readings-raw.json` (every reading/mark/photo/source as logged, in AR world space) |
| `room` | `rooms/<n>.json` (RoomPlan CapturedRoom per room) |
| `model` | `model.usdz` (3D model) |
| `thumbnail` | `thumb.png` |
| `meta` | `job.json` (jobs list facts) |
| `link` | `securesuite.json` (`jobID`, `jobNumber`, `clientName`, `siteAddress`) |
| `worldmap` | `worldmap.bin` (ARWorldMap for return visits) |
| `visits` | `revisit-log.json` |
| `conflict` | `plan.conflict-<stamp>.json`, `conflicts/<stamp>/…` (see below) |
| `data` | anything else (`plan-frame.json`, `editor-names.json`, `needs-fix.json`, …) |

`plan.json` itself is not a stored file (it is the `plan` column). Recordings
in progress (`*.wav`), the `scan-open` marker and hidden files stay on the phone.

## How it syncs

- **When**: on launch and on return to the app; a few seconds after the plan
  editor saves; when a job screen closes; when the network comes back; every
  minute while the app is open (a cheap check of file sizes and dates; the
  org's revision list every two minutes). Never during a scan (the scan-open
  marker), never for demo jobs. Failures retry 15 s, 30 s, 1 min … up to
  15 min. Going to the background asks iOS for time to finish; anything left
  continues the next time the app is opened. A sync cut off half way resumes
  without re-sending finished uploads.
- **Only what changed**: each file's sha256 is compared with the manifest;
  small files go first (readings and photos before the 3D model).
- **Order**: files are uploaded, then the row is written, so the manifest
  never lists a file that is not stored.
- **Other phones' changes** (the row's revision moved): new or changed files
  are downloaded; the plan is taken as is if this phone did not change it,
  else merged — markup items are unioned by `id` (readings, sources, removals,
  notes, equipment, visits, scope items…); for the same id the newer
  `updated`/`takenAt` wins, else the server's; a reading's re-measurements
  (`history`) are unioned by visit. Geometry and settings stay this phone's
  (last writer). This phone's plan is kept as `plan.conflict-<stamp>.json`.
  `readings-raw.json`, `voice.json` and `revisit-log.json` are merged by id;
  any other file changed on both phones keeps this phone's copy and saves the
  other as `conflicts/<stamp>/<path>`. Nothing is merged into a job while it
  is open on screen ("New changes on SecureSuite · they're added when you
  leave this job").
- **Deletes**: deleting a job on a phone never touches SecureSuite (it shows
  again under "On SecureSuite"). A photo deleted on a phone drops out of the
  manifest; the stored object is not deleted. Only admins delete, on the web.
- **Other phones' jobs**: the jobs list shows "On SecureSuite" (the org's scan
  jobs not on this phone); tapping one downloads it into a job folder and
  opens it.

## Status the user sees

A tiny cloud on each job card and a line at the top of the job's Files tab:
Saved to SecureSuite (last synced time) · Syncing… (Uploading 3 of 12) ·
Waiting to sync · Waiting for network · Not signed in · Couldn't sync (one-line
reason, retrying in N min) · New changes on SecureSuite · Archived. No
banners or alerts.

## Reading a job from chat (Claude, via the Supabase tools)

Find the scan for a SecureSuite job:

```sql
select s.id, s.title, s.site_address, s.job_id, j.job_number, j.client_name,
       s.revision, s.updated_at, jsonb_array_length(s.files) as file_count
from public.scan_jobs s
left join public.jobs j on j.id = s.job_id
where s.deleted_at is null
  and (j.job_number = 'SW-2418' or s.site_address ilike '%Kingsway%')
order by s.updated_at desc;
```

Read the whole job (everything the report needs is in `plan`):

```sql
select id, title, site_address, job_id, plan from public.scan_jobs where id = '<scan job id>';
```

Useful parts of `plan` (Contract 1, SPEC.md): `rooms[]` (name, polygon),
`walls[]`, `markup.readings[]` (`n`, `value`, `material`, `history[]` per
visit), `markup.sources[]`, `markup.affected[]`, `markup.removals[]`,
`markup.equipment[]`, `markup.visits[]`, `markup.notes[]` (voice notes as
text, time-stamped), `markup.scope.items[]` (the quote lines), `markup.thresholds`.

```sql
-- Readings, latest value each
select r->>'n' as n, r->>'material' as material, (r->>'value')::numeric as value, r->>'takenAt' as taken_at
from public.scan_jobs, jsonb_array_elements(plan->'markup'->'readings') r
where id = '<scan job id>' order by (r->>'n')::int;

-- Site notes in time order
select n->>'t' as at, n->>'text' as text
from public.scan_jobs, jsonb_array_elements(plan->'markup'->'notes') n
where id = '<scan job id>' order by n->>'t';

-- The files and where they are stored
select f->>'kind' as kind, f->>'path' as path, (f->>'bytes')::int as bytes,
       org_id || '/' || id || '/' || (f->>'path') as storage_path
from public.scan_jobs, jsonb_array_elements(files) f
where id = '<scan job id>' order by kind, path;
```

A photo, audio file or model is then object `storage_path` in bucket
`scan-files` (e.g. `storage.objects` where `bucket_id = 'scan-files' and name = '<storage_path>'`,
or a signed URL from the Storage API). Photo names match the plan:
`photos/<reading or photo id>.jpg`, full resolution `photos/<id>-full.jpg`.

## Checked only against the real backend

The CI simulator has no backend; the screens are shown with a Debug-only fake
(`SECURESCAN_FAKE_CLOUD`, see `Sync/FakeCloud.swift`). Things to confirm with
real accounts are listed in the round report (RLS on `users`, `jobs` and
storage upserts; the revision trigger; request size for large plans; the
`jobs` embed and `job_number` type).
