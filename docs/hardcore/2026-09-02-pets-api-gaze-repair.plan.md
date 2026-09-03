# Plan — pets: new /api/pets contract, gaze-table repair, submit-a-pet (2026-09-02)

Tier: **large** (3 slices) · Mode: add-feature + fix · Autonomous (gates printed, not asked) · Security lane: yes (user input, file upload, external calls, entitlement gating)

## Deliverable
1. **Cursor tracking fix for circular ("wraps") pets.** Backend tables (Misha's port of build_full.py) are not circularly monotone near the top: Cat v4 hops 58→156→53→25→178→143 inside a 20° cone; Chicken 7 reversals; Alpaca 21. The app animates *through* every intermediate frame, so each reversal is a visible spin, and every top crossing detours through the front-facing tail frames (the "returns to center" Simon reported twice). App-side repair so the app is robust to noisy data, plus a proper top crossing.
2. **Adopt the new /api/pets contract**: paginated listing (`paginated=1`, fixed `timestamp`, walk `info.last_page`), `is_premium` → PRO badge + paywall gate, `description` carried.
3. **Submit-a-pet** (`POST /api/pets/store`, multipart `photos[]` 1–5 jpeg/png/webp, optional `name`, `description`): sheet with drop zone / open panel, JPEG normalisation, upload, local "In review" record shown in the grid.
4. Client-answer txts on the Desktop in /lehastyle (cursor item 4, availability thread, 16:9 vs 1:1, update for team).

Non-goals: Vision-based photo quality filter (separately quoted, Simon has not said go); category filter (no categories endpoint exposed for pets); pipeline (Python) changes; iOS app.

## Observable acceptance criteria
- AC1 `GazeTableRepair.circular` on each live wraps table (fixtures = today's API dump) returns a table with exactly one direction reversal around the ring (the seam) — test `testLiveTablesBecomeCircularlyMonotone`.
- AC2 For Cat v4 the seam chord ends land at 51 (before seam) / 148 (after seam) ±3, both visually "up" frames (contact sheet: 45=up, 150=up) — test `testCatV4ChordEnds`.
- AC3 `PetPlayhead` with a chord (51…148, N=181) driven from pose 53 to target 143 never emits a pose in 60…140 and never in 0…50/149…180 (i.e., it cuts across the chord instead of detouring through the front frames) — test `testChordCrossingSkipsFrontDetour`.
- AC4 `PetPlayhead` without a chord produces bit-identical trajectories to the pre-change implementation over 2,000 random (value, target, wraps) steps — test `testNoChordMatchesLegacy`.
- AC5 Remote mirrored pets get `pivotUp = max(angleTable)`, `pivotDown = min(angleTable)` (fix_pivots.py rule) — test `testPivotsFollowTableExtremes`. Must NOT alter bundled pets.
- AC6 `RemotePetService` fetches every page: with the live backend (10 pets, per_page 24 → 1 page; verified also with per_page=2 → 5 pages in a curl run) the catalog shows all 10 remote pets. Log line `RemotePetService: loaded 10 pets from N page(s)`.
- AC7 A pet with `is_premium: true` shows a PRO pill; clicking it as a non-Pro user opens the paywall and does not place the pet (Release semantics; Debug `isPro` is hard-wired true, so gate logic is verified by reading the code path + a unit test of the decision helper).
- AC8 Submit sheet: 0 photos → Submit disabled; 6th photo refused with a message; non-image or < 512 px shorter side refused with the reason; on success an "In review · <name>" tile appears in the grid and persists across relaunch (`Application Support/WallpicsMac/Pets/submissions.json`).
- AC9 Upload sends `multipart/form-data` with `photos[]` (jpeg), optional `name`, `description`, `x-auth`/`x-token`/`x-guest-id`; a 422 from the server surfaces the server `message` inline. Verified against prod with the validation path only (no photos → 422 shown); success path exercised against prod once with a clearly labelled test pet only if the user asks (creates an admin-review record).
- AC10 `xcodebuild -scheme WallpicsMac -configuration Debug build` succeeds with no new warnings in changed files; app launches; Pets tab renders; a circular pet placed on the desktop tracks the cursor across the top without dipping to the front pose (manual, screenshot/GIF).

## Patterns to mirror
- Header/auth: `WallpicsMac/Services/WallpaperAPI.swift:293` `applyAuthHeaders`, `ensureOK` :312, `transport` :319.
- Pagination model: `WallpicsMac/Models/Wallpaper.swift:143` `WallpaperPage.PageInfo` (`current_page`/`last_page`).
- Photo picking: `WallpicsMac/Widgets/Editors/WidgetEditorModel.swift:117` (NSOpenPanel + security scope), drop zone `WidgetEditorView.swift:270`.
- Premium badge: `WallpicsMac/Views/WallpaperCard.swift:88` (`BadgePill(role: .status) { Text("PRO") }`), paywall: `PaywallPresenter.show()`, `store.state.isPro` via `@Environment(StoreKitService.self)` (`ContentView.swift:106,161`).
- Persisted JSON state: `WallpicsMac/Pets/Core/PetStore.swift` (atomic write, corrupt file moved aside).
- Error surfacing: `BrowseView.swift:393` inline `ErrorBanner` pattern.

## Tasks
| # | Slice | File(s) | RED test | Validate |
|---|---|---|---|---|
| 1 | gaze | `Pets/Render/GazeTableRepair.swift` (new) | AC1, AC2, AC5 | swiftc harness `scratch/gazetests` |
| 2 | gaze | `Pets/Render/GazeMap.swift` (PetPlayhead chord routing) | AC3, AC4 | harness |
| 3 | gaze | `Pets/Core/PetModels.swift` (`gazeLoop`), `PetCatalog.swift` (apply repair to remote), `PetRenderer.swift` (pass chord) | build | xcodebuild |
| 4 | api | `PetCatalog.swift` RemotePetService paging, `isPremium`, `description`; `PetModels.swift` fields | AC6 (log) | xcodebuild + run |
| 5 | api | `PetsView.swift` PRO pill + gate; `PetsViewModel` | AC7 | build + manual |
| 6 | submit | `WallpaperAPI.swift` `submitPet` multipart; `Pets/Core/PetSubmission.swift` (draft, validation, store); `Pets/Views/PetSubmitSheet.swift` — **delegated (opus)** | AC8, AC9 | build + prod 422 probe |
| 7 | submit | `PetsView.swift` toolbar button + sheet + In-review tiles | AC8 | build + manual |
| 8 | docs | Desktop txts, handoff | — | read-through |

## Risks / rollback
- Repair heuristics could mis-handle a future clean table → AC1/AC4 guard; repair only runs for remote pets with `wraps == true` (mirrored pets untouched except pivots).
- Chord routing changes animation only when a chord exists (remote wraps pets); bundled pets unchanged (AC4).
- Upload: sandbox `files.user-selected.read-only` present; images are re-encoded to JPEG (≤ 2048 px long edge) so HEIC/TIFF never reach the backend; 20 MB per-file cap.
- Rollback: revert the commit; no migrations; `submissions.json` is additive.

## Decisions
- Repair lives in the app (not only the pipeline) because tables come from a backend we don't control and the app must not spin on bad data.
- Chord (direct cut between the two "up" ends of the loop) chosen over "route through 0/N seam" because the tail frames are all front-facing; this is exactly the top-center lock Simon sees.
- Vision photo filter deliberately not built (quoted separately, not approved). Basic structural checks only.

## Outcome (2026-09-02)
- AC1–AC5, AC7 (decision helper): `Tools/GazeTests/run.sh` → 57 passed, 0 failed (Release semantics) + Debug-semantics run passes "debug builds stay unrestricted".
- AC6: app relaunch shows all 10 backend pets in the grid (screenshot `scratchpad/live2/app4_small.png`); listing walked via `paginated=1&per_page=24&timestamp=…`.
- AC9: validation path against prod → HTTP 422 `{"message":"The photos field is required."}`; success path NOT exercised (would create an admin-review record).
- AC10: `xcodebuild … BUILD SUCCEEDED`; Cat v4 placed on the desktop, cursor swept 0°→100°→315° (Quartz events), pet-window captures at 84/88/92/96/100° all show up-looking frames, no front-pose dip (`scratchpad/live2/sheet2.png`).
- Review gate (3 lanes + 2 round-2 lanes): 1 HIGH (premium gate bypass on restore) fixed and skeptic-confirmed; MEDIUMs fixed: chord clamp to clip length, hostile-table overflow clamp, thumbnails off-main, 2xx-with-error body, drop notice loss, persist failure surfaced, pending-tile reconcile, upload timeouts; LOWs fixed: log category, force unwrap, log privacy, name/notes caps.

## Deviations
- Project uses an explicit pbxproj (objectVersion 56, no synchronized groups): 3 new files registered by hand.
- Test harness lives in `Tools/GazeTests` (swiftc, no XCTest target in this project) instead of a test target.
- Sheet screenshot taken via Quartz click; two stray clicks during UI driving changed the local placement, restored from backup afterwards.
