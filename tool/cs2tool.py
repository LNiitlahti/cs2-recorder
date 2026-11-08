#!/usr/bin/env python3
"""Demo helper for the CS2 Recorder wizard.

Every command prints ONE JSON object on stdout. Errors print
{"ok": false, "error": "..."} and exit with code 1.

  decompress <src> <dst>                 .dem.zst / .dem.bz2 -> .dem
  info <demo>                            map, header, players with kill counts
  kills <demo> <steamid>                 that player's kills + own death ticks
  campath <demo> <steamid> <anchor> <end> <out.xml> [--fov 50] [--dist 110] [--cache dir]
                                         over-the-shoulder camera path for HLAE
"""
import argparse
import json
import math
import os
import sys
import traceback

TICKRATE = 64


def out(obj):
    sys.stdout.write(json.dumps(obj, default=str))
    sys.stdout.flush()


def fail(msg):
    out({"ok": False, "error": msg})
    sys.exit(1)


def sid(v):
    """Steam IDs come back as int, float or str depending on the parser version."""
    if v is None:
        return ""
    try:
        if isinstance(v, float) and math.isnan(v):
            return ""
        return str(int(v))
    except (ValueError, TypeError):
        return str(v)


# --------------------------------------------------------------- decompress
def cmd_decompress(a):
    src, dst = a.src, a.dst
    tmp = dst + ".part"
    low = src.lower()
    if low.endswith(".zst"):
        import zstandard
        with open(src, "rb") as f, open(tmp, "wb") as g:
            zstandard.ZstdDecompressor().copy_stream(f, g)
    elif low.endswith(".bz2"):
        import bz2
        import shutil
        with bz2.open(src, "rb") as f, open(tmp, "wb") as g:
            shutil.copyfileobj(f, g, 16 * 1024 * 1024)
    elif low.endswith(".gz"):
        import gzip
        import shutil
        with gzip.open(src, "rb") as f, open(tmp, "wb") as g:
            shutil.copyfileobj(f, g, 16 * 1024 * 1024)
    else:
        fail("Unknown compressed format: " + src)
    os.replace(tmp, dst)
    out({"ok": True, "path": dst})


# --------------------------------------------------------------- parsing helpers
def parser(path):
    from demoparser2 import DemoParser
    return DemoParser(path)


def deaths_df(p):
    """player_death events with round number; works across demoparser2 versions."""
    for other in (["total_rounds_played", "is_warmup_period"], ["total_rounds_played"], []):
        try:
            return p.parse_event("player_death", other=other)
        except Exception:
            continue
    return p.parse_event("player_death")


def col(df, name, default=None):
    return df[name] if name in df.columns else [default] * len(df)


# --------------------------------------------------------------- info
def cmd_info(a):
    p = parser(a.demo)
    header = {}
    try:
        header = {str(k): str(v) for k, v in dict(p.parse_header()).items()}
    except Exception as e:  # header is nice-to-have
        header = {"error": str(e)}

    d = deaths_df(p)
    players = {}
    # Player list from player_info when available (gives everyone, even 0 kills).
    try:
        pi = p.parse_player_info()
        for _, r in pi.iterrows():
            s = sid(r.get("steamid"))
            if s and s != "0":
                players[s] = {"steamid": s, "name": str(r.get("name", "")), "kills": 0}
    except Exception:
        pass
    warm = col(d, "is_warmup_period", False)
    for i, r in enumerate(d.itertuples(index=False)):
        rd = r._asdict()
        if bool(warm[i]):
            continue
        s = sid(rd.get("attacker_steamid"))
        if not s or s == "0":
            continue
        if s == sid(rd.get("user_steamid")):
            continue  # suicide
        e = players.setdefault(s, {"steamid": s, "name": str(rd.get("attacker_name", "")), "kills": 0})
        if not e["name"]:
            e["name"] = str(rd.get("attacker_name", ""))
        e["kills"] += 1
    pl = sorted(players.values(), key=lambda x: (-x["kills"], x["name"].lower()))
    max_tick = int(d["tick"].max()) if len(d) else 0
    out({"ok": True, "map": header.get("map_name", "?"), "header": header,
         "players": pl, "max_tick": max_tick, "tickrate": TICKRATE})


# --------------------------------------------------------------- kills
def cmd_kills(a):
    p = parser(a.demo)
    d = deaths_df(p)
    rounds = col(d, "total_rounds_played", None)
    warm = col(d, "is_warmup_period", False)
    kills, deaths = [], []
    for i, r in enumerate(d.itertuples(index=False)):
        rd = r._asdict()
        if bool(warm[i]):
            continue
        rnd = rounds[i]
        rnd = int(rnd) + 1 if rnd is not None and not (isinstance(rnd, float) and math.isnan(rnd)) else 0
        att, vic = sid(rd.get("attacker_steamid")), sid(rd.get("user_steamid"))
        if vic == a.steamid:
            deaths.append({"tick": int(rd["tick"]), "round": rnd})
        if att != a.steamid or vic == a.steamid:
            continue
        kills.append({
            "tick": int(rd["tick"]),
            "round": rnd,
            "weapon": str(rd.get("weapon", "") or ""),
            "victim": str(rd.get("user_name", "") or ""),
            "headshot": bool(rd.get("headshot", False)),
            "smoke": bool(rd.get("thrusmoke", False)),
            "noscope": bool(rd.get("noscope", False)),
            "wallbang": int(rd.get("penetrated", 0) or 0) > 0,
            "blind": bool(rd.get("attackerblind", False)),
        })
    kills.sort(key=lambda k: k["tick"])
    out({"ok": True, "kills": kills, "deaths": deaths})


# --------------------------------------------------------------- camera path
def occupancy(p, demo, cache_dir):
    """Cells where any living player stood during the match = known open space."""
    import numpy as np
    cache = None
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
        st = os.stat(demo)
        cache = os.path.join(cache_dir, "occ_%d_%d.npy" % (st.st_size, int(st.st_mtime)))
        if os.path.exists(cache):
            return np.load(cache)
    d = deaths_df(p)
    max_tick = int(d["tick"].max()) + 3000 if len(d) else 200000
    df = p.parse_ticks(["X", "Y", "Z", "is_alive"], ticks=list(range(0, max_tick, 16)))
    df = df[df["is_alive"] == True]  # noqa: E712
    pts = df[["X", "Y", "Z"]].dropna().to_numpy(dtype=float)
    if cache:
        np.save(cache, pts)
    return pts


class OpenSpace:
    """Walked-space test. A camera point is 'open' if players stood in that 24-unit
    column within a sensible height band below it. No map geometry is used."""
    CELL = 24.0

    def __init__(self, pts):
        self.cells = {}
        for x, y, z in pts:
            k = (int(math.floor(x / self.CELL)), int(math.floor(y / self.CELL)))
            lo_hi = self.cells.get(k)
            if lo_hi is None:
                self.cells[k] = [z, z]
            else:
                if z < lo_hi[0]:
                    lo_hi[0] = z
                if z > lo_hi[1]:
                    lo_hi[1] = z

    def ok(self, x, y, z):
        k = (int(math.floor(x / self.CELL)), int(math.floor(y / self.CELL)))
        c = self.cells.get(k)
        if c is None:
            return False
        # camera may sit up to ~130 units above a walked floor, and not below it
        return c[0] - 8 <= z <= c[1] + 130


def gauss(a, s):
    import numpy as np
    a = np.asarray(a, float)
    if s <= 0 or len(a) < 3:
        return a
    r = int(3 * s)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / s) ** 2)
    k /= k.sum()
    pad = np.pad(a, (r, r), mode="edge")
    return np.convolve(pad, k, "valid")


def running_min(a, w):
    import numpy as np
    a = np.asarray(a, float)
    h = w // 2
    pad = np.pad(a, (h, h), mode="edge")
    return np.array([pad[i:i + w].min() for i in range(len(a))])


def ss(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def build_shoulder_path(track, space, fov=50.0, dist=110.0, side=28.0, up=14.0):
    """track: list of (tick, X, Y, Z, pitch, yaw) every 2 ticks, starting at the anchor tick.
    Returns (points, shortened_fraction). points = (t, x, y, z, fov, pitch, yaw)."""
    import numpy as np
    tr = np.asarray(track, float)
    ticks = tr[:, 0]
    X, Y, Z = gauss(tr[:, 1], 3), gauss(tr[:, 2], 3), gauss(tr[:, 3], 3)
    pitch = gauss(tr[:, 4], 4)
    yaw = np.degrees(gauss(np.unwrap(np.radians(tr[:, 5])), 4))

    # per sample: pull the camera in until the line eye->camera stays in walked space
    scales = []
    for i in range(len(ticks)):
        ya = math.radians(yaw[i])
        fwd = (math.cos(ya), math.sin(ya))
        right = (fwd[1], -fwd[0])
        eye = (X[i], Y[i], Z[i] + 64)
        best = 0.3
        for s in (1.0, 0.85, 0.7, 0.55, 0.4, 0.3):
            cx = eye[0] - dist * s * fwd[0] + side * s * right[0]
            cy = eye[1] - dist * s * fwd[1] + side * s * right[1]
            cz = eye[2] + up
            good = True
            for u in (0.35, 0.6, 0.8, 1.0, 1.15):  # 1.15 = small margin behind the camera
                px, py = eye[0] + (cx - eye[0]) * u, eye[1] + (cy - eye[1]) * u
                if not space.ok(px, py, cz):
                    good = False
                    break
            if good:
                best = s
                break
        scales.append(best)
    raw = np.array(scales)
    sc = gauss(running_min(raw, 15), 6)  # react early, move smoothly
    shortened = float((raw < 0.999).mean())

    pts = []
    T0 = ticks[0]
    n = len(ticks)
    for i in range(n):
        ya, pi_ = math.radians(yaw[i]), math.radians(pitch[i])
        fwd = (math.cos(ya), math.sin(ya))
        right = (fwd[1], -fwd[0])
        eye = np.array([X[i], Y[i], Z[i] + 64])
        s = sc[i]
        cam = eye + np.array([-dist * s * fwd[0] + side * s * right[0],
                              -dist * s * fwd[1] + side * s * right[1], up])
        # look where the player looks: 700 units along his view ray
        view = np.array([math.cos(pi_) * fwd[0], math.cos(pi_) * fwd[1], -math.sin(pi_)])
        tgt = eye + 700 * view
        dv = tgt - cam
        cyaw = math.degrees(math.atan2(dv[1], dv[0]))
        cpitch = -math.degrees(math.atan2(dv[2], math.hypot(dv[0], dv[1])))
        t = (ticks[i] - T0) / TICKRATE
        f = fov + 8 * (1 - ss(t / 2.0))  # gentle 2 s push-in at the start
        pts.append([t, cam[0], cam[1], cam[2], f, cpitch, cyaw])
    # unwrap camera yaw so HLAE never spins 360 degrees
    yw = np.degrees(np.unwrap(np.radians([p[6] for p in pts])))
    for p, y in zip(pts, yw):
        p[6] = float(y)
    return pts, shortened


def write_campath(pts, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n')
        f.write('<campath positionInterp="linear" rotationInterp="sLinear" fovInterp="linear">\n<points>\n')
        for t, x, y, z, fov, pitch, yaw in pts:
            f.write('<p t="%.6f" x="%.3f" y="%.3f" z="%.3f" fov="%.3f" rx="0.000" ry="%.3f" rz="%.3f"/>\n'
                    % (t, x, y, z, fov, pitch, yaw))
        f.write("</points>\n</campath>\n")


def cmd_campath(a):
    p = parser(a.demo)
    space = OpenSpace(occupancy(p, a.demo, a.cache))
    ticks = list(range(a.anchor, a.end + 1, 2))
    df = p.parse_ticks(["X", "Y", "Z", "pitch", "yaw", "is_alive"], ticks=ticks)
    df = df[df["steamid"].map(sid) == a.steamid].sort_values("tick")
    if df.empty:
        fail("Player %s not found in ticks %d-%d" % (a.steamid, a.anchor, a.end))
    track = df[["tick", "X", "Y", "Z", "pitch", "yaw"]].dropna().to_numpy(float).tolist()
    if len(track) < 10:
        fail("Too few position samples for the camera path")
    pts, shortened = build_shoulder_path(track, space, fov=a.fov, dist=a.dist)
    write_campath(pts, a.out)
    out({"ok": True, "path": a.out, "points": len(pts), "shortened": round(shortened, 3),
         "duration": round(pts[-1][0], 3)})


# --------------------------------------------------------------- self test (no demo needed)
def cmd_selftest(a):
    import numpy as np
    # a straight 2000-unit corridor, 200 wide, player walking +X while looking +X
    pts = [(x, y, 0.0) for x in np.arange(-500, 2500, 8) for y in np.arange(-100, 100, 8)]
    space = OpenSpace(pts)
    track = [(1000 + i * 2, 100 + i * 2.0, 0.0, 0.0, 5.0, 0.0) for i in range(200)]
    p1, sh1 = build_shoulder_path(track, space)
    assert sh1 == 0.0, sh1
    assert abs(p1[100][6]) < 30 and p1[100][1] < track[100][1], p1[100]
    # same walk but the corridor is only 30 wide -> camera must pull in (right offset hits the wall)
    space2 = OpenSpace([(x, y, 0.0) for x in np.arange(-500, 2500, 8) for y in np.arange(-15, 15, 4)])
    p2, sh2 = build_shoulder_path(track, space2)
    assert sh2 > 0.5, sh2
    # yaw wrap: player turning through 180 must not jump 360
    track3 = [(1000 + i * 2, 100.0, 0.0, 0.0, 0.0, ((170 + i * 0.5 + 180) % 360) - 180) for i in range(100)]
    p3, _ = build_shoulder_path(track3, OpenSpace([(x, y, 0.0) for x in np.arange(-400, 600, 8) for y in np.arange(-400, 400, 8)]))
    jumps = max(abs(p3[i + 1][6] - p3[i][6]) for i in range(len(p3) - 1))
    assert jumps < 10, jumps
    write_campath(p1, os.path.join(a.dir, "selftest.xml"))
    out({"ok": True, "corridor_shortened": sh2, "max_yaw_step": round(jumps, 3)})


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("decompress"); s.add_argument("src"); s.add_argument("dst")
    s = sp.add_parser("info"); s.add_argument("demo")
    s = sp.add_parser("kills"); s.add_argument("demo"); s.add_argument("steamid")
    s = sp.add_parser("campath")
    s.add_argument("demo"); s.add_argument("steamid"); s.add_argument("anchor", type=int)
    s.add_argument("end", type=int); s.add_argument("out")
    s.add_argument("--fov", type=float, default=50.0); s.add_argument("--dist", type=float, default=110.0)
    s.add_argument("--cache", default="")
    s = sp.add_parser("selftest"); s.add_argument("dir")
    a = ap.parse_args()
    try:
        {"decompress": cmd_decompress, "info": cmd_info, "kills": cmd_kills,
         "campath": cmd_campath, "selftest": cmd_selftest}[a.cmd](a)
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write(traceback.format_exc())
        fail("%s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
