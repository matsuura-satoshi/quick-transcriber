#!/usr/bin/env python3
"""Oracle session-overlay simulation (offline, raw-level proxy).

Replays the persistence-2 correction model over recorded per-chunk embeddings
(stickiness_baseline.json with `embedding` populated) and compares:

  C0  no corrections (baseline)
  C1  current v2.4.86 behavior: correction does a gated append
      (cos >= 0.5 vs target centroid) into the target history
      (seed weight 10) -> centroid drifts gradually
  C2  C1 + session overlay: the corrected chunk's embedding is ALSO kept as a
      session-scoped sample for the target; identify scores
      score_i = max(cos(e, centroid_i), max_s cos(e, overlay_i))
  C3  overlay only (no centroid drift)

Correction model (mirrors the Swift persistence-2 oracle, but at the raw
layer — no Viterbi): a correction fires on the 2nd consecutive chunk with the
same (gt -> pred) error; the corrected chunk's embedding is the sample.

Metrics per session/config: corrections fired, system-wrong (raw argmax vs
GT), lived-wrong (system-wrong minus corrected chunks), 上東→松浦, 松浦→X,
plus overlay-induced errors (chunks that became wrong vs C1).
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
    """Mirrors EmbeddingBasedSpeakerTracker centroid math (weighted mean,
    stored centroid seeded at weight 10)."""

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
        """v2.4.86 Manual-mode correction: append at confidence 1.0 only when
        cos >= threshold vs current centroid. Returns True if appended."""
        if cos(embedding, self.centroid) >= SIM_THRESHOLD:
            self.entries.append((embedding, 1.0))
            self._recalc()
            return True
        return False


def run(rows, centroids, use_drift, use_overlay):
    profiles = {n: Profile(c) for n, c in centroids.items()}
    overlays = defaultdict(list)  # name -> [embedding]
    consecutive = None  # (gt, pred, count)
    corrections = 0
    appended = 0
    corrected_idx = set()
    results = []  # (gt, pred, used_overlay)

    for idx, r in enumerate(rows):
        e = r.get("embedding")
        if not e:
            results.append(None)
            continue
        gt = r["gt"]

        scores = {}
        overlay_won = {}
        for name, prof in profiles.items():
            s = cos(e, prof.centroid)
            o = max((cos(e, ov) for ov in overlays[name]), default=-1.0) if use_overlay else -1.0
            scores[name] = max(s, o)
            overlay_won[name] = o > s
        pred = max(scores, key=scores.get)
        results.append((gt, pred, overlay_won[pred]))

        # persistence-2 correction model
        if pred != gt:
            if consecutive and consecutive[0] == gt and consecutive[1] == pred:
                consecutive = (gt, pred, consecutive[2] + 1)
            else:
                consecutive = (gt, pred, 1)
            if consecutive[2] >= 2 and gt in profiles:
                consecutive = None
                corrections += 1
                corrected_idx.add(idx)
                if use_drift and profiles[gt].gated_append(e):
                    appended += 1
                if use_overlay:
                    overlays[gt].append(e)
        else:
            consecutive = None

    return results, corrections, appended, corrected_idx


def summarize(name, results, corrections, appended, corrected_idx, ref_results=None):
    wrong = 0
    lived = 0
    ue_ma = 0
    ma_x = 0
    overlay_wins_correct = 0
    overlay_wins_wrong = 0
    newly_wrong = 0
    pairs = defaultdict(int)
    for i, res in enumerate(results):
        if res is None:
            continue
        gt, pred, via_overlay = res
        if pred != gt:
            wrong += 1
            pairs[f"{gt}→{pred}"] += 1
            if i not in corrected_idx:
                lived += 1
            if gt == "上東" and pred == "松浦":
                ue_ma += 1
            if gt == "松浦":
                ma_x += 1
            if via_overlay:
                overlay_wins_wrong += 1
            if ref_results and ref_results[i] and ref_results[i][1] == ref_results[i][0]:
                newly_wrong += 1
        else:
            if via_overlay:
                overlay_wins_correct += 1
    top = sorted(pairs.items(), key=lambda x: -x[1])[:4]
    extra = f" overlayWins(correct/wrong)={overlay_wins_correct}/{overlay_wins_wrong}"
    if ref_results:
        extra += f" newlyWrongVsRef={newly_wrong}"
    print(
        f"  {name}: corrections={corrections} appended={appended} "
        f"system-wrong={wrong} lived-wrong={lived} 上東→松浦={ue_ma} 松浦→X={ma_x}{extra}"
    )
    print(f"      top pairs: {top}")
    return results


def main():
    centroids = load_roster_centroids()
    with open("/tmp/stickiness_baseline.json") as f:
        artifacts = json.load(f)

    for art in artifacts:
        rows = art["rows"]
        n_emb = sum(1 for r in rows if r.get("embedding"))
        print(f"\n=== {art['session']} (rows={len(rows)}, with embedding={n_emb}) ===")

        # sanity: recomputed cos vs recorded cosines on first row with embedding
        for r in rows:
            if r.get("embedding") and r["cosines"]:
                for name, recorded in list(r["cosines"].items())[:3]:
                    calc = cos(r["embedding"], centroids[name])
                    assert abs(calc - recorded) < 0.02, f"cos mismatch {name}: {calc} vs {recorded}"
                break

        r0 = run(rows, centroids, use_drift=False, use_overlay=False)
        summarize("C0 baseline (no corrections)", *r0)
        r1 = run(rows, centroids, use_drift=True, use_overlay=False)
        summarize("C1 current gated-append drift ", *r1)
        r2 = run(rows, centroids, use_drift=True, use_overlay=True)
        summarize("C2 drift + session overlay    ", *r2, ref_results=r1[0])
        r3 = run(rows, centroids, use_drift=False, use_overlay=True)
        summarize("C3 overlay only               ", *r3, ref_results=r1[0])


if __name__ == "__main__":
    main()
