#!/usr/bin/env python3
"""Recompute faceCenter from the rebuilt poster so it matches the new crop.

Mirrors the original derivation: alpha-weighted centroid of the top 32% band of
the neutral pose, normalised to the frame.
"""
import glob, json, os, subprocess
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

for d in sorted(glob.glob(os.path.join(ROOT, "WallpicsMac/Resources/Pets/*/"))):
    slug = os.path.basename(d.rstrip("/"))
    poster, meta_path = d + "poster.png", d + "pet.json"
    if not (os.path.exists(poster) and os.path.exists(meta_path)):
        continue
    s = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "json", poster],
        capture_output=True, text=True).stdout)["streams"][0]
    w, h = s["width"], s["height"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", poster, "-f", "rawvideo",
                          "-pix_fmt", "rgba", "-"], capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8)[:w * h * 4].reshape(h, w, 4)[..., 3].astype(np.float32) / 255.0
    band = max(1, int(h * 0.32))
    top = a[:band]
    total = max(float(top.sum()), 1e-3)
    fx = float((top * np.arange(w)[None, :]).sum() / total) / w
    fy = float((top * np.arange(band)[:, None]).sum() / total) / h
    meta = json.loads(open(meta_path).read())
    old = meta.get("faceCenter", {})
    meta["faceCenter"] = {"x": round(fx, 4), "y": round(fy, 4)}
    open(meta_path, "w").write(json.dumps(meta, indent=1))
    print(f"{slug:9s} faceCenter {old.get('x')},{old.get('y')} -> {meta['faceCenter']['x']},{meta['faceCenter']['y']}")
