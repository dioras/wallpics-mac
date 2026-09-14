import json
import os
import shutil
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "WallpicsMac", "Resources", "Pets")
SUFFIX = " test"


def main(argv):
    if len(argv) < 2:
        print("usage: installpets.py <built-pets-dir> <src:slug:Name> [...]   (src = folder name inside built-pets-dir)")
        return 2
    keep = "--keep" in argv
    base = argv[1]
    entries = [a.split(":", 2) for a in argv[2:] if a != "--keep"]
    catalog = {"version": 1, "pets": []}
    if keep:
        catalog = json.load(open(os.path.join(ROOT, "catalog.json")))
        catalog["pets"] = [p for p in catalog["pets"] if p["slug"] not in {e[1] for e in entries}]
    else:
        for d in os.listdir(ROOT):
            p = os.path.join(ROOT, d)
            if os.path.isdir(p):
                shutil.rmtree(p)
    for src, slug, name in entries:
        sd = os.path.join(base, src)
        meta = json.load(open(os.path.join(sd, "pet.json")))
        report = json.load(open(os.path.join(sd, "report.json")))
        if report["recommendation"] != "ok":
            print("SKIP", src, report["recommendation"], report["flags"])
            continue
        dd = os.path.join(ROOT, slug)
        shutil.rmtree(dd, ignore_errors=True)
        os.makedirs(dd)
        for f in ("pet.mov", "poster.png"):
            shutil.copy(os.path.join(sd, f), dd)
        label = name + SUFFIX
        meta = {"slug": slug, **meta, "name": label}
        json.dump(meta, open(os.path.join(dd, "pet.json"), "w"), indent=1)
        catalog["pets"].append({"slug": slug, "name": label, "width": meta["width"], "height": meta["height"]})
        seam = report.get("seam")
        print("installed", slug, meta["width"], meta["height"], "seam", seam and (seam["first"], seam["second"]), "flags", report["flags"])
    json.dump(catalog, open(os.path.join(ROOT, "catalog.json"), "w"), indent=1)
    print("catalog", [p["slug"] for p in catalog["pets"]])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
