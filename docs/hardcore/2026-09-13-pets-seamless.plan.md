# Plan — pets: seamless top, calm motion, exotic animals, new bundled set (2026-09-13)

Tier: large · mode: change-feature · autonomous (Alex not watching; gates printed, not asked)

## Deliverable
1. `~/Desktop/wallpics-pet-pipeline/petmaker.py` v3: the apex seam of a circular clip is baked out (the second "up" pass
   dissolves into a copy of the first, so the app's teleport frames are identical), the seam pair is chosen by visual
   similarity, source-edge clipping is feathered and flagged, clips with a real alpha channel are accepted (`--key alpha`),
   sources above 4096 px are rejected with a clear message (pre-scale), tests extended.
2. `wallpics-mac` app: WallPets-like pacing (response 9, ~0.65 turns/s normal, acceleration-limited start), wake hurry
   and detour boost reduced, two-phase (no coverage dip) fade on seam teleports for legacy pets, bundled pets replaced.
3. Bundled pets rebuilt with v3: ginger, dog, leopard (from the original 6K clips), natchan (WallPets cat, lookaround
   slot only, frames 0–191 of timeline.mov), and vault pets 17, 13, 23, 21, 15, 16. Old `pm-*`, `ginger-full` removed.
4. Desktop note in /lehastyle, handoff, memory.

## Evidence behind the plan
- Slack: Misha 09-11 "done from scratch… no jump at the top at all" = pure-360 generation + connector clip (09-07 plan).
  Simon 09-11 "I would like to finish with pets". Simon 09-08 "cropping issues" screenshot: snout cut at the frame edge.
- Served pets audit (`scratchpad/live/*/check.json`): top edge never touches; sides touch on 7, 17, 22, 27; 17's is a
  toy ball from the source; raw 17 frame 100 has the ear on the source's left border (source clipping).
- Build-130 recording (`scratchpad/slack/alex_seq2.png`, 8 fps): head jumps from up-right to up-left within 125 ms
  (seam teleport 50↔146) and whips across the loop. WallPets engine: scrubResponse 9, scrubMaxSpeed 110 f/s on a 192-frame
  loop (0.57 loops/s). Ours: 11, 270 poses/s on 181 (1.5 loops/s), ×3 wake hurry, ×3 detour boost.

## Acceptance criteria (observable)
- A1 petmaker on `animated_17.mp4`: report has `seam: {first, second, diff}`; frames `second` and `first` of pet.mov are
  pixel-identical (max abs diff 0 after ProRes decode within 2/255); the poses `second-m+1 … second-1` are not in
  `angleTable`; the app's `apexChord` for that table equals `first...second` (harness check).
- A2 all 13 vault raws + 3 legacy + natchan build with exit 0; compass sheets show L looking left, R right, U up
  (visual check, listed per pet in the handoff); `python3 -m unittest test_petmaker` green.
- A3 frames touching a source edge get a feathered alpha (≥ 12 px ramp at 720 p) and the report flags `subject_clipped`
  with the edges named.
- A4 harness `Tools/GazeTests/run.sh`: 0 FAIL; new tests: acceleration-limited start (first tick advance < 40 % of cap),
  max speed per sensitivity, seam fade state machine (enter → phase1 → phase2 → idle), legacy no-wrap pets still reach
  target and never overshoot.
- A5 `xcodebuild` Debug succeeds; app launches with the new bundled catalog (10 pets), no `pm-*` folders in Resources.
- A6 window-only captures of the placed pet at 60 ms cadence during a scripted top crossing on a v3 pet show no frame
  where the head pose differs from both neighbours by more than a sweep step (visual check on the strip).

## Tasks
T1 petmaker: rgba decode + `--key alpha`; MAX_DIMENSION error text says "pre-scale".
T2 petmaker: seam pair search (visual diff at analysis scale over the head band between candidates within the up
   regions of each half), dissolve region, table exclusion, report + json (`seamFirst`, `seamSecond` informational).
T3 petmaker: edge feather + clipped-edge names in report.
T4 tests for T1–T3 (synthetic clips already exist in test_petmaker).
T5 batch build all clips → `scratchpad/v3/<id>`; compass + edge + seam metrics; fix what fails.
T6 app: PetPlayhead pacing/acceleration; PetSensitivity constants; wake/boost; harness tests.
T7 app: PetRenderer two-phase fade on teleport; harness for the fade timing (pure function).
T8 app: bundled pets swap (Resources/Pets, catalog.json, PetProfileDefaults natchan entry), build.
T9 verify: harness, build, live captures; review workflow; handoff; Desktop note; memory.

## Not building
Misha's pure-360 generation (content pipeline), a new API field, optical-flow morphing, in-app gaze analysis.

## Risks / rollback
Pacing change alters feel for Simon — constants are in one place (`PetSensitivity`, `PetPlayhead`), easy to retune.
Pipeline v2 stays as `petmaker_v2_backup.py`.
