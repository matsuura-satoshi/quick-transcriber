#!/usr/bin/env python3
"""Render confusion-pair JSON artifacts into a markdown report.

Inputs (written by ConfusionPairAnalysisTests):
  /tmp/confusion_roster_similarity.json   (Part A)
  /tmp/confusion_sessions.json            (Part B)

Usage:
  python3 Scripts/analyze_confusion_pairs.py [roster.json] [sessions.json] > report.md
"""
import json, sys

roster_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/confusion_roster_similarity.json"
sessions_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/confusion_sessions.json"

def render_roster(path):
    d = json.load(open(path))
    sp = d["speakers"]; m = d["matrix"]
    print("## Part A — Registered-roster pairwise cosine similarity\n")
    print("| | " + " | ".join(sp) + " |")
    print("|" + "---|" * (len(sp) + 1))
    for i, name in enumerate(sp):
        cells = " | ".join(f"{m[i][j]:.3f}" for j in range(len(sp)))
        print(f"| **{name}** | {cells} |")
    print("\n**Top pairs:**\n")
    for p in d["topPairs"][:8]:
        print(f"- {p['a']} ↔ {p['b']}: {p['similarity']:.3f}")
    print()

def render_sessions(path):
    arts = json.load(open(path))
    print("## Part B — Real-session confusion matrices\n")
    for a in arts:
        mx = a["matrix"]; sp = mx["speakers"]
        print(f"### {a['session']}")
        print(f"Registered: {', '.join(a['registered'])} · "
              f"chunks={a['chunkCount']} · attributed={a['attributedCount']} · "
              f"**false-神野={mx['totalFalseTarget']}**\n")
        print("GT＼Pred | " + " | ".join(sp) + " |")
        print("|" + "---|" * (len(sp) + 1))
        counts = mx["counts"]
        for gt in sp:
            row = counts.get(gt, {})
            cells = " | ".join(str(row.get(pred, 0)) for pred in sp)
            print(f"| **{gt}** | {cells} |")
        if mx["falseTargetByGroundTruth"]:
            print("\n**神野 ⟵ (which GT speaker got mislabeled as 神野):**\n")
            for gt, n in sorted(mx["falseTargetByGroundTruth"].items(), key=lambda x: -x[1]):
                print(f"- {gt}: {n}")
        print()

print("# Confusion Pair Analysis Report\n")
render_roster(roster_path)
render_sessions(sessions_path)
