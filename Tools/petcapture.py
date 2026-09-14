import json
import math
import os
import sys
import time

import AppKit
import Quartz
from Foundation import NSURL

OUT = sys.argv[1]
SCENARIO = sys.argv[2] if len(sys.argv) > 2 else "top"
os.makedirs(OUT, exist_ok=True)


def pet_window():
    screens = [(s.frame().size.width, s.frame().size.height) for s in AppKit.NSScreen.screens()]
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    best = None
    for w in info:
        if w.get("kCGWindowOwnerName") != "WallPics":
            continue
        b = w["kCGWindowBounds"]
        if (b["Width"], b["Height"]) in screens and w.get("kCGWindowLayer", 0) < 0:
            if best is None or w.get("kCGWindowLayer", 0) > best[1]:
                best = (w["kCGWindowNumber"], w.get("kCGWindowLayer", 0), b)
    return best


REGION = None


def capture(wid, path):
    img = Quartz.CGWindowListCreateImage(REGION if REGION is not None else Quartz.CGRectNull,
                                         Quartz.kCGWindowListOptionIncludingWindow, wid,
                                         Quartz.kCGWindowImageBoundsIgnoreFraming)
    if img is None:
        return False
    dest = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(path), "public.png", 1, None)
    Quartz.CGImageDestinationAddImage(dest, img, None)
    return bool(Quartz.CGImageDestinationFinalize(dest))


def move(x, y):
    ev = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y), 0)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


found = pet_window()
if not found:
    print("no pet window")
    sys.exit(1)
wid, _, bounds = found
main = AppKit.NSScreen.mainScreen().frame()
W, H = main.size.width, main.size.height
face = (W / 2, H - 460 * 0.78)
REGION = Quartz.CGRectMake(W / 2 - 360, H - 620, 720, 620)
radius = 420
if SCENARIO == "top":
    angles = [-20, -20, -20, -50, -80, -100, -130, -160, -200]
elif SCENARIO == "sides":
    angles = [-10, -170, -10, -100, 60, -60]
else:
    angles = [float(a) for a in SCENARIO.split(",")]
log = []
start = time.time()
frame = 0
for a in angles:
    x = face[0] + radius * math.cos(math.radians(a))
    y = face[1] + radius * math.sin(math.radians(a))
    move(x, y)
    t0 = time.time()
    while time.time() - t0 < 0.8:
        path = os.path.join(OUT, f"f{frame:04d}.png")
        ok = capture(wid, path)
        log.append(dict(frame=frame, t=round(time.time() - start, 3), angle=a, ok=ok))
        frame += 1
        time.sleep(0.02)
json.dump(dict(window=wid, bounds=dict(bounds), face=face, log=log), open(os.path.join(OUT, "log.json"), "w"), indent=1)
print("captured", frame, "frames from window", wid, "bounds", bounds)
