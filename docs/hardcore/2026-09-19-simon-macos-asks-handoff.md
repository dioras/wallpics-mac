# Handoff — Simon's macOS asks: app size, paywall on Set, pet upload limit (2026-09-19)

Plan: `docs/hardcore/2026-09-19-simon-macos-asks.plan.md`. Working tree uncommitted (Alex commits). Version bumped to 1.0.4 (52).

## Why (Slack evidence, fizizi)
- 09-17 15:26 Simon: App Store size 306 MB "way over the limit". Alex: hardcoded pets. Simon: "Backend is all good".
- 09-17 15:37 Simon: paywall "has to be with locked content on 'set as wallpaper' > they get this. Also any other uploaded pets besides first 2 - paywalled."
- 09-17 14:57 Simon (#wallpics-app): dashboard with the same dog submitted 7× → "would need to put limit on".
- 09-18 15:51 Alex ↔ Simon: "App weight, paywall etc" confirmed as the macOS scope; "release update tomorrow".

## What changed
1. **Bundle size** — `WallpicsMac/Resources/Pets` (14 pets, 274 MB) `git rm`'d; folder reference + Copy-Resources entry removed from the pbxproj; `PetCatalog` bundled loader deleted (`all == RemotePetService.shared.pets`); `PetProfileDefaults` reduced to the placeholder; `PetStore.init` drops a stored placement whose slug is not `remote-<id>` (logged) so nobody keeps a frozen, invisible pet; `Tools/installpets.py` removed (wrote into the deleted folder). Release `WallPics.app`: **305 MB → 30 MB**.
2. **Paywall on Set Wallpaper** — new `Models/WallpaperAccess.swift` (registered in pbxproj, IDs AD/AC000091): `.free` user + `is_premium` wallpaper → paywall; `.free` user after **3 sets/day** (`WallpaperAccess.freeSetsPerDay`, one constant) → paywall; `.unknown/.trial/.pro` and DEBUG → allowed; user-imported wallpapers never gated. `FeaturedHero` shows `lock.fill` + "Pro wallpaper" / "Free limit reached for today" pill and opens the paywall instead of downloading; quota recorded only after a successful remote set; `WallpaperSetQuota` (UserDefaults day+count) refreshes on `.NSCalendarDayChanged`. Locked Pro wallpapers no longer prefetch the clean full asset into the cache (poster only). Onboarding picks skip premium items (falls back to the full page if all are premium).
   Reason for the daily quota: live catalog has only 13 premium of 1069 desktop wallpapers, so a premium-only gate would almost never show the paywall; the paywall copy already promised "no daily limits". Simon can raise the premium share on the dashboard with no app update.
3. **Pets: first 2 uploads free** — `PetAccess.freeSubmissions = 2`, `requiresPaywall(forSubmissionCount:state:)`; "Add your pet" shows a lock and opens the paywall when reached; `submit()` re-checks. `submissions.json` v2 keeps a lifetime `submissionCount` (v1 files migrate with `records.count`) and SHA-256 digests of sent photos (cap 200); re-sending an already-sent photo is refused before any upload with a notice. Client-side only — backend `POST /api/pets/store` still has no per-guest cap.
4. **Paywall copy** — subtitle "Every wallpaper, every pet, no watermark — and support a small, independent team."; third benefit "Pro wallpapers and unlimited pets from your photos". Old keys removed. All new strings translated (de/es/fr/ja/pt-BR/ru/zh-Hans), catalog edited by script (xcodebuild does not sync string catalogs).
5. **Pets tab empty state** — no longer says "reinstall WallPics"; shows "Loading pets…" while `RemotePetService` (now `@Observable`, `isRefreshing`/`lastError`) works, or "Couldn't load pets" + Try again.
6. `PetProfileStore.update` no longer persists an untouched placeholder profile (opening the editor used to pin the catalog name; same bug class as Danil's 09-16 report).
7. Danil's 09-16 fixes (panel title follows the renamed pet, backdrop card auto-fit) are still in the tree, uncommitted, and ship with this build.

## Verification
- `Tools/GazeTests/run.sh`: 108 passed / 0 failed (release binary) + 3 DEBUG-only checks (new: `testSubmissionGate`, `testWallpaperGate`, RED first → GREEN).
- `xcodebuild -scheme WallpicsMac -configuration Debug build` → BUILD SUCCEEDED.
- `xcodebuild -configuration Release CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED; `du -sh WallPics.app` = 30M, `Contents/Resources` = 1.2M. (`CODE_SIGN_IDENTITY=-` fails: app-groups entitlement needs the dev cert.)
- Live API count: desktop 738/11 premium, live-desktop 324/2, shader 7/0.
- Review gate round 1 (quality, silent-failure, security, plan lanes): 0 CRITICAL, 1 HIGH (fixed: pets empty-state copy), 3 MEDIUM (fixed: midnight lock label, onboarding dead end, Pro asset prefetch), LOWs fixed (stale resultMessage, submit() gate, log path, placeholder persist). Round 2 (fresh reviewer on the fixes): 1 HIGH fixed — a refresh yielding zero usable pets now sets `lastError` and keeps the cached list instead of wiping it and spinning forever; 1 LOW fixed — hero reloads the full asset once a premium wallpaper unlocks (`heroLoadKey`). Round 3: harness 108/108, Debug + Release builds green. Accepted: client-side quota/counter are resettable; lapsed `.pro` persists until relaunch (pre-existing).
- **NOT verified visually**: Release gating in the running app. A re-signed copy (different bundle id, ad-hoc) and the CLI-built Debug app both hit the macOS keychain prompt for "app.wallpics.mac", which is secure UI and cannot be clicked by script. To see it: run the Release scheme from Xcode (or the scratch QA copy) and click Deny/Allow, with `freeWallpaperSetsCount=3` for today in defaults to see the daily lock. A stale keychain prompt may still be on screen — Deny it, nothing is running.

## Open / not done
- Backend: per-guest pet upload cap and server-side premium asset check (the real enforcement). Tell Simon the app-side limits are soft.
- `RemotePetService.performRefresh` still replaces `pets` wholesale (placed pet vanishing from the UI on a partial refresh — known since 09-16, deliberately untouched).
- StoreKitService debug `print`s remain (pre-existing).
- `WallpicsMac-Direct.entitlements` still unreferenced (animated lock screen needs the direct build).
- Reinstall resets the free pet counter and the daily quota (by design for now).

## Exact next step
Alex: run Release from Xcode once to eyeball the lock pill + paywall, commit, archive 1.0.4 (52), upload. Ask Simon to flag more desktop wallpapers premium on the dashboard, and whether 3 free sets/day is the number he wants (`WallpaperAccess.freeSetsPerDay`).

## Addendum — Simon's other items, 09-14 … 09-19 (checked 09-19 evening)
- 09-18 06:35 #wallpics-dashboard "Found some pets that are extra large" (screenshot = our Pets tab, pet 65 Nina, ears cropped in the preview). Cause: Misha's 435-pose clips are bust close-ups (`subjectHeight` 0.67–0.72, frame 786×720) while the older pets are full body (0.94); the preview scaled the subject to fill the pane and cut everything above `subjectTop`. Fixed app-side: `PetPreviewView.layoutPet` now aspect-fits the whole frame (no crop). The desktop window was never cropped. Size normalisation by subject height still makes a bust look bigger than a full-body pet at the same size setting — that is content framing (Misha), already routed to him by Simon.
- 09-16 "Wallpapers to widgets possible issue" (recording) — dashboard "make a profile picture" flow, not the mac app.
- 09-14 "dashboard and app side of algorithm, default selection" — dashboard sorting, not the mac app.
- 09-17 "How often does the app get the new animals" — Simon closed it himself ("it's all good, 5-10 minutes"); no change made.
- Everything else from Simon in that window is iOS (AI filters/videos, themes with lock screen preview, Duo wallpapers, CarPlay) or backend (designer accounts, link expiry, AI filter size).
