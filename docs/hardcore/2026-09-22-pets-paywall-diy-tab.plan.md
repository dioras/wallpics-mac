# Plan: Pets behind Pro + DIY pet as its own tab

- Date: 2026-09-22 · Size: standard · Mode: change-feature
- Branch: `feature/mvp-release` (Alex commits; no branch, no commits from this run) · Stack: swift · Security triggers hit: yes (entitlements / paywall gating, user uploads)
- Confidence: 8/10 — every touched path already exists; the only unknown is the backend contract for pending/rejected submissions (see Assumptions).

## Summary
Simon (Slack, 09-22): every pet — catalog and user-made — is Pro-only; free users are sent to the paywall, not blocked silently. The DIY flow (upload your pet's photos, Simon's pipeline builds it, ~$7 per pet) moves from a sheet on the Pets tab into its own tab with a real explanation, a photo form, and the status of each submission. The app polls the backend for approval and tells the user when the pet is ready. What stays: the Pets grid, placement, backdrop, the wallpaper paywall (set-as-wallpaper gate + 3 free sets/day) from commit 8ced362.

## Acceptance criteria
| # | Scenario | Action | Expected (observable) | Must NOT | Verify by | Priority |
|---|---|---|---|---|---|---|
| AC1 | Free user, any pet (premium flag true or false) | click tile / "Put on Desktop" | Paywall sheet opens, pet is not placed | place the pet; show "PRO" only on some tiles | `Tools/GazeTests testPremiumGate` (release harness) + manual | P0 |
| AC2 | Pro/trial/unknown state | same | pet placed as before | paywall for pro/trial | harness `testPremiumGate` | P0 |
| AC3 | Free user, DIY tab | click Submit with photos | Paywall opens, nothing uploaded | upload; count-based free submissions | harness `testSubmissionGate` (no `freeSubmissions` symbol) | P0 |
| AC4 | Any user | open the app | nav has a "DIY Pet" pill between Pets and Favorites; tab shows how-it-works (3 steps), tips, form, submissions list | remove the Pets tab "Add your pet" entry point (it now jumps to the tab) | build + screenshot | P0 |
| AC5 | Submission pending; backend GET /api/pets/{id} returns `status:"success"` | poll tick / tab appear | record shows "Ready" and the pet appears in the Pets grid (catalog refreshed) | delete the record before the catalog contains the pet | harness `testSubmissionOutcome` + log line | P0 |
| AC6 | Backend answers `status:"error"` "Pet ID not found." | poll | record stays "In review" (no change) | mark rejected | harness `testSubmissionOutcome` | P0 |
| AC7 | Backend adds `data.status: "rejected"` (+ `rejection_reason`) | poll | record shows "Couldn't be made" with the reason | crash / drop the record | harness `testSubmissionOutcome` | P1 |
| AC8 | Set-as-wallpaper gate (Simon 09-17) | free user sets premium wallpaper or 4th free wallpaper | paywall opens, wallpaper not set | regress | harness `testWallpaperGate` + code read `PreviewPanel.swift:195` | P0 |

## Assumptions & open questions
- Assumption: a pending/rejected pet is not served by GET /api/pets/{id} (docs: "Not yet served by the public API until an admin approves") → probed live: unknown id → HTTP 200 `{"status":"error","data":{"message":"Pet ID not found."}}`. So "error" = still in review OR rejected; the app cannot tell. Forward-compatible: if the backend later returns `data.status` ∈ {pending, processing, approved, rejected} and `rejection_reason`, the app shows it. Backend ask for Misha recorded in the report.
- Assumption: DEBUG builds keep `SubscriptionState.isPro == true` (existing), so paywall logic is exercised by the release harness build (`Tools/GazeTests/run.sh` compiles both).
- Assumption: no system notification permission flow exists today; a local notification on approval is added with a lazy authorization request after the first successful submission. If denied, the in-app "Ready" state still shows.

## Patterns to mirror
| Concern | Source | Pattern |
|---|---|---|
| Access rules | `WallpicsMac/Models/WallpaperAccess.swift:17` | pure static decision on `SubscriptionState`, DEBUG-agnostic, tested in harness |
| Tab wiring | `WallpicsMac/App/AppEnvironment.swift:28`, `Views/ContentView.swift:82,132` | `Section` enum + `navPill` + `detailContent` switch |
| Dark pets styling | `Pets/Views/PetsView.swift:60-90` (header), `PetSubmitSheet.swift` (form) | `.background(.black)`, `.environment(\.colorScheme, .dark)`, `Theme.Space/Radius`, `liquidGlass` |
| Networking | `Pets/Core/PetCatalog.swift:167-186` | x-auth/x-token headers, `URLSession.shared`, decode `status` envelope |
| Persistence | `Pets/Core/PetSubmission.swift:120-215` | versioned JSON file, atomic write, corrupt file moved aside |
| Logging | `Log.api` / `Log.app` with privacy annotations | same |
| Tests | `Tools/GazeTests/main.swift:302-370` | `check(cond, name)` harness; files listed in `run.sh` |

## Design decision
- Submission form location: A) keep the sheet and add a tab that only explains → B) embed the form in the tab (chosen). One place to learn, upload and watch status; the sheet's success/failed states become inline. Rejected: A — two surfaces for one flow.
- Rejection visibility: cannot be derived today; design the record status enum with `.rejected(reason)` now so the backend change is a no-op in the app.

## Files
| Op | Path | Purpose |
|---|---|---|
| UPDATE | `WallpicsMac/Pets/Core/PetModels.swift` | `PetAccess`: all pets Pro-only; submissions Pro-only; `PetSubmissionOutcome` pure decoder |
| UPDATE | `WallpicsMac/Pets/Core/PetSubmission.swift` | record status (`inReview/ready/rejected`), status poller, notification |
| UPDATE | `WallpicsMac/Services/WallpaperAPI.swift` | `petStatus(id:)` GET /api/pets/{id} |
| CREATE | `WallpicsMac/Pets/Views/DIYPetView.swift` | the tab: hero, steps, tips, form, submissions |
| UPDATE | `WallpicsMac/Pets/Views/PetSubmitSheet.swift` | becomes `PetSubmissionForm` (embedded), drop the sheet chrome |
| UPDATE | `WallpicsMac/Pets/Views/PetsView.swift` | no sheet/pending tiles; lock badge for free users; "Add your pet" → DIY tab |
| UPDATE | `WallpicsMac/Pets/ViewModels/PetsViewModel.swift` | reconcile → mark ready (not remove) |
| UPDATE | `WallpicsMac/App/AppEnvironment.swift`, `Views/ContentView.swift` | `.diy` section + pill + content |
| UPDATE | `WallpicsMac.xcodeproj/project.pbxproj` | add DIYPetView.swift (IDs AD/AC000093…) |
| UPDATE | `Tools/GazeTests/main.swift` | tests updated to new spec + outcome tests |
| UPDATE | `WallpicsMac/Resources/Localizable.xcstrings` | translations for new copy (de/es/fr/ja/pt-BR/ru/zh-Hans) |

## Tasks
### T1 — Access rules (RED first)
- RED: harness `testPremiumGate` expects `requiresPaywall(pet: freePet, state: .free) == true` (release); `testSubmissionGate` expects `PetAccess.submissionsRequirePro(state: .free) == true`, `.pro/.trial/.unknown == false`; remove `freeSubmissions`.
- IMPLEMENT in `PetModels.swift`; update `PetSubmission.submit()` guard, `PetsView.submissionsLocked`, `DesktopPetManager` (unchanged API).
- VALIDATE: `bash Tools/GazeTests/run.sh` → all PASS.
### T2 — Submission outcome decoding (RED first)
- RED: `testSubmissionOutcome`: success body → `.approved`; error "not found" → `.stillPending`; `data.status:"rejected"` → `.rejected(reason)`; garbage → `.stillPending`.
- IMPLEMENT `PetSubmissionOutcome.parse(data:)` in `PetModels.swift` (Foundation only, harness-compilable).
### T3 — Record status + poller + notification
- `PetSubmissionRecord.status` (Codable enum, default `.inReview` when absent), file version 3.
- `PetSubmissionStore.markReady(serverID:)`, `markRejected(serverID:reason:)`, `reconcile` → ready instead of remove.
- `PetSubmissionSync` (@MainActor @Observable): `refreshNow()` polls every in-review record with a serverPetID via `WallpaperAPI.shared.petStatus(id:)`; on `.approved` → `RemotePetService.shared.refresh()` then `markReady` and post a local notification; timer every 10 min while the app runs; started from `PetsViewModel.init`.
- VALIDATE: build.
### T4 — DIY tab
- `AppEnvironment.Section.diy` ("DIY Pet", `wand.and.stars`), pill after `.pets`, `DIYPetView(model: petsModel)`.
- `DIYPetView`: header · "How it works" 3 cards (Send photos → We build it (about 48 h) → Lives on your desktop) · form (`PetSubmissionForm`) with Pro lock ribbon for free users (Submit → paywall) · "Your submissions" rows with status pill and actions (Show in Pets / Remove).
- `PetsView`: drop sheet + PendingPetTile usage; "Add your pet" → `env.selectedSection = .diy`; PRO/lock badge driven by `PetAccess.isLocked`.
- VALIDATE: Debug + Release build.
### T5 — Localization + de-sloppify
- Add translations for the new strings via script; rerun harness + builds.

## Validation ladder
- L1 static: compiler (no swiftlint config) · L2 unit: `bash Tools/GazeTests/run.sh` · L3 build: `xcodebuild -project WallpicsMac.xcodeproj -scheme WallpicsMac -configuration Debug build` and `-configuration Release CODE_SIGNING_ALLOWED=NO` · L4: launch the Debug app, open the DIY tab, screenshot · L5: visual (dark, window ≥ 1180 and narrow).

## Risks & rollback
| Risk | L | I | Mitigation | Rollback |
|---|---|---|---|---|
| Existing placed pet of a free user stops on update | high | medium | intended (Simon); DesktopPetManager already shows "Pro required" | revert PetAccess |
| Old submissions.json (v2) without status | high | low | decode default `.inReview` | — |
| Poll noise | low | low | 10-min timer, only records with serverPetID and `.inReview` | — |

## NOT building
- Pricing/product changes, backend changes, per-pet purchase, push notifications, Pets grid redesign.

## Deviations (filled during BUILD)

## Outcome (filled at SHIP)
- 2026-09-22 — Browse tab pets rail also shows the lock badge (same `PetTile`), not in the original file list.
- 2026-09-22 — Review round 1: form model hoisted to `PetsViewModel.submission` (tab switch mid-upload lost the result); `PetSubmissionOutcome.unrecognized` + `ensureOK` + `PetSubmissionSync.lastError`; overdue rows (7 days / no server id) become removable; foreground notification delegate; poll throttle 60 s; `PetSpecies.remoteSlug(id:)`; `PetSubmitSheet.swift` renamed to `PetSubmissionForm.swift`.

## Outcome
- AC1–AC3 ✅ harness `testPremiumGate`, `testSubmissionGate` (release build of the harness) · AC4 ✅ Debug + Release BUILD SUCCEEDED, not screenshotted (see handoff) · AC5–AC7 ✅ harness `testSubmissionOutcome` · AC8 ✅ `testWallpaperGate` + `PreviewPanel.swift` `setAsWallpaper` gate unchanged since 8ced362.
- Harness 130/130. Review: security PASS on client (1 HIGH is backend-side, 1 LOW fixed); silent-failure 2 HIGH + 1 MEDIUM + 2 LOW fixed; quality 1 HIGH + 4 LOW fixed.
