#!/usr/bin/env python3
"""Oracle day-profile ceiling: could ANY better profile separate these voices?

For each session, build each roster speaker's "day centroid" from the GT
chunks of that same session (leave-one-out so a chunk never matches itself),
then identify every chunk against day centroids instead of stored centroids.

If day-profiles fix 04-21's 上東→松浦 block, the root cause is stale/broad
stored profiles and re-enrollment (Priority 2) has real headroom.
If they don't, the embedding space itself cannot separate these voices and
no profile/score engineering can — the ceiling is the embedding model.

Also reports the mixed setting (day-profile for the GT speaker of interest,
stored for others) and per-speaker own-voice cos to day vs stored centroid.
"""
import json
import math
import os
from collections import defaultdict

HOME = os.path.expanduser("~")
ROSTER = ["松浦", "今村", "上東", "森", "森谷", "神野"]


def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def vsum(acc, e):
    for i, x in enumerate(e):
        acc[i] += x
    return acc


def load_roster_centroids():
    with open(f"{HOME}/QuickTranscriber/speakers.json") as f:
        data = json.load(f)
    return {p["displayName"]: p["embedding"] for p in data if p["displayName"] in ROSTER}


def main():
    stored = load_roster_centroids()
    with open("/tmp/stickiness_baseline.json") as f:
        artifacts = json.load(f)

    for art in artifacts:
        rows = [r for r in art["rows"] if r.get("embedding")]
        print(f"\n=== {art['session']} (rows={len(rows)}) ===")

        # Group embeddings by GT speaker
        by_gt = defaultdict(list)
        for r in rows:
            by_gt[r["gt"]].append(r["embedding"])
        print("  GT chunk counts:", {k: len(v) for k, v in sorted(by_gt.items())})

        dim = len(rows[0]["embedding"])
        sums = {s: vsum([0.0] * dim, [0.0] * dim) for s in by_gt}
        sums = {}
        for s, embs in by_gt.items():
            acc = [0.0] * dim
            for e in embs:
                vsum(acc, e)
            sums[s] = acc

        def day_centroid(speaker, exclude=None):
            embs = by_gt[speaker]
            n = len(embs)
            if exclude is not None and n > 1:
                acc = [x - y for x, y in zip(sums[speaker], exclude)]
                return [x / (n - 1) for x in acc]
            return [x / n for x in sums[speaker]]

        # Own-voice cos: day vs stored centroid (median), per speaker
        print("  own-voice cos median (stored / day-LOO):")
        for s in sorted(by_gt):
            if s not in stored:
                continue
            cs = sorted(cos(e, stored[s]) for e in by_gt[s])
            cd = sorted(cos(e, day_centroid(s, exclude=e)) for e in by_gt[s])
            med = lambda xs: xs[len(xs) // 2] if xs else float("nan")
            print(f"    {s}: stored={med(cs):.3f}  day={med(cd):.3f}  (n={len(cs)})")

        # Identify with day-profiles (LOO), roster speakers only
        speakers = [s for s in by_gt if s in stored]

        def evaluate(profile_fn, label):
            wrong = 0
            pairs = defaultdict(int)
            for r in rows:
                e = r["embedding"]
                gt = r["gt"]
                scores = {}
                for s in speakers:
                    scores[s] = cos(e, profile_fn(s, e, gt))
                pred = max(scores, key=scores.get)
                if pred != gt:
                    wrong += 1
                    pairs[f"{gt}→{pred}"] += 1
            top = sorted(pairs.items(), key=lambda x: -x[1])[:5]
            print(f"  {label}: wrong={wrong}  top: {top}")

        evaluate(lambda s, e, gt: stored[s], "stored profiles (baseline)")
        evaluate(
            lambda s, e, gt: day_centroid(s, exclude=e if gt == s else None),
            "oracle day-profiles (LOO)  ",
        )


if __name__ == "__main__":
    main()
