# Plan — lock screen: custom uploads static, aerial "not always active" (2026-09-20)

Tier: standard · mode: fix · autonomous (Alex away; gates printed, not asked). Branch: feature/mvp-release (Alex commits).

## Evidence (Slack fizizi DM D0B9LHK7VJM, 09-19 → 09-20; video IMG_1785.MOV)
- Simon 09-19 16:45: "installed the .dmg but I dont see a posibility to add it on a lockscreen" → 16:46 "all good I see it, it does not work in custom uploads" → 17:04 video.
- Video (90 s, recorded 20:01–20:02 local): Uploads tab, custom Kling upload "kling_20260920_VIDEO_Make_the_c_140_1 (1)" shows **"Wallpaper set. Lock screen animates too — lock your Mac to see it."**, lock screen at 8:01 shows the **static poster**. Then Browse → Spider-Man (Preparing…) → catalog "Tung Tung Sahur desktop wallpaper" (Preparing… ~25 s) → lock at 8:02 **animates**. Simon is a free user (Remove watermark button visible).
- Alex 09-20 06:51: "Will be home closer to evening and will check custom uploads".

## Root cause (verified in code + on this Mac)
1. `LockScreenAerial.isInstalled` = "state matches AND slot file exists AND *any* Desktop section anywhere in Index.plist points at the slot". Alex's Index.plist has **4901** Desktop/Idle sections (stale Spaces/Displays, SystemDefault). After `setDesktopImageURL(poster)` the active section becomes the poster while stale sections keep the aerial → false "installed" → `sync` returns `.ready` **without installing** → app claims "animates too", lock screen shows the poster. Trigger: picking a wallpaper while a previous prep is in flight (state file still names the previous asset), or any external desktop change.
2. Custom uploads transcode fast (Kling 10 s 1312×1580 24 fps → 60 s HEVC in **4 s** here; catalog 2704×1512@60 takes ~25 s) so the aerial is written seconds after the poster call; nothing re-verifies the desktop choice afterwards, at unlock, wake or launch. No check that the slot file is still our clip (idleassetsd cleans the folder: our `*.wallpicsbak.mov` backup is gone on this Mac).
3. Format is NOT the cause: the transcoded Kling clip was placed in the aerial slot on this Mac and the desktop played it (frames differed between two screenshots); slot restored byte-identical (md5 bf0ac04a…).
4. Every re-set re-transcodes (up to a minute for 4K); users lock before "Preparing…" finishes → static.

## Deliverable
- `Services/LockScreenIndex.swift` (new, pure): `desktopPoints(to:in:)` = every Desktop section with Choices holds exactly the aerial choice for `id` (≥ 1 section required); `applyAerialChoice`, `collectAerialIDs` moved here.
- `LockScreenAerial`: strict `isInstalled` (index strict + slot size == recorded clip size); `State.clipSize`; clip cache `Application Support/WallpicsMac/LockScreenClips/<sha256(path|size|mtime)>.mov`, keep 3; `cachedClip(for:)`, `store(clip:for:)`; `reselect(id)` for repair.
- `LockScreenService`: `willInstallImmediately(kind:assetURL:)` (cached clip present) → renderer skips the poster; otherwise poster first, transcode, install waits ≥ 3 s after the poster; after install verify at +3 s / +10 s and repair (re-write index + reload) ≤ 2×; `reassert()` re-syncs when the aerial is no longer the desktop choice.
- `WallpaperRenderer`: skip poster when the service installs immediately; `reassert()` on wake, unlock and screen change for animated kinds.

## Acceptance criteria
- A1 harness `Tools/GazeTests/run.sh`: new `testLockScreenIndexStrict` RED on current logic (a plist with one image section + one aerial section must NOT count as installed) → GREEN.
- A2 `xcodebuild -scheme WallpicsMac -configuration Debug build` → BUILD SUCCEEDED; Release (CODE_SIGNING_ALLOWED=NO) → BUILD SUCCEEDED.
- A3 Second set of the same asset does not transcode (cached clip reused: log "Lock screen clip reused from cache").
- A4 Must NOT: change the App Store (sandboxed) path; touch paywall/quota; add code comments; commit.

## NOT building
Backend anything; watermark on the lock clip; UI redesign of the status line.

## Deviations
- Repair after install re-runs the full `install(clip:assetPath:)` from the cached clip instead of a lighter "re-select index" step, so a replaced slot file (idleassetsd) is fixed by the same path. Capped at 2 repairs per install.
- RED evidence is a missing-symbol compile error on `LockScreenIndex.desktopPoints` (harness has no way to exercise the old `isInstalled` without touching the real wallpaper store); the harness additionally records that the old contains-check IS fooled by the stale fixture.
- Review gate ran as three parallel agents on the diff file rather than the Workflow script (the script needs the diff inline; kept context for the fix loop).

## Outcome
- Shipped to the working tree (uncommitted). Harness 115/115, Debug + Release builds green. Review gate: round 1 = 2 HIGH / 3 MEDIUM / 7 LOW across three lanes, all fixed except the count-only cache cap; round 2 = APPROVE, 1 LOW (final unchecked repair) fixed. Not verified in the running app on a real lock screen (see handoff).
