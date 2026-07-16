# Resume Point — 2026-07-14 (separability 診断、犯人は Zoom 遠端音響と確定)

> 話者識別精度作業の再開用ハンドオフ。`2026-07-09-calibration-dead-end.md` を supersede する。
> 全証拠: `docs/benchmarks/2026-07-14-separability/report.md`。

## One-line current state

**分離不能の犯人は Zoom 遠端音声の音響経路（コーデック → スピーカー再生 → 部屋残響 →
マイク再録音）と確定**（PR #91）。同じモデルが AMI 会議室 4 話者を LOO 99.4 %
（margin +0.527）で分離する一方、real-sessions は GT 純粋スパンでも 70.7 %
（margin +0.100）— モデル限界説・窓混入説は棄却。v2.4.86 の実機体感は
「直しても戻るは改善」とユーザー確認済み。

## 診断結果（4 条件、統一 LOO プロトコル）

| 条件 | LOO acc | margin med | 判定への寄与 |
|---|---|---|---|
| real-sessions（Zoom+会議室, ja） | 70.7 % | +0.100 | 問題の条件 |
| AMI（会議室マイク, en, 4 話者） | 99.4 % | +0.527 | モデル健全の証明 |
| callhome_ja（電話, ja） | 86.0 % | +0.194 | 劣化チャネル×日本語の勾配（副次） |
| callhome_en（電話, en） | 92.0 % | +0.323 | 同上の言語対照 |

- 窓混入（15s window への他話者混入）は副次要因: 除去で約 10 pt 回復するが
  AMI との差 ~29 pt は音響。リモート話者の声が「部屋+スピーカーの共有伝達関数」で
  互いに似る構図（現地マイク直の松浦だけ own cos が高い、とも整合）
- 判定の含意: **モデル変更は無意味**（どのモデルも融合済みの入力を受ける）。
  音響前処理（dereverb 等）は弱い fallback（コーデック損失と話者間で共有された
  スピーカー音色は戻せない）

## 次の一手（優先順）

1. **システムオーディオ直接キャプチャの brainstorming から**: Zoom 遠端音声を
   スピーカー再録音ではなく loopback（ScreenCaptureKit 等）でデジタルに取る。
   共有伝達関数が消え、副産物として「マイク=現地 / loopback=リモート」という
   強力な話者分離信号も得られる。production 機能の設計になるため
   `superpowers:brainstorming` から（キャプチャ権限、ミキシング、既存
   AudioCaptureService との関係、会議アプリ非依存性が論点）
2. 代替/並行: 不確実性の表面化 UX（低 margin 表示・profile health）— 音響改修より
   小さく、キャプチャ改修が届かない会議形態の保険
3. 検証資産: 次の実会議で「QT 録音 + loopback 録音」を同時取得できれば、
   キャプチャ改修の効果を実装前に separability プロトコルで事前計測できる

## 本 PR (#91) に含めたもの

- `PureSpanExtractor` + ユニットテスト 9 件（TDD、モデル不要）
- `SeparabilityBenchmarkTests`（4 条件の span embedding 抽出 →
  `/tmp/separability_<dataset>.json`）
- `separability_analysis.py`（LOO 分析）+ レポート
- Package.swift: ベンチターゲットに FluidAudio 直接依存を追加（テストのみ）
- spec: `docs/superpowers/specs/2026-07-14-separability-diagnostic-design.md`

## What NOT to do（累積、2026-07-09 から更新）

- スコア層・プロファイル層の精度工学（per-profile calibration / session-overlay /
  精度目的の re-enrollment）— 2026-07-09 に理論上限ゼロ確定
- **embedding モデルの乗り換え検討** — 本診断で無意味と確定（入力が融合済み）
- 従来からの禁止事項: smoother margin gate / findRelevantSegment windowing /
  speakerTransitionPenalty 追加調整 / Manual-mode within-session learning

## Backlog（変更なし）

F1 silence-reset 分離 / F2 pacer-cache 再供給 / F5 embedding_history.json 未書き込み /
F6 boundary-shadow / QT 出力タイムスタンプ / B2 状態二重所有（2026-07-08 handoff 参照）

## Key files

| Concern | File |
|---|---|
| 今回の診断レポート（read first） | `docs/benchmarks/2026-07-14-separability/report.md` |
| 診断 spec | `docs/superpowers/specs/2026-07-14-separability-diagnostic-design.md` |
| スパン抽出 + ベンチ | `Tests/QuickTranscriberBenchmarks/PureSpanExtractor.swift`, `SeparabilityBenchmarkTests.swift` |
| 前回診断（スコア層の理論上限ゼロ） | `docs/benchmarks/2026-07-09-calibration-ceiling/report.md` |
| 現行の音声キャプチャ | `Sources/QuickTranscriber/Services/AudioCaptureService.swift` |

## Suggested first prompt for the next session

> 「コンテキストを引き継いで再開してください。状況は
> `docs/superpowers/handoffs/2026-07-14-separability-verdict.md` に書いてあります。
> システムオーディオ直接キャプチャ（loopback）による Zoom 遠端音声のデジタル取得を
> brainstorming から設計してください。」
