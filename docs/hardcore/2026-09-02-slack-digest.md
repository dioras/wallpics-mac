# Slack digest (fizizi workspace), 2026-08-03 → 2026-09-02

Sources: #wallpics-app (42 threads), #wallpics-dashboard, #diy-wallpapers, #wallpaper-testing, #wallpics-videos, #ab-tests, DM with Simon, @iOS group DM. #parallax and #wallpics-outpainting are not joined; #general returned nothing; #ai-drama silent since July. 37 other DMs empty in range.

## People
Simon = client/owner · Alex Silver = us (macOS + iOS) · Ahmet = iOS builds/TestFlight · Dima = Android · Mykhailo (Misha) = backend · Andrei = web/dashboard · Huseyin = content/QA.

## Pets (macOS) storyline
- 08-19→08-24: iterative mac builds 1.0.1(98) → 99 (Apple rejected "mac" in name) → 1.0.2(109) → (114) → (115). Cursor sensitivity, mirror dead-band, alignment.
- 08-26: Misha ships backend pets (list + store endpoints). Simon dislikes the mirror jump; wants non-mirrored full video.
- 08-27: webm unplayable on mac → Alex asks for `video_mov` (ProRes 4444); Misha adds it same day. Andrei's web prototype: "corner to corner" vs "through the middle". Alex: pivotUp should be the deepest up frame.
- 08-28: background/cutout fixed after ffmpeg update; mirroring dropped ("mirroring is definitely out the window"); Black Cat v4 is the best; tracking still imprecise.
- 09-01: Simon's list: (1) center lock on top, (2) "WallpicsMac" name leftovers (old app on disk), (3) preview too big, (4) weird cursor movement. Misha: "app can skip the straight looking frames when the cursor is on the top". Chicken choppy = Seedance (Huseyin/Misha joke, Simon accepted). Simon: "center only when the cursor is out of the desktop".
- 09-02: 16:9 vs 1:1 → 1:1 agreed; Misha to add empty area around the animal.
- Pipeline is Replicate → Seedance (not Kling). Replicate credits ran out once on 09-01 (Simon re-applied).

## Unanswered asks of Alex (as of 09-02)
| Date | Ask | Where |
|---|---|---|
| 08-11 | release notes with each build | #wallpics-app |
| 08-15→20 | do themes support live wallpaper / live widget? | #wallpics-app (5-day thread, no reply) |
| 08-18 | themes not showing live wallpaper thumbnails | #wallpics-dashboard |
| 08-21 | video → moving animal converter | #wallpics-app (superseded by pipeline work) |
| 08-24 | "do we still leave this horizontal flip?" | #wallpics-app (superseded: mirroring dropped 08-28) |
| 08-30 | themes installing icons separately + "not signed" labels | #wallpics-app |
| 08-31 | Premium theme saving hiccup, app stopped on widgets | #wallpics-app |
| 09-01 | KlingAI credits exhausted, AI "in a mess", "you did not let Ahmet know" | DM |
| 09-01 | availability during days | DM |
Open from Alex's side: server load for the DIY pet script (08-22, Misha never answered); $700 package ask (08-10 DM) with no visible "sent" confirmation.

## iOS facts checked in the 08-19 snapshot (`~/Downloads/Wallpics-develop 2`)
- Theme icons install via ONE configuration profile of `com.apple.webClip.managed` payloads (`ThemeProfileBuilder`), served by `LocalProfileServer`. Unsigned → iOS shows "Not Signed"; signing needs a server-side certificate.
- Themes carry `lockLive` (live lock wallpaper) and animated widgets are baked as "<name> Live" (`ThemeWidgetInstaller`).
- AI Live tab: `KlingConfig.unlimitedGenerationsForTesting || RemoteFlags.aiVideoEnabled` in Release.

## Other context worth knowing
- iOS app size complaints (08-05, 08-31) unresolved; iOS crashes reported 08-30; `/api/me/likes` migration pending on iOS.
- Dashboard: age-rating tiers, 100 MB / 10-15 s / full-HD upload cap (iOS cannot render 4K), unified accounts discussion.
- A/B: platform-based download ranking live since 08-24; Android sends no impressions.
- Content team films the Mac app for marketing (08-27/28).
