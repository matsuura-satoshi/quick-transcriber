# Resume Point — 2026-07-09 (calibration ceiling 診断、精度改善 3 ルート無効化)

> **SUPERSEDED (2026-07-14)** by `2026-07-14-separability-verdict.md`:
> 上流切り分け診断が完了し、犯人は Zoom 遠端音響と確定（モデル健全）。
> See `docs/benchmarks/2026-07-14-separability/report.md`.

> 話者識別精度作業の再開用ハンドオフ。`2026-06-10-post-diagnostic.md` を supersede する。
> 全証拠: `docs/benchmarks/2026-07-09-calibration-ceiling/report.md`。

## One-line current state

**2026-06-10 handoff の優先度 1（per-profile score calibration）と優先度 2（re-enrollment）
の精度面の根拠は、オフライン計測により両方とも無効と確定**（PR #90）。この embedding
モデル + この音響条件（Zoom 遠端音声の会議録音）では当該話者群は分離不可能で、
ceiling を動かせるのは embedding 上流（モデル・窓・音響前処理）のみ。
既知の失敗テスト 1 件は期待見直し済みで **テストゲートは 803 件失敗ゼロ**。

## 計測で確定したこと（詳細はレポート）

1. **per-profile scalar calibration はクラスごと死んでいる** — 松浦だけを demote する
   oracle β 掃引でも動作点なし。攻撃 gap（0.146–0.304）と防御 margin（0.049–0.339）が
   交錯しており、減算・除算・z-norm いずれも 1 誤り直すと 1 つ以上壊す。
   handoff が提案していた静的バイアス（profile↔profile mean cos）は前提から誤り:
   attractor 松浦の bias は roster 中 2 番目に低い 0.626。
2. **session-overlay（修正 1 回でその日の声を登録 → max マッチ）も不成立** —
   ペア限定 + gate/margin 掃引込みで、04-21 は微改善+誤爆同数、04-23 は退行。
3. **oracle day-profile（LOO、re-enrollment の理論上限）でも総エラー減らず** —
   own-voice cos は劇的に上がる（上東 0.579→0.794）が impostor cos も同時に上がる。
   誤りは移動するだけ（04-21: 32→37, 04-23: 41→43）。

## 本 PR (#90) に含めたもの

- 診断レポート + シミュレーションスクリプト 4 本
  （`docs/benchmarks/2026-07-09-calibration-ceiling/`）
- replay の per-chunk embedding 記録（`ChunkDiagnostic.embedding` /
  `StickinessRow.embedding` — テストコードのみ、オフライン what-if の基盤）
- 既知の失敗テストの期待見直し:
  `testCorrection_trustedLearningReducesFutureMisidentification` →
  `testCorrection_ambiguousSampleIsGatedWithoutCentroidPollution`。
  旧期待「修正を重ねれば ambiguous も A と識別される」は v2.4.86 ゲーティングが
  意図的に閉じた centroid 融合経路そのものだった。新テストはゲート前提
  （cos < threshold）の明示 assert + centroid 非汚染 assert + typical A 保護。
- 2026-06-10 診断レポートへの前方参照追記

## 次セッションの選択肢（優先順は実機 FB 次第）

1. **v2.4.86 の実機体感 FB の確認が最優先** — poisoning 修正（revert 0/0）の
   lived 効果は未確認のまま。次の精度投資の判断材料はこれ。
2. **embedding 上流の切り分け診断**（唯一 ceiling を動かせる方向、工数大）:
   クリーン音源での同モデル話者分離コントロール実験で「モデル限界」vs
   「音響条件限界」を分離 → 窓長・前処理・モデル選択の検討へ。
3. **不確実性の表面化（UX）**: profile health 警告・低マージン表示。精度ではなく
   信頼の問題として設計する（Priority 2 の accuracy 根拠は死んだが UX 根拠は残る）。

## What NOT to do（2026-06-10 から更新）

- スコア層・プロファイル層の精度工学すべて: per-profile calibration（全変種）、
  session-overlay（全変種）、re-enrollment を精度目的で行うこと。
- 従来からの禁止事項は継続: smoother margin gate / findRelevantSegment windowing /
  speakerTransitionPenalty 追加調整 / Manual-mode within-session learning (config C)。

## Backlog（変更なし、レポート 2026-06-10 §F1–F6 参照）

F1 silence-reset 分離 / F2 pacer-cache 再供給 / F5 embedding_history.json 未書き込み /
F6 boundary-shadow / QT 出力タイムスタンプ / B2（VM↔Coordinator 状態二重所有、
`2026-07-08-pr-b3-complete.md` の B2 メモ参照）。

## Key files

| Concern | File |
|---|---|
| 今回の診断レポート（read first） | `docs/benchmarks/2026-07-09-calibration-ceiling/report.md` |
| シミュレーションスクリプト | 同ディレクトリの `*.py`（baseline 再生成手順はレポート §Method） |
| 前回診断（poisoning 修正の経緯） | `docs/benchmarks/2026-06-10-stickiness-diagnostic/report.md` |
| replay ハーネス | `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift` |
| 見直したテスト | `Tests/QuickTranscriberTests/ManualModeStabilityTests.swift` |

## Suggested first prompt for the next session

> 「コンテキストを引き継いで再開してください。状況は
> `docs/superpowers/handoffs/2026-07-09-calibration-dead-end.md` に書いてあります。
> v2.4.86 の実機体感フィードバックを確認した上で、embedding 上流の切り分け診断か
> 不確実性表面化（UX）のどちらに進むか判断してください。」
