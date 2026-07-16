#!/usr/bin/env python3
"""LOO separability analysis over span-embedding artifacts.

Input: /tmp/separability_<dataset>.json written by SeparabilityBenchmarkTests
(one file per condition; pass dataset names as argv, default: all four).

Per recording: speakers with >= MIN_SPANS spans participate. For each span e
of speaker s, identify against day-centroids (LOO for s, full for others):
    own    = cos(e, centroid of s's spans excluding e)
    imp    = max over other speakers t of cos(e, centroid_t)
    margin = own - imp        (> 0 == correctly identified)

Reported per dataset: span count, LOO accuracy, median own / impostor cos,
margin quartiles, negative-margin rate. Roster sizes differ across conditions
(2-6), so cross-condition comparison should lean on margins and cos levels,
not raw accuracy.
"""
import json
import math
import statistics
import sys

MIN_SPANS = 5


def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def centroid(embs):
    dim = len(embs[0])
    acc = [0.0] * dim
    for e in embs:
        for i, x in enumerate(e):
            acc[i] += x
    return [x / len(embs) for x in acc]


def analyze_recording(rec):
    by_speaker = {}
    for s in rec["spans"]:
        by_speaker.setdefault(s["speaker"], []).append(s["embedding"])
    eligible = {k: v for k, v in by_speaker.items() if len(v) >= MIN_SPANS}
    if len(eligible) < 2:
        return None

    full_centroids = {k: centroid(v) for k, v in eligible.items()}
    rows = []
    for spk, embs in eligible.items():
        for i, e in enumerate(embs):
            loo = centroid([x for j, x in enumerate(embs) if j != i])
            own = cos(e, loo)
            imp_name, imp = max(
                ((t, cos(e, c)) for t, c in full_centroids.items() if t != spk),
                key=lambda x: x[1],
            )
            rows.append({
                "recording": rec["recording"], "speaker": spk,
                "own": own, "imp": imp, "impName": imp_name,
                "margin": own - imp,
            })
    return {
        "recording": rec["recording"],
        "speakers": {k: len(v) for k, v in eligible.items()},
        "rows": rows,
    }


def quartiles(xs):
    q = statistics.quantiles(xs, n=4)
    return q[0], statistics.median(xs), q[2]


def main():
    datasets = sys.argv[1:] or ["real_sessions", "ami", "callhome_ja", "callhome_en"]
    for ds in datasets:
        path = f"/tmp/separability_{ds}.json"
        try:
            with open(path) as f:
                art = json.load(f)
        except FileNotFoundError:
            print(f"\n=== {ds}: artifact not found ({path}) — skipped ===")
            continue

        all_rows = []
        n_recordings = 0
        print(f"\n=== {ds} ===")
        for rec in art["recordings"]:
            result = analyze_recording(rec)
            if result is None:
                print(f"  {rec['recording']}: <2 eligible speakers — skipped")
                continue
            n_recordings += 1
            rows = result["rows"]
            all_rows.extend(rows)
            acc = sum(1 for r in rows if r["margin"] > 0) / len(rows)
            wrong_pairs = {}
            for r in rows:
                if r["margin"] <= 0:
                    key = f'{r["speaker"]}→{r["impName"]}'
                    wrong_pairs[key] = wrong_pairs.get(key, 0) + 1
            top = sorted(wrong_pairs.items(), key=lambda x: -x[1])[:3]
            print(
                f"  {result['recording']}: speakers={result['speakers']} "
                f"spans={len(rows)} LOO-acc={acc:.2%} wrong-top={top}"
            )

        if not all_rows:
            continue
        owns = [r["own"] for r in all_rows]
        imps = [r["imp"] for r in all_rows]
        margins = [r["margin"] for r in all_rows]
        acc = sum(1 for m in margins if m > 0) / len(margins)
        mq1, mmed, mq3 = quartiles(margins)
        print(f"  ---- {ds} summary ({n_recordings} recordings, {len(all_rows)} spans)")
        print(f"  LOO accuracy: {acc:.2%}")
        print(f"  own cos    median {statistics.median(owns):.3f}")
        print(f"  impostor   median {statistics.median(imps):.3f}")
        print(f"  margin     q1 {mq1:+.3f}  median {mmed:+.3f}  q3 {mq3:+.3f}  "
              f"negative {sum(1 for m in margins if m <= 0)}/{len(margins)}")


if __name__ == "__main__":
    main()
