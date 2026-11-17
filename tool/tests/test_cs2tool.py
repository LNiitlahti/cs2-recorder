import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import cs2tool  # noqa: E402


def K(tick, rnd, hs=False):
    return {"tick": tick, "round": rnd, "headshot": hs}


class Presets(unittest.TestCase):
    def ids(self, kills):
        return {p["id"]: p["kill_ticks"] for p in cs2tool.compute_presets(kills)}

    def test_empty(self):
        self.assertEqual(self.ids([]), {"all": []})

    def test_multikills_and_best_round_tie_earliest(self):
        kills = [K(100, 1), K(110, 1), K(120, 1), K(500, 2), K(510, 2), K(520, 2), K(900, 3)]
        p = self.ids(kills)
        self.assertEqual(p["all"], [100, 110, 120, 500, 510, 520, 900])
        self.assertEqual(p["multikills"], [100, 110, 120, 500, 510, 520])
        self.assertEqual(p["best_round"], [100, 110, 120])
        self.assertNotIn("aces", p)
        self.assertNotIn("clutch", p)

    def test_ace(self):
        kills = [K(10 * i, 4) for i in range(1, 6)] + [K(900, 5)]
        p = self.ids(kills)
        self.assertEqual(p["aces"], [10, 20, 30, 40, 50])
        self.assertEqual(p["best_round"], [10, 20, 30, 40, 50])

    def test_headshots(self):
        p = self.ids([K(1, 1, True), K(2, 1), K(3, 2, True)])
        self.assertEqual(p["headshots"], [1, 3])
        self.assertNotIn("multikills", p)

    def test_unsorted_input(self):
        self.assertEqual(self.ids([K(30, 1), K(10, 1)])["all"], [10, 30])


class Estimate(unittest.TestCase):
    def test_baseline(self):
        # 6 + clean 4 + hud 12 = 22 MB/s at 1080p60, 10 s -> 220
        r = cs2tool.estimate(2, 10, 60, 1920, 1080, ["clean", "hud"])
        self.assertEqual(r["size_mb"], 220.0)
        self.assertEqual(r["minutes"], 9.0)

    def test_scale(self):
        r = cs2tool.estimate(1, 10, 120, 3840, 2160, [])
        self.assertEqual(r["size_mb"], 6 * 8 * 10)

    def test_unknown_layer_ignored(self):
        self.assertEqual(cs2tool.estimate(1, 1, 60, 1920, 1080, ["nope"])["size_mb"], 6.0)


if __name__ == "__main__":
    unittest.main()
