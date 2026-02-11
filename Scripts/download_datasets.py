#!/usr/bin/env python3
"""Download and prepare speech recognition evaluation datasets.

Datasets:
  - FLEURS en_us + ja_jp (minimal, ~350 utterances each)
  - LibriSpeech test-other (standard, ~200 utterances subset)
  - ReazonSpeech test (standard, ~200 utterances subset)

Output: ~/Documents/MyTranscriber/test-audio/<dataset_name>/
  Each directory contains WAV files + references.json
"""

import json
import os
import random
import sys

def main():
    base_dir = os.path.expanduser("~/Documents/MyTranscriber/test-audio")
    os.makedirs(base_dir, exist_ok=True)

    tasks = [
        ("fleurs_en", download_fleurs_en),
        ("fleurs_ja", download_fleurs_ja),
        ("librispeech_test_other", download_librispeech_test_other),
        ("reazonspeech_test", download_reazonspeech_test),
    ]

    # Allow selecting specific datasets via command line
    if len(sys.argv) > 1:
        selected = sys.argv[1:]
        tasks = [(name, fn) for name, fn in tasks if name in selected]

    for name, fn in tasks:
        out_dir = os.path.join(base_dir, name)
        if os.path.exists(os.path.join(out_dir, "references.json")):
            print(f"[SKIP] {name} already exists at {out_dir}")
            continue
        print(f"\n{'='*60}")
        print(f"[DOWNLOAD] {name}")
        print(f"{'='*60}")
        try:
            fn(out_dir)
        except Exception as e:
            print(f"[ERROR] {name}: {e}")
            import traceback
            traceback.print_exc()


def save_audio_and_refs(samples, out_dir, lang, name_prefix=""):
    """Save audio samples as WAV files and create references.json."""
    import soundfile as sf
    os.makedirs(out_dir, exist_ok=True)
    references = {}

    for i, sample in enumerate(samples):
        audio = sample["audio"]
        text = sample["text"].strip()
        if not text:
            continue

        fname = f"{name_prefix}{i:04d}"
        wav_path = os.path.join(out_dir, f"{fname}.wav")

        # audio dict has 'array' and 'sampling_rate'
        sf.write(wav_path, audio["array"], audio["sampling_rate"])

        duration = len(audio["array"]) / audio["sampling_rate"]
        references[fname] = {
            "language": lang,
            "text": text,
            "duration_seconds": round(duration, 2),
        }

    refs_path = os.path.join(out_dir, "references.json")
    with open(refs_path, "w", encoding="utf-8") as f:
        json.dump(references, f, ensure_ascii=False, indent=2)

    total_dur = sum(r["duration_seconds"] for r in references.values())
    print(f"  Saved {len(references)} files, total {total_dur:.1f}s ({total_dur/60:.1f}min)")
    print(f"  Output: {out_dir}")


def download_fleurs_en(out_dir):
    """FLEURS English test set (~350 utterances)."""
    from datasets import load_dataset
    print("  Loading FLEURS en_us test split...")
    ds = load_dataset("google/fleurs", "en_us", split="test", trust_remote_code=True)
    print(f"  Loaded {len(ds)} samples")

    samples = []
    for item in ds:
        sample = dict(item)
        if "transcription" in sample and "text" not in sample:
            sample["text"] = sample["transcription"]
        samples.append(sample)
    save_audio_and_refs(samples, out_dir, "en", "en_")


def download_fleurs_ja(out_dir):
    """FLEURS Japanese test set (~350 utterances)."""
    from datasets import load_dataset
    print("  Loading FLEURS ja_jp test split...")
    ds = load_dataset("google/fleurs", "ja_jp", split="test", trust_remote_code=True)
    print(f"  Loaded {len(ds)} samples")

    # Use all (small enough)
    # Map 'transcription' to 'text' if needed
    samples = []
    for item in ds:
        sample = dict(item)
        if "transcription" in sample and "text" not in sample:
            sample["text"] = sample["transcription"]
        samples.append(sample)
    save_audio_and_refs(samples, out_dir, "ja", "ja_")


def download_librispeech_test_other(out_dir):
    """LibriSpeech test-other subset (~200 utterances)."""
    from datasets import load_dataset
    print("  Loading LibriSpeech test-other split...")
    ds = load_dataset("openslr/librispeech_asr", "other", split="test")
    print(f"  Loaded {len(ds)} samples")

    # Random subset of 200
    random.seed(42)
    indices = random.sample(range(len(ds)), min(200, len(ds)))
    samples = [ds[i] for i in sorted(indices)]
    save_audio_and_refs(samples, out_dir, "en", "en_")


def download_reazonspeech_test(out_dir):
    """ReazonSpeech test subset (~200 utterances)."""
    from datasets import load_dataset
    print("  Loading ReazonSpeech test split...")
    ds = load_dataset("japanese-asr/ja_asr.reazonspeech_test", split="test",
                       trust_remote_code=True)
    print(f"  Loaded {len(ds)} samples")

    # Map field names: ReazonSpeech uses 'transcription' not 'text'
    # Random subset of 200
    random.seed(42)
    indices = random.sample(range(len(ds)), min(200, len(ds)))
    samples = []
    for i in sorted(indices):
        item = dict(ds[i])
        if "transcription" in item and "text" not in item:
            item["text"] = item["transcription"]
        samples.append(item)
    save_audio_and_refs(samples, out_dir, "ja", "ja_")


if __name__ == "__main__":
    main()
