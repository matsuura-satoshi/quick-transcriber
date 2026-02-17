# Phase C-1: Confidence Score Propagation Design

## Goal

Propagate cosine similarity score from `EmbeddingBasedSpeakerTracker.identify()` through the entire pipeline to `TranscriptionTextView`, enabling visual confidence indication for speaker labels.

## Design Decisions

- **UI表示**: 話者ラベルの色分け（2段階）
  - confidence ≥ 0.5 → 通常色（`.labelColor`）
  - confidence < 0.5 → グレー（`.secondaryLabelColor`）
  - 色分け対象は話者ラベル部分（「A:」）のみ。テキスト本文は常に通常色
- **ファイル出力**: 変更なし（プレーンテキスト維持）
- **閾値**: similarityThreshold（0.5）と同値。これ以下は強制割当のため低信頼

## Architecture

```
EmbeddingBasedSpeakerTracker.identify(embedding:)
  → SpeakerIdentification(label, confidence)
      ↓
FluidAudioSpeakerDiarizer.identifySpeaker()
  → SpeakerIdentification?
      ↓
SpeakerLabelTracker.processLabel()
  → SpeakerIdentification?
      ↓
ConfirmedSegment(text, precedingSilence, speaker, speakerConfidence)
      ↓
TranscriptionTextView (色分け表示)
```

## Component Changes

### 1. SpeakerIdentification (new)

```swift
public struct SpeakerIdentification: Sendable, Equatable {
    public let label: String
    public let confidence: Float  // cosine similarity [0.0, 1.0]
}
```

### 2. EmbeddingBasedSpeakerTracker.identify()

- Return type: `String` → `SpeakerIdentification`
- New speaker registration: confidence = 1.0
- Existing match: confidence = bestSimilarity
- Forced assignment (expectedSpeakerCount reached): confidence = bestSimilarity

### 3. SpeakerDiarizer protocol

- `identifySpeaker()` return type: `String?` → `SpeakerIdentification?`

### 4. SpeakerLabelTracker.processLabel()

- Parameter type: `String?` → `SpeakerIdentification?`
- On confirmation: pass through latest confidence
- On pending (nil return): unchanged

### 5. ConfirmedSegment

- Add `speakerConfidence: Float?` field

### 6. TranscriptionTextView

- Receive `[ConfirmedSegment]` array instead of pre-formatted string
- Build NSAttributedString with per-label color based on confidence
- Speaker label color: confidence < 0.5 → `.secondaryLabelColor`, else `.labelColor`

### 7. File output

- No changes
