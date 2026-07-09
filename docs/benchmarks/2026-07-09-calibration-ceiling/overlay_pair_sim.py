#!/usr/bin/env python3
"""Pair-scoped session-overlay with gate/margin sweep (offline proxy).

Design under test: a Manual-mode correction (from -> to) stores the corrected
chunk's embedding as a session-scoped sample keyed by the PAIR (from, to).
At identify time the tracker first takes the plain centroid argmax `pred0`;
only when some pair (from=pred0, to) has overlay samples does it consider
flipping to `to`:

    flip to `to` iff  o >= tau  and  o >= cos(e, centroid_pred0) + delta
    where o = max cos(e, samples[(pred0, to)])

This targets exactly the lived complaint (the same misattribution recurring
after a correction) and cannot disturb chunks whose argmax is not `from`.

Correction model: persistence-2, same as overlay_sim.py. Centroid drift
(v2.4.86 gated append) stays ON in all configs — it ships today.

Sweep: tau in {0.70..0.90}, delta in {0.0, 0.05}.
Success bar (handoff): 04-21 上東→松浦 drops materially; 04-23 no regression.
"""
import json
import math
import os
from collections import defaultdict

HOME = os.path.expanduser("~")
ROSTER = ["松浦", "今村", "上東", "森", "森谷", "神野"]
SEED_WEIGHT = 10.0
SIM_THRESHOLD = 0.5


def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def load_roster_centroids():
    with open(f"{HOME}/QuickTranscriber/speakers.json") as f:
        data = json.load(f)
    return {p["displayName"]: p["embedding"] for p in data if p["displayName"] in ROSTER}


class Profile:
    def __init__(self, seed_embedding):
        self.entries = [(seed_embedding, SEED_WEIGHT)]
        self._recalc()

    def _recalc(self):
        total_w = sum(w for _, w in self.entries)
        dim = len(self.entries[0][0])
        acc = [0.0] * dim
        for e, w in self.entries:
            for i, x in enumerate(e):
                acc[i] += x * w
        self.centroid = [x / total_w for x in acc]

    def gated_append(self, embedding):
        if cos(embedding, self.centroid) >= SIM_THRESHOLD:
            self.entries.append((embedding, 1.0))
            self._recalc()
            return True
        return False


def run(rows, centroids, tau, delta, use_overlay=True):
    profiles = {n: Profile(c) for n, c in centroids.items()}
    pair_overlays = defaultdict(list)  # (from, to) -> [embedding]
    consecutive = None
    corrections = 0
    corrected_idx = set()
    results = []
    flips = {"good": 0, "bad": 0}  # flip made prediction right / wrong

    for idx, r in enumerate(rows):
        e = r.get("embedding")
        if not e:
            results.append(None)
            continue
        gt = r["gt"]

        cscores = {n: cos(e, p.centroid) for n, p in profiles.items()}
        pred0 = max(cscores, key=cscores.get)
        pred = pred0
        if use_overlay:
            best_to, best_o = None, -1.0
            for (frm, to), samples in pair_overlays.items():
                if frm != pred0:
                    continue
                o = max(cos(e, s) for s in samples)
                if o >= tau and o >= cscores[pred0] + delta and o > best_o:
                    best_to, best_o = to, o
            if best_to is not None:
                pred = best_to
                was_right = pred0 == gt
                now_right = pred == gt
                if now_right and not was_right:
                    flips["good"] += 1
                elif was_right and not now_right:
                    flips["bad"] += 1

        results.append((gt, pred))

        if pred != gt:
            if consecutive and consecutive[0] == gt and consecutive[1] == pred:
                consecutive = (gt, pred, consecutive[2] + 1)
            else:
                consecutive = (gt, pred, 1)
            if consecutive[2] >= 2 and gt in profiles:
                consecutive = None
                corrections += 1
                corrected_idx.add(idx)
                profiles[gt].gated_append(e)
                if use_overlay:
                    pair_overlays[(pred, gt)].append(e)
        else:
            consecutive = None

    return results, corrections, corrected_idx, flips


def summarize(label, results, corrections, corrected_idx, flips):
    wrong = 0
    lived = 0
    ue_ma = 0
    ma_x = 0
    pairs = defaultdict(int)
    for i, res in enumerate(results):
        if res is None:
            continue
        gt, pred = res
        if pred != gt:
            wrong += 1
            pairs[f"{gt}→{pred}"] += 1
            if i not in corrected_idx:
                lived += 1
            if gt == "上東" and pred == "松浦":
                ue_ma += 1
            if gt == "松浦":
                ma_x += 1
    top = sorted(pairs.items(), key=lambda x: -x[1])[:4]
    print(
        f"  {label}: corr={corrections} wrong={wrong} lived={lived} "
        f"上東→松浦={ue_ma} 松浦→X={ma_x} flips(good/bad)={flips['good']}/{flips['bad']}"
    )
    print(f"      top: {top}")


def main():
    centroids = load_roster_centroids()
    with open("/tmp/stickiness_baseline.json") as f:
        artifacts = json.load(f)

    for art in artifacts:
        rows = art["rows"]
        print(f"\n=== {art['session']} ===")
        res = run(rows, centroids, tau=0, delta=0, use_overlay=False)
        summarize("C1 drift only (reference)   ", *res)
        for tau in [0.70, 0.75, 0.80, 0.85, 0.90]:
            for delta in [0.0, 0.05]:
                res = run(rows, centroids, tau=tau, delta=delta)
                summarize(f"pair-overlay τ={tau:.2f} δ={delta:.2f}", *res)


if __name__ == "__main__":
    main()
