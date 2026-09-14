# Plan — animated lock screen for live & shader wallpapers (2026-09-14)

Tier: standard · mode: restore-feature · autonomous (Alex not watching; gates printed, not asked)

## What was actually there
The lock-screen animation never lived in this repo. It was a separate, un-git'd copy at
`~/Desktop/wallpics-lockscreen` (July 2026, `LOCKSCREEN-README.txt`): `LockScreenAerial` in
`WallpaperRenderer.swift` transcoded a live wallpaper to HEVC, overwrote the `.mov` of the aerial the
Desktop is set to under `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<uuid>.mov`,
rewrote `Store/Index.plist` so Desktop + Idle point at that aerial, and `killall`'d the wallpaper
daemons. macOS mirrors the desktop aerial on the lock screen, so it animates there. Requirements:
app must run **unsandboxed** (sandboxed app can't write there) → never App Store. Video only; a
manual "Lock Screen" button. The main app (sandboxed, App Store) always shipped the static poster.

## Deliverable
1. `Services/LockScreenAerial.swift` — the aerial-store mechanism, ported; runtime-gated on
   `isSupported` (not sandboxed + wallpaper store present). No plist backups (restoring a stale
   index was riskier than leaving the Idle choice); `.mov` slot still backed up and restored.
2. `Services/ShaderVideoExporter.swift` — renders an `.msl` shader offscreen with Metal into a
   60 s / 30 fps HEVC `.mov` (AVAssetWriter, Metal-compatible pixel buffers) so shaders get the
   lock screen too.
3. `Services/LockScreenService.swift` — `@Observable` orchestrator with status
   (idle / preparing / ready / failed). Every aerial-store operation runs on ONE serial chain, so a
   retire can never interleave with an in-flight install; superseded jobs are cancelled and their
   status/progress writes ignored by generation. After a retire the desktop choice is re-applied so a
   static pick isn't left pointing at the aerial.
4. `WallpaperRenderer` hooks: `startAnimated` → poster first (unless the aerial for this exact asset
   is already live), then `LockScreenService.sync`; `setStaticImage` → retire the aerial.
5. Automatic: no extra button. Status line under "Wallpaper set." in the hero. Settings toggle
   (shown only when supported) to switch it off; static wallpaper switches it off too.
6. Debug builds run unsandboxed (`WallpicsMac-Local.entitlements`) so the feature can be exercised;
   Release stays sandboxed (feature inert/hidden). A private Developer-ID build = Release signing with
   `com.apple.security.app-sandbox` set to false.

## Acceptance criteria (observable)
- A1 `xcodebuild -configuration Debug` succeeds with no new warnings in the new files.
- A2 Debug app: set a live wallpaper → hero shows "Preparing lock screen…" then "Lock screen animates
  too…"; `~/Library/Application Support/WallpicsMac/lockscreen.json` exists; the Desktop aerial `.mov`
  is a video-only HEVC ≥ 60 s; `Index.plist` Desktop/Idle choices point at that aerial.
- A3 Same for a shader wallpaper (clip rendered from the shader).
- A4 Set a static wallpaper → state file gone, backup `.mov` restored, desktop shows the image.
- A5 Relaunch with the same live wallpaper → no re-export (status ready immediately), poster not
  re-applied over the live aerial.
- A6 Release (sandboxed) build: no Lock Screen settings section, no status line, poster path unchanged.

## Review
Two independent reviewers (correctness, silent failures) ran on the diff. Fixed in the same pass:
install now writes its state record BEFORE overwriting the aerial and rolls back on any failure
(otherwise a mid-install error left Apple's aerial overwritten with no way back); retire throws,
keeps the backup when restoring fails, and reloads the daemons; the plist edit is verified after
writing (a no-op edit used to report "ready" and re-transcode forever); both exporters clean up
partial clips on every error/cancel path and carry the underlying error in logs; install/retire are
serialized; progress callbacks are generation-checked; settings are read from the live environment.
Known limitation: the lock-screen clip carries no free-tier watermark (irrelevant while the feature
is Debug/unsandboxed-only, since Debug is Pro) — revisit before any free-tier Developer-ID build.

## App Store question (asked 2026-09-14)
Alex asked for this to work in the App Store build too. It cannot, and this is a platform limit, not a
conservative reading:
- The Mac App Store mandates the App Sandbox, and a sandboxed app's home is redirected to its container.
  Verified on this Mac: `~/Library/Containers/com.kyragames.AestheticSadWallppapers/Data/Library/Application Support/`
  holds no `com.apple.wallpaper` while the real home does — the aerial store is invisible to the sandboxed
  build, not merely read-only. Signalling WallpaperAgent/idleassetsd is barred too, and depending on
  undocumented internals is a 2.5.1 rejection on its own.
- Apple docs: 0 of 348 frameworks match "wallpaper"; there is no public lock-screen API of any kind.
  `ScreenSaver` is the legacy `.saver` plugin API (macOS 10.0, no app-extension point), so it is neither
  sandbox-shippable nor the lock-screen wallpaper.
- Every shipping app in this category (Backdrop/Cindori, gifPaper, Wallux, MotionDesk) is direct-download
  only, explicitly because of sandboxing.

Conclusion: hybrid distribution. The App Store build keeps today's behaviour (full-resolution static
poster on the lock screen, feature inert, no Lock Screen settings section); a direct-download
Developer-ID build carries the animated lock screen. Both come from this one codebase, gated at runtime
by `LockScreenAerial.isSupported`.
