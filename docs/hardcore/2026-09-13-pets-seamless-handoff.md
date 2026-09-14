# Handoff — pets: seamless top, calm motion, new bundled set (2026-09-13)

Plan: `docs/hardcore/2026-09-13-pets-seamless.plan.md`. Working tree uncommitted (Alex commits).

## Why (evidence)
- Alex: "cut on top, jumpy behaviour, exotic animals". Misha (Slack #wallpics-app 09-11): new generation "from scratch…
  no jump at the top" = pure-360 clip + connector clip (needs regenerating every pet). Simon 09-11: "I would like to finish with pets".
- Build-130 recording frames (`scratchpad/slack/alex_seq2.png`, 8 fps): head pops from up-right to up-left inside 125 ms
  (the app teleports between the two "up" frames of the sweep, poses 50 ↔ 146 on pet 17) and whips through the loop.
- WallPets engine (`~/Desktop/wallpets-kit/app/Sources/Natchan/PetEngine.swift`): scrubResponse 9, scrubMaxSpeed 110 f/s on a
  192-frame loop. Ours before: 11, 270 poses/s on 181 poses + ×3 wake hurry + ×3 detour boost = 2.5–7× faster.
- Served-pet audit (`scratchpad/live/*/check.json`): the top edge never touches the frame; side touches on 17 are a toy ball;
  Simon's 09-08 "cropping" screenshot (`scratchpad/slack/simon_crop_small.png`) is the snout cut by the SOURCE frame edge.

## What changed
### Pipeline `~/Desktop/wallpics-pet-pipeline/petmaker.py` (v3; v2 kept as `petmaker_v2_backup.py`)
- Seam: `seam_pair` picks the two up poses (one per half) that look most alike while still up (cost = head-band gray diff
  + 0.5·(1−IoU) + 0.5·pitch shortfall); the table is restricted to poses between them and its extremes forced to exactly
  those two; the 7 poses before the second are dissolved into a copy of the first (`blend_rgba`, premultiplied), the
  second pose IS the first (pixel-identical), blend poses never appear in `angleTable`. report.json `seam{first, second,
  diff, blend, wrap_bucket}`, flag `seam_off_axis` if the wrap is > 30° from up, `no_seam` if no up pair was found. pet.json/API contract unchanged.
- Edge feather: when the analysis sees the subject touch a source edge, every frame gets a 2.5 % alpha ramp on that edge
  (`feather_edges`, constant across poses); report `clipped_edges` (analysis, per side), `feathered_edges` (list),
  `touched_edges` (output poses that reached each edge).
- Alpha sources: `--key alpha` (or auto when the stream has alpha) uses the clip's own alpha (used for the WallPets cat).
- Oversized sources (> 4096 px) fail with a pre-scale hint (the 6K legacy clips were pre-scaled to 1620 px).
- `HOW-TO-ADD-A-PET.txt` V3 section. Tests: `python3 -m unittest test_petmaker` → 45 OK (new: SeamTests ×3, EdgeAndAlphaTests ×4, SeamAfterSwapTests ×2, OpaqueAlphaTests ×1).

### App (`wallpics-mac`)
- `PetPlayhead`: response 9 / max 0.7 turns·s⁻¹ × gazeSpan (≈105 poses/s normal; calm 0.45, alert 1.1), acceleration ramp
  0.12 s (`speed`, `lastDirection`), detour boost 2 → 0.8, wake hurry 3 → 2 over 30 ticks; `step` returns `true` on a seam
  teleport; `SeamFade` (80 ms in over, 60 ms out under — no coverage dip).
- `PetRenderer`: `PetStackLayer` container with two `AVSampleBufferDisplayLayer`s; on a cut the incoming layer fades in over
  the outgoing one (legacy pets with a visible seam get a soft cut; v3 pets show nothing because both frames are identical).
- Bundled pets rebuilt with v3 (`Resources/Pets`, 195 MB): ginger, dog, leopard (original 6K clips), natchan (WallPets
  `timeline.mov` frames 0–191, alpha), dachshund (17), golden-puppy (13), tabby (23), dalmatian (21), monkey (15),
  elephant (16). `pm-*` and `ginger-full` removed. `PetProfileDefaults` has a natchan entry.
- Harness `Tools/GazeTests/run.sh`: 94 PASS / 0 FAIL (legacy-equivalence test replaced by overshoot/arrival, acceleration,
  pacing, fade and cut tests). `xcodebuild … Debug build`: BUILD SUCCEEDED.

## Verification
- v3 outputs for 16 clips (`scratchpad/v3/<id>`): `v3check.py` — seam frames identical (max abs diff 0), blend poses absent
  from tables, wrap buckets 46–53 (up), no top-edge alpha in any output. Compass sheets checked by eye for all 16: L/R/U/D
  correct (shiba 4 has no right turn in the source; alpaca 11 flagged extra_object — neither bundled).
- Live capture (2026-09-14, after Alex approved the keychain prompt): `Tools/petcapture.py <dir> top` on the pet Alex had
  placed (backend pet 27, medium, bottom centre): 97 window captures at ~86 ms during a scripted right → up → left sweep.
  Strip `scratchpad/cap_v4/strip.png`: right → up-right → up → up-left → left with no pop across the top; the one odd-looking
  early frame is the clip's own down/down-left pose (compass `live/27`). A first capture showed a stale frame flashing on a
  seam cut; cause was the fade reusing a layer whose image had not been cleared — `beginFade` now ignores a cut while a fade
  is active and `finishFade` clears the outgoing image; rebuilt, harness 94/94, re-captured clean.

## Review gate (5 independent lanes, all findings fixed)
| Sev | Finding | Status |
|---|---|---|
| HIGH | `swap_lateral` rebuilt the table without the seam pins | fixed: `pin_seam` shared, re-applied after swap + test |
| HIGH | opaque alpha track treated as the matte | fixed: auto falls back to colour keying, `--key alpha` raises + test |
| MEDIUM | per-frame feathering flickers between poses | fixed: edges decided once per clip from the analysis |
| MEDIUM | `pivotUp` could point outside the seam pair | fixed: pinned to the seam range |
| MEDIUM | `feathered_edges` double-counted | fixed: per-pose set, `touched_edges` counts + `feathered_edges` list |
| MEDIUM | display sublayers got implicit 0.25 s frame animations | fixed: actions disabled on both layers + in `layoutSublayers` |
| MEDIUM | second cut mid-fade raced an async flush | fixed: plain `flush()`, no image removal |
| MEDIUM | dropped frames never logged | fixed: error on nil buffer, throttled notice on not-ready |
| LOW | feather wider than a thin crop crashed | fixed: clamped per axis, `main` fails closed with exit 2 |
| LOW | `SEAM_OFF_AXIS_DEG` looser than the app's apex window | fixed: 30° |
| LOW | seam hold kept the display link alive; pause mid-fade froze a blend | fixed: `isHolding`, `settle()` on pause |
| LOW | direction sign on exact seam bound restarted the ramp | fixed: sign from the moving leg |
| LOW | circular clip without a seam not flagged | fixed: `no_seam` flag |
Pipeline suite 45 OK, harness 94 PASS, build green after all fixes.

## For Misha
Drop-in replacement, same CLI, same output files and API fields. Re-run on every pet; nothing to add to the API.
The app-side fade covers the old assets until then.

## Open
- Apex "up" is only as high as the source shows; the two seam frames are the most similar pair, not the highest.
- The Debug app blocks on the login keychain while the screen is locked (`KeychainStore` in `WallpaperAPI.init`); harmless
  but it means a launch during lock shows nothing until unlock.

## Round 2 (2026-09-14) — Alex's WallPets vs WallPics comparison clips
- Clips: `scratchpad/cmp/a_1217.mov` (WallPets, Natchan) and `b_1215.mov` (WallPics preview, backend pet 27). At 10 fps the
  "weird transition" is the two-layer seam fade showing a double exposure on a legacy asset (two distinct seam frames); the
  "whole circle" is the head sweeping through intermediate poses on long moves — WallPets does the same, but faster and
  with a subtler clip, and it settles back to front after 4 s.
- App: fade and `PetStackLayer` removed (single `AVSampleBufferDisplayLayer`, hard cut; v3 assets have identical seam
  frames so nothing shows), `PetSensitivity.turnsPerSecond` 0.9/1.5/2.2 (half circle ≈ 0.4 s at normal), ramp 0.1 s, wake
  hurry 1.5, `restAfter` 4 s, idle grace 5.5 s. Harness 89 PASS, build green.
- Bundled set: 14 pets, every name suffixed " test" (Alex's ask): ginger, dog, leopard, natchan, dachshund, golden-puppy, tabby,
  dalmatian, monkey, elephant + golden-bow (24), ribbon-dachshund (22), cream-cat (27), duck (14). 275 MB. Pending pets 31–38
  on the dashboard have no animation yet; 5 (full-body dachshund) scored 45 and was skipped. `Tools/installpets.py` installs
  built pets (`--keep` adds to the catalog).
- Live captures on the bundled cream cat were polluted by Alex's own mouse (the pet follows the real cursor); not used as evidence.
- Clean captures on the bundled cream cat (`scratchpad/cap7`, `cap8`, Alex away from the mouse): up-right → up → up-left → left
  with no pop or ghost at the top; right ↔ left sweeps complete in ~0.5 s. The pet ignored the first cursor jump after launch
  because `resolveTarget` needed a previous sample to detect movement — the first sample now counts as movement.

## Round 3 (2026-09-14 13:30) — ghost frame at rest, full rebuild
- Alex's screenshots (ribbon dachshund, duck looking up): a dissolve pose shown at REST. Tables exclude the blend poses, so the
  leak was the app's seam hold: `restsAcrossSeam` kept `value` wherever it was inside the ≤4-pose band below the seam end,
  which overlaps the 7 dissolve poses. Fix: the hold now parks `value` on the seam end itself (identical frame on both sides),
  never on a transit pose. Harness 90 PASS (new check: hold from a transit pose lands on the end), build green.
- All 14 test animals rebuilt with the current petmaker (`scratchpad/v5`), seam frames identical (max diff 0) and no blend pose in
  any table (checked numerically), installed, app rebuilt.
- Live verification blocked: the debug app (pid 9188) is attached to the Xcode debugger (`ps` STAT `SX`, ignores SIGKILL,
  `open` times out); it does not tick while paused, so scripted captures show a frozen pet. Resume/stop it in Xcode, then run
  `Tools/petcapture.py`.

## Round 4 (2026-09-14 14:00) — stitch on asymmetric clips
- Alex: some pets look perfect at the top, others "relaunch the clip" at the stitch. Cause: on dalmatian/duck/golden puppy the
  second up pass never reaches the apex (pitch 0.45–0.69 vs 1.0 on the first pass, and yawed), so the two seam frames differ
  a lot (diff 0.25–0.34) and a 7-pose dissolve at 225 poses/s (~30 ms) reads as a snap. ffmpeg `minterpolate` morph was tried
  (`scratchpad/morph/*_morph.png`): worse than the dissolve on these pairs (garbled).
- petmaker v3.1: dissolve length 8–28 poses scaled by the seam diff (`seam_blend_length`, capped at half the second half),
  incoming frame slides from the outgoing head centre into place during the dissolve (`head_centre`, `shifted`, report
  `seam.blend_shift`). Strips: `scratchpad/v6/*_blendstrip.png`. Suite 45 OK. All 14 test animals rebuilt (v6) and installed:
  seam frames identical, no blend pose in any table, blend 7–18 poses. Build green. Zip: `~/Desktop/wallpics-pet-pipeline-2026-09-14.zip`.
- Alex runs the app from Xcode (pid attached to the debugger); he must re-run from Xcode to pick up the new Resources/Pets.

## Round 5 (2026-09-14 15:00) — motion morph at the stitch
- Alex's 1:47 PM clip (ginger, 12 fps, `scratchpad/cmp2/c_zoom.png`): a double-exposed frame flashes for ~1 frame every time
  the cursor crosses the top = the dissolve poses passing in transit. A dissolve trades the pop for a ghost.
- petmaker v3.2: `seam_morph` — ffmpeg `minterpolate` (mci/aobmc/bidir/epzs) on premultiplied colour and alpha separately,
  after the head alignment, for pairs with seam.diff ≤ 0.25; sanity gate (alpha coverage ≥ 90 %, total premultiplied path
  ≤ 3× the direct distance) falls back to the aligned dissolve; report `seam.method`. Strips: `scratchpad/v7/*_final.png`
  (golden puppy: real head turn, no double image; ginger: eyes glide). Dalmatian and duck stay on the dissolve.
- Suite 47 OK (new SeamMorphTests, gates compare premultiplied images). 14 test animals rebuilt (v7), 12 morph / 2 dissolve
  … dalmatian, duck; seam frames identical, no blend leak; installed; build green. Zip `~/Desktop/wallpics-pet-pipeline-2026-09-14.zip`.

## Round 6 (2026-09-14 15:30) — morph reverted, plain cut is the default
- Alex judged the morph worse than before. Default is now `--seam cut`: no synthetic poses at all; the second up frame is a
  byte copy of the first (the two most similar real up frames), the app cuts between identical frames. `--seam dissolve` and
  `--seam morph` remain opt-in. Suite 48 OK (new SeamCutTests). 14 test animals rebuilt (v8) and installed, build green.
