# Plan — Pets layout + Browse "Home" rails (2026-09-03)

Tier: standard · Mode: change-feature · Autonomous · Security lane: no (UI only, no new inputs or network beyond existing API calls)

## Deliverable
1. **Pets tab**: preview stays top-left at its capped size; settings become a compact block under it (same left column); the pet chooser grid moves to the right of that column. Below ~1180 pt window width fall back to the current stacked layout.
2. **Browse tab**: add a **Home** mode (default) to the type switch: [Home][Photos][Live][Shaders]. Home keeps the giant featured hero and the Most Popular strip, then shows one horizontal rail per type (Live, Photos, Shaders, Pets), each with a "See all" that opens that type's existing page (type tabs + category chips + sub-categories + All Wallpapers grid unchanged). Typing in search while on Home switches to the current type page so search keeps working as today.

Non-goals: per-category rails (Simon asked for type rails), iOS, changing card visuals, new endpoints.

## Acceptance (observable)
- AC1 Pets at 1728 pt: preview left, settings under it inside one card ≤ 560 pt wide, grid on the right with ≥ 4 columns; no empty band between preview and settings (screenshot).
- AC2 Pets at 1100 pt: stacked layout identical to today (screenshot).
- AC3 Browse Home at launch: hero + popular strip + 4 rails (Live, Photos, Shaders, Pets) each with See all; clicking See all on Live shows the Live page with category chips (screenshot).
- AC4 Type pages unchanged: chips, sub-chips, sort, infinite grid still work (code path untouched; screenshot of Live page).
- AC5 Search while on Home: typing a query shows the grid search results (existing behaviour) instead of an empty home.
- AC6 Build green; no new warnings in changed files.

## Mirror
- `BrowseView.heroCarousel` (HWheelScroll rail) and `SectionHeader` (already has See all) — `WallpicsMac/Views/BrowseView.swift:130,324`.
- `WallpaperCard` for rail cards (16:10, min height 140) — `WallpicsMac/Views/WallpaperCard.swift:16`.
- `PetTile` for the pets rail — `WallpicsMac/Pets/Views/PetsView.swift:367`.
- Parallel fetch: `WallpaperAPI.desktopWallpapers(collection:page:perPage:sortOrder:)`.

## Tasks
1. `BrowseViewModel`: `mode` (.home/.collection), `homeRails`, `loadHomeRailsIfNeeded/loadHomeRails` (3 parallel fetches, popular, 14 each), `showHome()`, `setCollection` switches mode and reloads when needed.
2. `BrowseView`: Home segment in `CollectionFilter`, `homeRails` view (rails + pets rail + error/loading), hero fallback to popular rail, hide chips/grid in Home.
3. `ContentView`: search typed in Home → `setCollection(current)`.
4. `PetsView`: `GeometryReader` width switch; `activePetCard` as a vertical card (preview + compact settings) with fixed column width; right column = toolbar + grid.
5. Verify: build, screenshots at 1728 and 1100 widths, Home + See all + Live page.

## Risks / rollback
- Home rails cost 3 extra requests on first open (14 items each); cached until reload. Rollback = revert the two files.
- `PetCatalog.all` is MainActor; the rail reads it from the view (MainActor) — fine.

## Outcome (2026-09-03)
- AC1 ✓ Pets at 1728: preview 628×406 in a 660 pt left column, compact settings under it, 5-column grid right (`scratchpad/live5/pets_wide2_small.png`). AC2 ✓ stacked at 1100 (`pets_narrow_small.png`).
- AC3 partial: Home renders hero + popular strip + [Home|Photos|Live|Shaders] + Live/Photos/Shaders/Pets rails with See all (`home_fresh_small.png`, `home_bottom_trackpad_small.png`); Pets "See all" verified (opened Pets tab); a wallpaper-type See all / segment tap was NOT captured — synthetic clicks kept missing the in-page controls. Code path reviewed clean by the review lane (`setCollection` state machine).
- AC4 ✓ code path untouched (reviewer). AC5 ✓ by code (search → `setCollection(current)`), not exercised.
- AC6 ✓ BUILD SUCCEEDED; harness 59/59.
- Extra: `HWheelScroll` scroll chaining (trackpad vertical → page; wheel → rail until end, then page), verified with both event kinds.
- Review: 0 HIGH; MEDIUMs fixed (cancelled rail load no longer flagged as failure, partial rail failure now retried); LOWs fixed (hero fallback while searching, refreshable on Home, `sideBySide` naming). Open LOW: detail overlay opened from a rail uses the grid list for prev/next.
- Client change mid-task: photo quality checks removed from "Add your pet" (kept as a separate paid job); only decode + JPEG conversion + 20 MB cap remain.
