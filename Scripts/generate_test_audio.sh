#!/bin/bash
# Generate test audio fixtures using macOS say command
# Usage: ./Scripts/generate_test_audio.sh

set -euo pipefail

OUTPUT_DIR="Tests/MyTranscriberBenchmarks/Resources"
mkdir -p "$OUTPUT_DIR"

echo "Generating test audio fixtures..."

# English short (~3 seconds)
say -v Samantha -o "$OUTPUT_DIR/en_short.wav" --data-format=LEI16@16000 \
    "The quick brown fox jumps over the lazy dog."

# English medium (~15 seconds)
say -v Samantha -o "$OUTPUT_DIR/en_medium.wav" --data-format=LEI16@16000 \
    "Artificial intelligence has transformed the way we interact with technology. From voice assistants to autonomous vehicles, machine learning models are becoming increasingly sophisticated. Natural language processing allows computers to understand and generate human speech with remarkable accuracy."

# English with pauses (~10 seconds)
say -v Samantha -r 160 -o "$OUTPUT_DIR/en_pauses.wav" --data-format=LEI16@16000 \
    "Good morning everyone. [[slnc 1000]] Today we will discuss the latest developments in technology. [[slnc 500]] First, let us review the quarterly results. [[slnc 500]] Revenue increased by fifteen percent."

# Japanese short (~3 seconds)
say -v Kyoko -o "$OUTPUT_DIR/ja_short.wav" --data-format=LEI16@16000 \
    "本日のニュースをお伝えします。"

# Japanese medium (~15 seconds)
say -v Kyoko -o "$OUTPUT_DIR/ja_medium.wav" --data-format=LEI16@16000 \
    "人工知能の技術は近年急速に発展しています。音声認識の分野では、深層学習モデルの進化により、人間に近い精度で音声をテキストに変換できるようになりました。今後もさらなる技術革新が期待されています。"

echo "Generating references.json..."

cat > "$OUTPUT_DIR/references.json" << 'REFS'
{
  "en_short": {
    "language": "en",
    "text": "The quick brown fox jumps over the lazy dog.",
    "duration_seconds": 3.0
  },
  "en_medium": {
    "language": "en",
    "text": "Artificial intelligence has transformed the way we interact with technology. From voice assistants to autonomous vehicles, machine learning models are becoming increasingly sophisticated. Natural language processing allows computers to understand and generate human speech with remarkable accuracy.",
    "duration_seconds": 15.0
  },
  "en_pauses": {
    "language": "en",
    "text": "Good morning everyone. Today we will discuss the latest developments in technology. First, let us review the quarterly results. Revenue increased by fifteen percent.",
    "duration_seconds": 10.0
  },
  "ja_short": {
    "language": "ja",
    "text": "本日のニュースをお伝えします。",
    "duration_seconds": 3.0
  },
  "ja_medium": {
    "language": "ja",
    "text": "人工知能の技術は近年急速に発展しています。音声認識の分野では、深層学習モデルの進化により、人間に近い精度で音声をテキストに変換できるようになりました。今後もさらなる技術革新が期待されています。",
    "duration_seconds": 15.0
  }
}
REFS

echo "Done! Generated files:"
ls -la "$OUTPUT_DIR"
