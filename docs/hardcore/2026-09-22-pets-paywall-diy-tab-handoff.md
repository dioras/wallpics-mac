# Handoff — pets behind Pro + DIY Pet tab (2026-09-22)

Plan: `docs/hardcore/2026-09-22-pets-paywall-diy-tab.plan.md`. Working tree uncommitted (Alex commits).

## Why
Simon, Slack 09-22: "we have to paywall it" (all pets), DIY pet costs ~$7 per generation, "bad photos I manage on the backend". Simon 09-17: paywall on "set as wallpaper", not an optional watermark page.

## What changed
- `PetAccess`: every pet Pro-only for `.free`; `submissionsRequirePro` replaces the 2-free-submissions rule. `.unknown` allowed until StoreKit resolves. DEBUG builds unrestricted (pre-existing `isPro`).
- New tab "DIY Pet" (`DIYPetView.swift`): how-it-works steps, embedded photo form (`PetSubmissionForm.swift`, was the sheet), submissions list with IN REVIEW / READY / NOT BUILT, Check now, error caption.
- `PetSubmissionSync` polls `GET /api/pets/{id}` every 10 min + tab appear; approval → catalog refresh → record READY → local notification.
- Pets tab: "Make your own" jumps to the DIY tab; lock + PRO badge on every tile for free users (Browse rail too).
- 39 new strings translated into 7 locales.

## Verification
- `bash Tools/GazeTests/run.sh` → 130 passed, 0 failed.
- Debug and Release (`CODE_SIGNING_ALLOWED=NO`) → BUILD SUCCEEDED.
- NOT verified: the tab visually. The app window could not be captured by script (blank capture, no accessibility tree). Alex: open DIY Pet tab, check wide (≥ 1100 pt) and narrow layouts, submit as free user in a Release build → paywall.

## Backend gaps (ask Misha)
1. Pending vs rejected: `GET /api/pets/{id}` answers "Pet ID not found." for both. App already reads `data.status` (pending/approved/rejected) and `data.rejection_reason` if added.
2. No server-side Pro check on `POST /api/pets/store`; token is md5(ts+"wall"), so old builds or curl can upload for free.
3. Unclear whether an approved DIY pet is private to its owner or appears in `GET /api/pets` for every user.

## Exact next step
Alex: visual pass on the DIY tab, send Misha the 3 backend items, commit.
