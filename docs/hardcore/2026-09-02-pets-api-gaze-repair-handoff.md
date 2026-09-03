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
