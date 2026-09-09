# Handoff — pets: new API, gaze repair, submit-a-pet (2026-09-02)

## State
Working tree has the full change, uncommitted (Alex commits himself). Build green, harness green, review gate clear.
Plan: `docs/hardcore/2026-09-02-pets-api-gaze-repair.plan.md`.

## What worked (evidence)
- Root cause of "weird cursor movement": backend gaze tables for circular pets are not circularly monotone (Cat v4 top cone 58→156→53→25→178→143; Chicken 7 reversals; Alpaca 21). `GazeTableRepair.circular` (LIS-based seam search + seam-outlier trim + slope extrapolation) fixes all six live tables; `PetPlayhead` chord routing cuts between the two "up" frames instead of detouring through the front tail. Verified live on Cat v4 (window captures during an 84°→100° sweep show only up frames).
- Mirrored pets: pivots now derived from table extremes in-app (fix_pivots.py rule), so Misha's stored jsons need no patch.
- New listing contract: paginated walk with fixed timestamp, `is_premium` → PRO pill + paywall (tap, context menu, restore path, idle path), `description` carried.
- Submit-a-pet: `PetSubmitSheet` + `PetSubmissionModel/Store` + `WallpaperAPI.submitPet` (multipart, JPEG normalisation ≤2048px, 512px min side, 20 MB cap, name 80 / notes 500). 422 path verified on prod.
- `Tools/GazeTests/run.sh`: 57 checks incl. legacy-equivalence differential test for the playhead.

## What did not work / open
- Chicken clip is choppy at the source (motion in ~9-frame steps) — content, needs regen by Misha.
- `/api/pets/store` success body shape unknown → id parsed leniently; "In review" tiles only resolve when a `serverPetID` was returned and later appears in the listing. Backend needs a submission-status endpoint.
- No categories endpoint for pets → category filter not built.
- Stale cached remote pets (ids 4, 5 removed server-side) still hydrate from disk until the first refresh replaces the list (pre-existing).
- Vision photo-quality filter (quoted separately) intentionally not built.

## Exact next step
1. Alex reviews the diff, commits, pushes `feature/mvp-release`, bumps build for TestFlight.
2. Send Desktop txts: `simon-cursor-answer.txt`, `simon-aspect-ratio.txt`, `simon-availability.txt`, `pets-api-update-for-team.txt`.
3. When Misha answers with the store response shape / status endpoint, wire `PetSubmissionStore.reconcile` to it.

## Round 2 (after Slack sweep, same day)
- Preview card capped at 400 pt (`PetsView.previewMaxHeight`), grid visible without scrolling (Simon item 3).
- Neutral (look-at-camera) pose only when the cursor is off the pet's screen or in the face dead zone (`GazeMap.target(cursor: CGPoint?)`, `DesktopPetManager.handleTick`), per Simon "center only when the cursor is out of the desktop". Harness: 59 checks.
- Full-month Slack digest: `docs/hardcore/2026-09-02-slack-digest.md`. Desktop txts: `simon-cursor-answer.txt`, `simon-availability.txt`, `simon-ios-items.txt`, `simon-aspect-ratio.txt`, `pets-api-update-for-team.txt`, `mac-build-notes.txt`.
- iOS items (live thumbnails, signed profiles, icons-separately regression, premium theme hiccup) are promises in `simon-ios-items.txt`; they need the current iOS repo, not the 08-19 Downloads snapshot.

## Round 3 (2026-09-03, Simon's video overview)
- Source: DM video (2:05, voice-over transcribed with whisper, `scratchpad/simon/audio.srt`). Asks: preview ~2x smaller (done day before), all sizes bigger with Large ~2x, cursor returning to center / not reacting (day-before fix, never pushed), Browse "icon going out".
- `PetSize.pointHeight` 300/460/700 (was 190/280/380); `DesktopPetManager.globalRect` caps subject height at 80% of the screen; preview `heightFactor` = pointHeight / screen height (true proportion).
- Brand pill in `ContentView` toolbar: `.fixedSize()` + `.lineLimit(1)` — at 1512 pt width the label collapsed and the capsule stretched vertically.
- Verified: harness 59/59, BUILD SUCCEEDED, captures at 1512×982 (`scratchpad/live4`).
- Still uncommitted: HEAD `c06434c`. Push commands in the chat. Simon's future idea: per-type sliders on the home screen (statics 2x2/1x1, live, widgets, pets).

## Round 4 (2026-09-03 evening) — redesign
- Pets tab side-by-side (>=1180 pt): 660 pt column (preview + compact settings), grid right. Browse "Home" mode with per-type rails + Pets rail, See all → type pages unchanged; `HWheelScroll` chaining. Plan/outcome: `docs/hardcore/2026-09-03-pets-browse-redesign.plan.md`.
- Photo analysers removed from upload per Alex (separate paid job). Desktop txts: `simon-today-tomorrow.txt`, `wallpics-mac-changes-sep2-3.txt`, `mac-build-notes.txt`.
- Still uncommitted (HEAD c06434c). Note: an Xcode-beta debug session of the app was killed during verification.

## Round 5 (2026-09-04) — inverted pets, in-app gaze analysis
- Simon: new pets (13–18) "completely inverted", "everyone is different". Backend tables and my centroid-based measurement agreed with each other but not with the frames: on long-snouted / big-eared animals the head mass swings away from the gaze direction when the head turns (dachshunds, elephant).
- New `WallpicsMac/Pets/Render/GazeAnalyzer.swift`: decodes the clip (AVAssetReader → 128 px alpha mask + gray), per-frame symmetry / head-top pitch / distance-to-neutral; neutral = most symmetric frame in the last 10%; lateral runs from symmetry (first = right, second = left — generation prompt order); loop extended outward until front-like; pitch → vertical, distance → magnitude, horizontal = residual with prompt-order sign; 64-bucket nearest-angle table with neutral fallback (>50°); pan clips (no pitch swing / no up ends) map only the two lateral runs. Result cached as `gaze-analysis.json` (version + clip byte size).
- `RemotePetService`: pets publish first, analyses run afterwards one by one in a detached task, each republishes its pet; placed pet restarts via `DesktopPetManager.refresh()`. `buildSpecies` prefers the analysis (table, neutral, loop) for wraps pets.
- Validation: Python reference (`scratchpad/newpets/promptmap8.py`) → compass sheets correct for all 12 circular pets; Swift CLI `Tools/GazeAnalyze/run.sh <mov…>` matches the reference (L/R/U/D within a few frames on all 12). Live check on the dachshund: 7/8 directions clean, the 8th coincided with the user moving the mouse.
- Harness recreated at `Tools/GazeTests` (it had vanished from disk, never committed): 87 checks.
- Also: `name: null` pets decode (Pet 13… placeholder), repo re-materialized twice after iCloud eviction — move the repo off iCloud Desktop.

## Round 6 (2026-09-04, later) — backend-first by Alex's decision
- Alex: "i want backend to do it, delete all manual stuff from app". Removed `GazeAnalyzer.swift`, `GazeTableRepair.swift`, the analysis cache, the in-app repair and the pivot override. App is a pure consumer again: `angleTable`, `neutralPose`, pivots from the API; new optional `gaze.loopStart` / `gaze.loopEnd` drive the top-crossing chord (no chord when absent → plain wrap).
- Pipeline updated instead: `~/Desktop/wallpics-pet-pipeline/gaze_map.py` (validated on 12 clips) is now called by `build_full.py` for table, neutral and loop; `HOW-TO-ADD-A-PET.txt` documents it. Zip for Misha: `~/Desktop/wallpics-pet-pipeline-2026-09-04.zip` (also in Downloads). Note: `~/Desktop/misha-gaze-map.txt`.
- Until Misha regenerates gaze json for pets 7–18 and passes loopStart/loopEnd, circular pets behave as before (inverted ones stay inverted). Harness trimmed to playhead/chord/gate tests: 18 checks.

## Round 7 (2026-09-09) — centre cut with dissolve
- Simon on the side-aware routing build: a centre frame still flashes, and centre → bottom-right should be one motion. Cause: leaving/returning to the neutral pose walked through the front tail frames between neutral and the loop.
- `PetPlayhead.step` now returns `Bool` (cut): a move that crosses the loop edge (neutral ↔ any look) jumps straight to the target; a chord teleport also reports a cut. `PetRenderer` uses two `AVSampleBufferDisplayLayer`s under a `PetStackLayer` container and cross-dissolves 0.16 s on a cut (`flushAndRemoveImage` on the standby layer first). Container propagates `contentsScale`, sublayers autoresize.
- Harness: 40 checks incl. `testCentreCuts`. Build green. Live visual check of the dissolve not driven (user active on the Mac); static render checked.
