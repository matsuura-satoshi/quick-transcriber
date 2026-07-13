#!/usr/bin/env python3
"""Offline simulation of per-profile score calibration candidates.

Manual mode (suppressLearning=true) keeps centroids frozen, so the recorded
per-chunk cosines in stickiness_baseline.json are exact — we can re-run the
argmax with any calibration formula without replaying audio.

Caveat: this evaluates the RAW layer only (argmax over calibrated scores vs
ground truth). Viterbi/pending dynamics are not simulated, but rawWrongFresh
dominates the error split (42/51), so raw-level deltas are a valid proxy for
candidate selection. Final validation must use the Swift replay.

Candidates:
  A0  baseline (no calibration)              score_i = cos_i
  A1  static bias (handoff's cheap AS-norm)  score_i = cos_i - lam * b_i,
      b_i = mean_{j!=i} cos(centroid_i, centroid_j)
  A2  online session bias                    score_i = cos_i - lam * m_i(t),
      m_i(t) = running mean of cos_i over previous chunks (causal),
      warm-up: bias inactive until n >= N_MIN chunks observed
"""
import json
import math
import os
from collections import defaultdict

HOME = os.path.expanduser("~")
ROSTER = ["松浦", "今村", "上東", "森", "森谷", "神野"]
N_MIN = 10  # A2 warm-up chunks before bias activates


def load_static_bias():
    with open(f"{HOME}/QuickTranscriber/speakers.json") as f:
        data = json.load(f)
    profs = {p["displayName"]: p["embedding"] for p in data if p["displayName"] in ROSTER}

    def cos(a, b):
        dot = sum(x * y for x, y in zip(a, b))
        return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(x * x for x in b)))

    bias = {}
    for a in ROSTER:
        others = [cos(profs[a], profs[b]) for b in ROSTER if b != a]
        bias[a] = sum(others) / len(others)
    return bias


def evaluate(rows, score_fn):
    """score_fn(row_index, cosines) -> dict name->score. Returns error stats."""
    wrong = 0
    pair_counts = defaultdict(int)
    for i, r in enumerate(rows):
        if not r["cosines"]:
            continue
        scores = score_fn(i, r["cosines"])
        pred = max(scores, key=scores.get)
        if pred != r["gt"]:
            wrong += 1
            pair_counts[f'{r["gt"]}→{pred}'] += 1
    return wrong, dict(pair_counts)


def main():
    static_bias = load_static_bias()
    with open("/tmp/stickiness_baseline.json") as f:
        artifacts = json.load(f)

    for art in artifacts:
        session = art["session"]
        rows = [r for r in art["rows"]]  # already time-sorted
        n_scored = sum(1 for r in rows if r["cosines"])
        print(f"\n=== {session} (attributed rows={len(rows)}, with cosines={n_scored}) ===")

        # A0 baseline
        base_wrong, base_pairs = evaluate(rows, lambda i, c: dict(c))
        print(f"A0 baseline: raw-wrong={base_wrong}")
        for p, n in sorted(base_pairs.items(), key=lambda x: -x[1]):
            print(f"    {p}: {n}")

        # A1 static bias, lambda sweep
        for lam in [0.25, 0.5, 0.75, 1.0]:
            w, pairs = evaluate(
                rows, lambda i, c, lam=lam: {k: v - lam * static_bias.get(k, 0.0) for k, v in c.items()}
            )
            top = sorted(pairs.items(), key=lambda x: -x[1])[:4]
            print(f"A1 lam={lam}: raw-wrong={w}  top: {top}")

        # A2 online bias (causal running mean), lambda sweep
        for lam in [0.25, 0.5, 0.75, 1.0]:
            sums = defaultdict(float)
            counts = defaultdict(int)
            state = {"sums": sums, "counts": counts}

            def score(i, c, lam=lam, state=state):
                s = {}
                for k, v in c.items():
                    n = state["counts"][k]
                    m = state["sums"][k] / n if n >= N_MIN else None
                    s[k] = v - lam * m if m is not None else v
                # update AFTER scoring (causal)
                for k, v in c.items():
                    state["sums"][k] += v
                    state["counts"][k] += 1
                return s

            w, pairs = evaluate(rows, score)
            top = sorted(pairs.items(), key=lambda x: -x[1])[:4]
            print(f"A2 lam={lam}: raw-wrong={w}  top: {top}")


if __name__ == "__main__":
    main()
