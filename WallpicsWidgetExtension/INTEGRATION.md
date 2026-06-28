# WallPics native widgets — already wired, here's how to run it

The widget-extension **target is already added to the Xcode project** (done programmatically with the
`xcodeproj` gem) and verified to compile + embed: `WallpicsMac.app/Contents/PlugIns/WallpicsWidgetExtension.appex`.
You do **not** need to create the target by hand. You only need to let Xcode sign it with your dev account
(that part can't be done on a headless/CI box without your Apple login — but your local Xcode does it
automatically).

## What's wired
- New target **WallpicsWidgetExtension** (app-extension, macOS 14, bundle id
  `com.kyragames.AestheticSadWallppapers.WidgetExtension`), embedded into the app's PlugIns.
- App Group `group.com.kyragames.AestheticSadWallpapers` added to BOTH entitlements files
  (`WallpicsMac/WallpicsMac.entitlements` and `WallpicsWidgetExtension/WallpicsWidgetExtension.entitlements`).
- `WidgetSharedExport.sync()` is called from the app on launch and after every widget save/delete — it mirrors
  `instances.json` + each widget's primary image into the App Group container and reloads the widget timelines.
- Extension reads that container (`WidgetSharedStore`) and renders the chosen widget; `SelectWidgetIntent` lets
  the user pick which of their WallPics widgets to show in the system "Edit Widget" panel.

## How to run it (you DON'T need the App Store / distribution account — a personal dev account is enough)
1. Open `WallpicsMac.xcodeproj` in Xcode, signed into your dev account (team Y2QL97Z4A6).
2. Select the **WallpicsMac** scheme. In Signing & Capabilities, both targets should show
   "Automatically manage signing" + your team. If Xcode asks, let it register the App Group + the
   extension's bundle id (it does this for you, online).
3. Build & Run (Cmd+R). Xcode provisions the App Group + extension and launches the app.
4. Right-click the desktop (or open Notification Center / "Edit Widgets") → search **WallPics** → you'll see
   **WallPics Photo** in Small / Medium / Large. Drag it out, then right-click it → Edit Widget → pick one of
   your created widgets. (Create a Photo/Image widget in-app first so there's something to pick.)

## If signing complains
- "No profiles for ... were found" on a headless/CI build is normal — that box just can't talk to the dev
  portal. On your logged-in Xcode it auto-provisions. If your local Xcode shows it: open Signing &
  Capabilities for each target, confirm the team, let it manage signing, click "Try Again".
- For a headless/CI build to succeed you'd register the App Group + extension bundle id in the portal once
  and use a profile that includes them (or connect the account to Xcode Cloud).

## Reality check (Apple's design)
Native macOS widgets are **static timeline snapshots** — no live video, no continuous animation. So native
handles the **static** photo/image widgets (system gallery, add/remove/edit). The **animated + video** widgets
stay as the app's own desktop overlays (the only way they can actually move).

## To undo the target wiring
Backup of the original project file is at `/tmp/project.pbxproj.bak`:
`cp /tmp/project.pbxproj.bak WallpicsMac.xcodeproj/project.pbxproj` and remove the App Group line from
`WallpicsMac/WallpicsMac.entitlements`.
