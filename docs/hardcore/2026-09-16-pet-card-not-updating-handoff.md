# Pet name not updating in the app — investigation handoff

Date: 2026-09-16 · Branch: `feature/mvp-release` · Mode: `/hardcore fix` (audit + fix, uncommitted)

## Report
Relayed second-hand as "changes the pet description and it doesn't change". Danil's own words
(Slack, 2026-09-16 19:44) turned out to be narrower:

> "я ранее хотел поменять имя для питомца... Но там основное имя не меняется в приложении,
> а только в данных снизу."

i.e. the **title in the app's active-pet panel** did not follow the Name field — only the detail
rows under it did. He also asked how long pet generation normally takes (20 min this time, almost
a day previously).

## Actual reported bug — fixed
`PetsView.swift:109` rendered `Text(pet.name)` — the catalog/species name — and never the edited
`PetProfile.displayName`. The wallpaper card used `profile.displayName`, so the two disagreed
exactly as Danil described. Now routed through `PetProfileStore.displayName(for:)`, which returns
the typed name only when it differs from the untouched default, so pets nobody renamed are
unaffected. Applied to the panel title, the "Remove … from Desktop" help, and the grid tile
caption/tooltip. 8/8 logic cases verified.

His generation-time question is not a client bug: the submit sheet already states "usually within
48 hours" and pending pets show an "In review" tile. Anything faster is a backend pipeline change.

## Second bug found while investigating (also fixed)
`PetBackdropRenderer` laid the card out top-down with no bottom bound. Once the text was taller
than the screen, the remainder was drawn below y=0 — off the bottom edge, invisible. Nothing
clipped, scrolled or shrank, and no error surfaced.

Measured maximum "Pet Notes" length before the text runs off-screen (old renderer):

| display | short detail rows | detail rows that wrap (as in Alex's screenshot) |
|---|---|---|
| 1470×956 (16:10) | ~288 chars | ~168 chars |
| 1512×982 (16:10) | ~288 chars | ~168 chars |
| 1920×1080 (16:9) | ~192 chars | **~72 chars** |
| 2560×1440 (16:9) | ~192 chars | **~72 chars** |
| 3456×2234 (16:10) | ~288 chars | ~168 chars |

`unit = min(height, width * 9/16)` makes the type ~15% larger relative to screen height on 16:9
displays while the text column stays narrow, so common external monitors fit the *least* text.
This is why it reproduced for the friend and not on a 16:10 MacBook display.

## Fix applied (uncommitted)
- `PetBackdropRenderer` — `Layout` struct with `header(scale:draw:)` / `notes(_:from:scale:draw:)`
  that both measure and draw. Scale steps 1.0 → 0.6 until the card fits above `margin * 0.5`;
  if it still overflows, a grapheme-safe binary search keeps the longest prefix that fits and
  appends "…". Cards that already fitted render byte-identically (SHA-256 verified).
- `PetsViewModel.updateProfile` — 200 ms debounce on the backdrop redraw. Previously every
  keystroke triggered a full-screen render per display (~10 ms at 1080p, ~30 ms at 3456×2234).
  The store write stays immediate; the redraw task deliberately outlives the view model so the
  last keystroke always lands.
- `PetProfileStore` — corrupt `profiles.json` is now logged and moved to `.corrupt` instead of
  silently resetting every profile to defaults; save failures set `lastSaveError`, shown in the
  editor.
- `PetBackdropService.reapply()` — logs when the placed species is missing from the catalog.
  Deliberately keeps the existing backdrop (see "rejected" below).

## Rejected during review
Clearing the backdrop when the species is missing from the catalog, plus calling `reapply()` from
the `RemotePetService.didUpdate` observer. `PetCatalog` replaces `pets` wholesale on every refresh
and silently drops pets that fail to decode or fall past `maxPages = 20`, so one transient backend
hiccup would have wiped a working desktop card. Reverted to a no-op plus a log line.

## Still open (not fixed)
1. `PetSpecies.summary` (backend `description`) is decoded at `PetCatalog.swift:370` and declared
   at `PetModels.swift:21` but never rendered anywhere. If "pet description" means the backend
   field, it cannot appear in the app at all.
2. `PetCatalog.performRefresh` replaces `pets` wholesale; a single undecodable pet or a truncated
   pagination removes a placed pet from the catalog, which hides the whole active-pet card and
   editor while leaving the desktop backdrop frozen.
3. Debug is unsandboxed (`WallpicsMac-Local.entitlements`) and Release is sandboxed
   (`WallpicsMac.entitlements`), so they use different Application Support trees. Debug also forces
   `isPro = true` (`SubscriptionState.swift:9-18`). Local "works for me" testing does not exercise
   the shipped configuration.
4. `WallpicsMac-Direct.entitlements` and `WallpicsWidgetExtension-Direct.entitlements` exist on
   disk but are referenced nowhere in `project.pbxproj` — the unsandboxed "Direct" distribution
   has no build configuration, so the animated lock screen stays disabled in any Release build
   (`LockScreenAerial.isSupported` requires `!isSandboxed`).
5. The new save-failure string has no `Localizable.xcstrings` entry yet.

## Verification run
- `xcodebuild -scheme WallpicsMac -configuration Debug build` → BUILD SUCCEEDED
- `xcodebuild -scheme WallpicsMac -configuration Release CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED
  (signed Release needs `-allowProvisioningUpdates`; not run)
- Standalone harness replicating the renderer: all cases fit after the fix on 1470×956, 1920×1080,
  2560×1440, 3456×2234, including a 984-char note and an emoji/Cyrillic note.
- Render cost, isolated: 1080p 9.1 → 10.4 ms; 3456×2234 30.4 → 30.5 ms; worst case 32.8 ms.
- Not run: the app itself was never launched, so no on-desktop visual confirmation.

## Exact next step
Bump the build and get it to Danil; the panel title fix is what he reported. Decide separately
whether the grid tile caption should also follow a renamed pet (currently it does) or stay on the
catalog name.
