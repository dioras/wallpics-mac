# Plan: DIY pet — Pro-only upload, ready popup, menu bar status, DIY in catalog

- Date: 2026-09-23 · Size: standard · Mode: change-feature · Branch: feature/mvp-release (Alex commits; no commits, no code comments)
- Security triggers: entitlements (Pro gate), user uploads.

## Backend facts (probed 2026-09-23, prod)
- `POST /api/pets/store` accepts `category_ids[]`; `GET /api/pets?categoryId=N` filters (categoryId=4178 → [3,7,21]).
- `GET /api/pets/{id}`: unapproved → 200 `{"status":"error","data":{"message":"Pet ID not found."}}`; approved → success + full pet. Readiness is detectable. Rejection and progress are not.
- Pet JSON has no owner, category or source field. Every approved pet is public in `GET /api/pets`.
- Category 3832 "Uploaded by users 👥" exists (top level).

## Decisions
- Ready detection = existing poll of `/api/pets/{id}` (10 min + app activation, throttled) + catalog refresh. Monitoring moves to app launch (AppDelegate), so it runs with the window closed.
- "Your pet is ready" = the app's default popup (SwiftUI `.alert`, same as the autostart prompt) + system notification when the app is in the background; clicking it opens the DIY tab.
- Menu bar: the existing status item shows a dot when a pet is ready and unseen; its menu lists DIY pets (in review / ready → Put on Desktop) and "Check status now".
- DIY in catalog: new submissions send `category_ids[]=3832`; Pets tab gets "All / DIY" chips (DIY = category 3832 ∪ user's own ready pets). If the server rejects the category (422 mentioning category), the upload retries once without it.
- DIY tab gets "Your pets" (own ready pets, place on desktop from there).
- Copy: 1–5 photos (Simon 09-22: 1 photo is fine).

## Acceptance criteria
| # | Scenario | Expected | Verify |
|---|---|---|---|
| AC1 | Free user sends photos | paywall, no upload | harness testSubmissionGate |
| AC2 | Poll/catalog shows own pet approved | record READY, alert "<name> is ready", system notification if app inactive, menu bar dot | harness (seen/badge logic) + build |
| AC3 | Old records (v3 file) | decode, ready ones count as seen | harness decode test |
| AC4 | Upload body | contains `category_ids[]` 3832 | harness multipart test |
| AC5 | 422 about category | one retry without category | harness retry-decision test |
| AC6 | Pets tab DIY chip | shows community ∪ own ready pets | harness filter test + build |

## NOT building
- Separate $7 IAP, backend changes, rejection UI beyond the existing overdue state, per-owner privacy.

## Outcome
- Harness 150/150; Debug + Release (CODE_SIGNING_ALLOWED=NO) BUILD SUCCEEDED.
- Review: security PASS; silent-failure 2 HIGH + 3 MEDIUM + 1 LOW fixed; quality 1 MEDIUM + 1 LOW fixed; round 2 1 MEDIUM + 1 LOW fixed (reviewer's exact fix).
- Not verified live: a real upload → admin approve → popup/notification/badge cycle (no test upload sent to prod on purpose). No UI screenshot (window capture blank in this environment).
- Summary for Simon: ~/Desktop/wallpics-mac-diy-pets-2026-09-23.txt
