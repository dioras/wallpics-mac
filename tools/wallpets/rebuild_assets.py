#!/usr/bin/env python3
import argparse, json, os, subprocess, sys
from pathlib import Path
import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "WallpicsMac" / "Resources" / "Pets"
SRC_DIRS = [Path(os.path.expanduser(d)) for d in
            ["~/Downloads", "~/Downloads/drive-download-20260817T154615Z-1-001"]]

PETS = {
    "panther":  ("copy_3CECB412-664E-4AA4-AA40-C8FA9C92561E.mov", dict(core=4,  lo=1, hi=4,  close=6,  area=20000)),
    "axolotl":  ("copy_241AFE44-52BD-48BB-9FB3-97C50961F239.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
    "doberman": ("copy_6233F282-A5A9-4A07-BD8E-4F6A416BA1D5.mov", dict(core=5,  lo=1, hi=6,  close=8,  area=4000)),
    "panda":    ("copy_8BBE2DF2-7265-44CC-9019-12F0A14FFF73.mov", dict(core=6,  lo=1, hi=8,  close=8,  area=4000)),
    "poodle":   ("copy_B5BB7200-24CB-4E74-A5D2-A3DEE7A00FD4.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
    "golden":   ("copy_CB713CD3-F948-49E9-B6A9-4E5D8905D3C8.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
    "hamster":  ("copy_D3A4A329-C0C8-495E-976E-358E8A7CDB06.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
    "wolf":     ("copy_D71FF81A-B988-4022-AF30-6D13B313098B.mov", dict(core=5,  lo=1, hi=6,  close=8,  area=4000)),
    "kitten":   ("copy_E820265D-3C73-4217-8078-E31E7735160B.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
    "pig":      ("copy_EF93FC21-D21F-4A76-AAB6-4470C5AB47C3.mov", dict(core=10, lo=2, hi=12, close=6,  area=4000)),
}

ALPHA_FLOOR = 0.30
POSES = 180
OUT_H = 900
BITRATE = "8M"


def find_source(name):
    for d in SRC_DIRS:
        if (d / name).exists():
            return d / name
    return None


def probe(path):
    s = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,nb_frames", "-of", "json", str(path)],
        capture_output=True, text=True, check=True).stdout)["streams"][0]
    return int(s["width"]), int(s["height"]), int(s["nb_frames"])


def stream(path, w, h, indices):
    sel = "+".join(f"eq(n\\,{i})" for i in indices)
    cmd = ["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"select='{sel}'",
           "-vsync", "0", "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    n = w * h * 3
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=n * 2)
    while True:
        buf = proc.stdout.read(n)
        if len(buf) < n:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    proc.stdout.close()
    proc.wait()


def matte(rgb, cfg):
    m = rgb.max(axis=2).astype(np.float32)
    r = cfg["close"]
    core = ndimage.binary_closing(m >= cfg["core"], np.ones((r * 2 + 1,) * 2, bool))
    lbl, n = ndimage.label(core)
    if n:
        sizes = ndimage.sum(core, lbl, range(1, n + 1))
        keep = np.zeros(n + 1, bool)
        keep[1:][sizes >= cfg["area"]] = True
        core = keep[lbl]
    bg = ~core
    seeds = np.zeros_like(core)
    seeds[0, :] = True; seeds[:, 0] = True; seeds[:, -1] = True
    fill = ~ndimage.binary_propagation(seeds & bg, mask=bg)
    interior = ndimage.binary_erosion(fill, np.ones((9, 9), bool))
    band = ndimage.binary_dilation(fill, np.ones((13, 13), bool)) & ~interior
    ref = ndimage.maximum_filter(m, size=25)
    coverage = np.clip(m / np.maximum(ref, cfg["hi"]), 0, 1)
    return np.where(interior, 1.0, np.where(band, coverage, 0.0)).astype(np.float32)


def resize_rgba(rgba, out_w, out_h):
    """Area-average in premultiplied space, then unpremultiply with a floor.

    The floor is the fix for the white halo: dividing a premultiplied colour by a
    near-zero alpha explodes it toward white, which is exactly what produced the
    bright rim around every pet.
    """
    h, w = rgba.shape[:2]
    stack = np.concatenate([rgba[..., :3].astype(np.float32),
                            rgba[..., 3:4].astype(np.float32)], axis=2)
    ys = np.linspace(0, h, out_h + 1).astype(int)
    xs = np.linspace(0, w, out_w + 1).astype(int)
    cum = np.pad(stack.cumsum(0).cumsum(1), ((1, 0), (1, 0), (0, 0)))
    y0, y1, x0, x1 = ys[:-1], ys[1:], xs[:-1], xs[1:]
    block = (cum[np.ix_(y1, x1)] - cum[np.ix_(y0, x1)]
             - cum[np.ix_(y1, x0)] + cum[np.ix_(y0, x0)])
    area = ((y1 - y0)[:, None] * (x1 - x0)[None, :]).astype(np.float32)[..., None]
    avg = block / np.maximum(area, 1)
    alpha = np.clip(avg[..., 3:4], 0, 255)
    divisor = np.maximum(alpha, ALPHA_FLOOR * 255.0)
    rgb = np.clip(avg[..., :3] * 255.0 / divisor, 0, 255)
    res = np.empty((out_h, out_w, 4), np.uint8)
    res[..., :3] = rgb.astype(np.uint8)
    res[..., 3] = alpha[..., 0].astype(np.uint8)
    return res


def write_png(path, rgba):
    h, w = rgba.shape[:2]
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba",
                          "-s", f"{w}x{h}", "-i", "-", "-frames:v", "1", "-y", str(path)],
                         stdin=subprocess.PIPE)
    p.communicate(rgba.tobytes())


def encode(frames, w, h, dst):
    p = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
         "-s", f"{w}x{h}", "-r", "30", "-i", "-", "-an", "-c:v", "hevc_videotoolbox",
         "-alpha_quality", "0.95", "-allow_sw", "1", "-pix_fmt", "bgra",
         "-tag:v", "hvc1", "-g", "1", "-b:v", BITRATE, str(dst)], stdin=subprocess.PIPE)
    for f in frames:
        p.stdin.write(f.tobytes())
    p.stdin.close()
    if p.wait() != 0:
        raise RuntimeError(f"encode failed: {dst}")


def build(slug):
    name, cfg = PETS[slug]
    src = find_source(name)
    if src is None:
        print(f"[{slug}] SOURCE MISSING: {name}", file=sys.stderr)
        return False
    w, h, total = probe(src)
    stride = max(1, total // POSES)
    idx = list(range(0, total, stride))[:POSES]
    print(f"[{slug}] {w}x{h} {total}f -> {len(idx)} poses (full res)", flush=True)

    alphas = [(matte(f, cfg) * 255).astype(np.uint8) for f in stream(src, w, h, idx)]
    if not alphas:
        print(f"[{slug}] no frames decoded", file=sys.stderr)
        return False

    solid = np.zeros_like(alphas[0], bool)
    for a in alphas:
        solid |= a > 5
    rows = np.flatnonzero(solid.any(axis=1)); cols = np.flatnonzero(solid.any(axis=0))
    top, bot, left, right = int(rows[0]), int(rows[-1]) + 1, int(cols[0]), int(cols[-1]) + 1
    py, px = int((bot - top) * 0.02), int((right - left) * 0.02)
    top, left = max(0, top - py), max(0, left - px)
    bot, right = min(h, bot + py), min(w, right + px)
    ch, cw = bot - top, right - left
    out_h = min(OUT_H, ch) // 2 * 2
    out_w = max(2, int(round(cw * out_h / ch)) // 2 * 2)
    print(f"[{slug}] crop {cw}x{ch} -> {out_w}x{out_h}", flush=True)

    poster = {}

    def frames():
        for i, rgb in enumerate(stream(src, w, h, idx)):
            rgba = np.empty((ch, cw, 4), np.uint8)
            rgba[..., :3] = rgb[top:bot, left:right]
            rgba[..., 3] = alphas[i][top:bot, left:right]
            scaled = resize_rgba(rgba, out_w, out_h)
            if i == 0:
                poster["img"] = scaled.copy()
            yield scaled

    d = OUT / slug
    encode(frames(), out_w, out_h, d / "pet.mov")
    if "img" in poster:
        write_png(d / "poster.png", poster["img"])
        a = poster["img"][..., 3]
        r = np.flatnonzero((a > 16).sum(axis=1) > 2)
        st, sb = int(r[0]), int(r[-1]) + 1
    else:
        st, sb = 0, out_h

    meta = json.loads((d / "pet.json").read_text())
    meta.update(width=out_w, height=out_h,
                subjectTop=round(st / out_h, 4),
                subjectBottom=round(sb / out_h, 4),
                subjectHeight=round((sb - st) / out_h, 4))
    (d / "pet.json").write_text(json.dumps(meta, indent=1))
    mb = (d / "pet.mov").stat().st_size / 1e6
    print(f"[{slug}] done {mb:.1f} MB  subjectHeight={meta['subjectHeight']}", flush=True)
    return True


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("slugs", nargs="*", default=[])
    a = ap.parse_args()
    for s in (a.slugs or list(PETS)):
        build(s)
