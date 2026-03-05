# Viterbi状態リセット on ユーザー修正

## 問題
ユーザーが話者ラベルを修正しても、`ViterbiSpeakerSmoother` の内部状態（`stateLogProb`、`confirmed`）が旧話者のまま。次のセグメントで旧話者が再度選ばれてしまい、何度も修正が必要になる。

## 解決策
`correctSpeakerAssignment` の呼び出し時に、`ViterbiSpeakerSmoother` の状態を修正先話者にリセットする。

## 変更箇所

### 1. `ViterbiSpeakerSmoother` に `confirmSpeaker` メソッド追加
- `stateLogProb` を修正先話者に有利にリセット（他話者は -100.0）
- `confirmed` を修正先話者にセット
- `pending` 状態をクリア

### 2. `ChunkedWhisperEngine.correctSpeakerAssignment` に Viterbi リセット追加
- 既存の `diarizer?.correctSpeakerAssignment` の後に `speakerSmoother.confirmSpeaker(newId)` を呼ぶ

## 動作フロー
1. ユーザーが Speaker-1 → Speaker-2 に修正
2. embedding が Speaker-2 のプロファイルに移動（既存動作）
3. Viterbi が Speaker-2 を現在の確定話者としてリセット
4. 以降のセグメントは `stayProbability=0.8` で Speaker-2 に留まる傾向
5. 本当に別の話者が来たら、embedding 的に高確信度 + 2連続検出で自然に切り替わる
6. 固定期間中に Speaker-2 の embedding が蓄積され、重心が収束

## アプローチ選定理由
- 変更箇所が最小（メソッド1つ追加 + 呼び出し1行追加）
- 既存の Viterbi メカニズム（stayProbability、2連続検出）をそのまま活用
- 新しいパラメータやカウンタが不要
- 本質的に「ユーザーが修正した = 今の話者はこの人」という情報を Viterbi に正しく伝えるだけ
