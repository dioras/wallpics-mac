# Handoff — lock screen: custom uploads static / aerial not always active (2026-09-20)

Plan: `docs/hardcore/2026-09-20-lockscreen-custom-uploads.plan.md`. Working tree uncommitted (Alex commits). No version bump.

## Why (Slack fizizi DM, 09-19 → 09-20)
- Simon 09-19 16:46: "it does not work in custom uploads" + IMG_1785.MOV. In the video the custom Kling upload shows "Wallpaper set. Lock screen animates too" while the lock screen is the static poster; the same clip from the catalog animates after ~25 s of "Preparing lock screen…". Simon is a free user (watermark button visible).
- Alex 09-20 06:51: "Will be home closer to evening and will check custom uploads".

## Root cause
`LockScreenAerial.isInstalled` accepted "any Desktop section in Index.plist points at our aerial". Index.plist keeps a section per Space×Display ever seen (Alex's Mac: 4901 Desktop/Idle sections). `setDesktopImageURL(poster)` only rewrites the active display's section, so stale sections kept the previous aerial and the check said "installed" → `sync` reported `.ready` without installing → poster on the lock screen. Custom uploads hit it more because their transcode is fast (Kling 1312×1580 24 fps → 4 s vs ~25 s for a 2704×1512@60 catalog clip). Clip format is NOT the cause: the transcoded Kling clip played from the aerial slot on this Mac (verified by swapping it in and out; slot restored byte-identical).

## What changed
- `Services/LockScreenIndex.swift` (new, pbxproj IDs AD/AC000092): `desktopPoints(to:in:)` = every Desktop section that has Choices holds exactly our aerial; `applyAerialChoice`/`collectAerialIDs`/`aerialChoice` moved here.
- `LockScreenAerial`: strict `isInstalled` (index strict + slot size == `State.clipSize`); clip cache `Application Support/WallpicsMac/LockScreenClips/<sha256(path|size|mtime|variant)>.mov`, 3 kept, prune only touches 64-hex names; `rollBack` skipped when a newer install owns the state; new `Failure.lost` ("macOS replaced the lock screen clip — set the wallpaper again.", 7 translations added by script).
- `LockScreenService`: cached clip → poster skipped (`willInstallImmediately`), otherwise poster → transcode → wait ≥ 3 s after the poster → install; verify at +3/+10/+20 s, ≤ 2 repairs through the same serial queue, else `.failed(.lost)` + poster re-applied; `reassert()` reinstalls when the aerial is gone (skipped while `.failed`); every failure re-applies the poster.
- `WallpaperRenderer`: `reassert()` on wake, unlock, screen change; poster re-apply timestamps the settle window.
- Harness `Tools/GazeTests`: `testLockScreenIndexStrict` (RED: missing symbol → GREEN; also records the old contains-check is fooled by a stale section). 115/115.

## Verification
- `bash Tools/GazeTests/run.sh` → 115 passed, 0 failed.
- `xcodebuild -scheme WallpicsMac -configuration Debug build` → BUILD SUCCEEDED; Release `CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.
- Transcode probe (same code as the app, `scratchpad/transcode.swift`): Kling .mov → 60.25 s hvc1 1312×1580 in 4 s, status completed.
- Review gate: security PASS (2 LOW fixed); silent-failure 1 HIGH + 2 MEDIUM + 2 LOW (all fixed); quality 1 HIGH + 1 MEDIUM + 5 LOW (all fixed except the count-only cache cap, accepted); round 2 (fresh reviewer) → APPROVE, 1 LOW fixed: after the last repair one more +3 s check, else `.failed(.lost)`. Final: Debug + Release BUILD SUCCEEDED, harness 115/115.
- NOT verified: the fixed flow in the running app on a lock screen (keychain prompt blocks scripted launch; lock screen cannot be screenshotted). Alex: build the direct (unsandboxed) .dmg, set a custom upload, lock within 5 s → poster, then after "Lock screen animates too" → animation; set it again → no "Preparing…" (cache hit, log "Lock screen clip reused from cache").

## Open / not done
- Clip cache is count-capped (3 clips, up to ~1 GB for 4K60) and survives disabling the feature; byte cap not added.
- `WallpicsMac-Direct.entitlements` still unreferenced by any configuration: the direct .dmg is a manual Release build with sandbox off. A "Direct" configuration would remove that step.
- idleassetsd deletes unknown files in `aerials/videos` (our backup is gone on this Mac); retire then just removes the slot and macOS re-downloads. Pre-existing.
- Alex's /lehastyle skill rewritten to v2.0.0 from 339 Slack messages; note for Simon at `~/Desktop/simon-lockscreen.txt`.

## Exact next step
Alex: read `~/Desktop/simon-lockscreen.txt`, run the direct build once through the custom-upload → lock test above, commit, build the .dmg, send it to Simon.
