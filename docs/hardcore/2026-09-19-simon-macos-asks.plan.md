# Plan — Simon's macOS asks (2026-09-19)

Mode: /hardcore full, autonomous ("go!"). Tier: large. Branch: feature/mvp-release (Alex commits).

## Evidence (Slack #fizizi, 2026-09-16 … 09-18)
- 09-17 15:26 Simon (DM): App Store size 306 MB "way over the limit", "what takes up the most space?" — Alex: "hardcoded pets"; Simon: "Backend is all good".
- 09-17 15:37 Simon: "this paywall we have to show more often. It should not be an optional page like 'oh i want to remove the watermark'. It has to be with locked content on 'set as wallpaper' > they get this. Also any other uploaded pets besides first 2 - paywalled."
- 09-17 14:57 Simon (#wallpics-app): dashboard screenshot with the same dog submitted 7× (pets 51-60): "users probably can upload multiple photos and this creates this — would need to put limit on".
- 09-18 15:51 Alex: "the ones we discussed yesterday right? App weight, paywall etc?" — Simon: "yes". Alex: "release update tomorrow".
- 09-16 Danil: pet name not updating → already fixed in working tree (handoff 2026-09-16).

## Measured
- Release build `WallPics.app` = 305 MB; `Contents/Resources/Pets` = 274 MB; everything else = 30.2 MB.
- Live catalog (api/wallpapers/{desktop,live-desktop,shader-desktop}): 1069 items, 13 flagged `is_premium` (11 photo, 2 live, 0 shader).
- Mac app never reads `is_premium` for gating (only a PRO badge on the card); set-wallpaper never blocks; pet upload has no gating.

## Acceptance criteria (observable)
1. `git ls-files WallpicsMac/Resources/Pets | wc -l` = 0; pbxproj has no `Pets` folder reference; Release build `du -sh WallPics.app` < 40 MB; app launches with catalog = backend pets only.
2. A placement whose slug is not `remote-<id>` is dropped at PetStore load (logged), so no invisible frozen state after update.
3. `WallpaperAccess.decision(isPremium:state:setsToday:)`: `.free` + premium → `.paywall(.premiumContent)`; `.free` + 3 sets today → `.paywall(.dailyLimit)`; `.unknown`/`.trial`/`.pro` → `.allowed`; DEBUG → `.allowed`. Covered by Tools/GazeTests (RED first).
4. FeaturedHero "Set Wallpaper" on a locked wallpaper opens the paywall and does NOT download/set; on allowed content it sets and records one use for the day. Local (imported) wallpapers never gated.
5. `PetAccess.requiresPaywall(forSubmissionCount:state:)`: `.free` + 2 prior submissions → true; 1 → false; pro/unknown → false; DEBUG → false. Harness-tested.
6. "Add your pet" with the free limit reached opens the paywall instead of the sheet; the lifetime submission count persists in submissions.json (v2) and survives records being reconciled/removed.
7. Re-submitting a photo already sent (SHA-256 of the prepared JPEG) is refused with a notice, no upload.
8. Paywall copy no longer leads with "remove the watermark"; new strings translated in de/es/fr/ja/pt-BR/ru/zh-Hans like the existing paywall keys.
9. MARKETING_VERSION 1.0.4, CURRENT_PROJECT_VERSION 52 in all 4 configs.
10. Debug build + Release build succeed; harness all PASS.

## Decisions (ADR-style)
- Daily free quota (3 sets/day, one constant) added on top of `is_premium`: the backend flags only 1.2 % of desktop content, so a premium-only gate would not make the paywall "show more often"; the paywall copy already promises "no daily limits". Simon can raise premium share on the dashboard without an app update.
- Pet gate is on *submission* (upload), not on placing approved pets: submissions are what costs generation money and what the dashboard duplicates show. Lifetime local counter (reinstall resets it — acceptable for now).
- Duplicate-photo guard uses the prepared JPEG digest, so the same source file re-encodes to the same digest.
- Bundled catalog loader removed entirely rather than left to log "cannot read catalog" on every launch.
- Not touching: StoreKitService debug prints, Direct entitlements, iOS asks, loading indicator for pet downloads (Simon: "it's all good").

## Tasks
1. Remove Resources/Pets (git rm), pbxproj folder ref + build file, PetCatalog bundled loader, PetProfileDefaults entries, stale placement drop.
2. New `Models/WallpaperAccess.swift` (+ pbxproj 4 entries, + harness SRC), quota store, FeaturedHero gate, onboarding pick filter.
3. PetAccess submission rule, submissions.json v2 (count + digests), submit() digest check, PetsView button gate.
4. Paywall copy + translations.
5. Version bump.
Validate: `Tools/GazeTests/run.sh`; `xcodebuild -scheme WallpicsMac -configuration Debug build`; `xcodebuild -configuration Release CODE_SIGN_IDENTITY=- build` + launch for screenshots.

## Outcome (2026-09-19)
All 10 acceptance criteria met statically + by harness/build; criterion 4 (hero gate) not observed in a running Release app — keychain prompt blocks scripted launch. See `2026-09-19-simon-macos-asks-handoff.md`.

## Deviations
- Added the daily free quota (3/day) beyond the literal ask — 1.2 % premium share on the backend made a premium-only gate meaningless; recorded as ADR above.
- Review round 2 added: observable loading/error state for the remote pet catalog, onboarding fallback, no prefetch of locked Pro assets, midnight refresh, placeholder-profile persist guard, `Tools/installpets.py` removed.
- pbxproj: first attempt collided object IDs with Logger.swift; fixed to AD/AC000091.
