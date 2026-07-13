# Separability diagnostic — embedding 分離不能の犯人切り分け (2026-07-14)

## 背景

`docs/benchmarks/2026-07-09-calibration-ceiling/report.md` で、real-sessions
（Zoom 遠端音声の会議室録音、日本語 roster）に対するスコア層・プロファイル層の
精度工学 3 ルートすべての理論上限ゼロが確定した。ceiling は embedding 上流にある。
本診断はその「上流」を 3 候補に切り分ける:

- **(a) モデル限界**: FluidAudio の embedding がそもそもこの規模の話者集合を分離できない
- **(b) 音響条件**: Zoom 遠端 + 会議室録音という条件が embedding を潰している
- **(c) 窓混入**: production の 15s rolling window に他話者が混入し embedding が濁る

## 方法 — 統一プロトコル × 4 条件

全条件に同一の測定を適用する:

1. **GT 純粋スパン抽出**（`PureSpanExtractor`、pure logic・ユニットテスト付き）:
   話者ごとに gap ≤ 1.0s の隣接 GT セグメントをマージ → 他話者区間との重なりを
   除去 → 両端 0.25s trim → 5s 未満を破棄、15s 単位に分割（production window に整合）
2. **スパン embedding**: 各スパンの音声を独立に `OfflineDiarizerManager.process()`
   に与え、内部クラスタのうち合計 duration 最大のものの duration-weighted mean
   embedding を採用
3. **LOO 分析**（Python、2026-07-09 の `day_profile_sim.py` の一般化）:
   録音単位で、スパン数 ≥ 5 の話者を対象に leave-one-out day-centroid 識別。
   指標: LOO 識別精度 / own-cos median / best-impostor-cos median / margin 分布

| 条件 | データ | 音響 | 言語 |
|---|---|---|---|
| A | real-sessions 2 本（Zoom GT） | Zoom 遠端+会議室 | ja |
| B | AMI（≤ 8 会議、4 話者each） | 会議室マイク | en |
| C | callhome_ja（≤ 10 会話、2 話者each） | 電話 | ja |
| D | callhome_en（≤ 10 会話、2 話者each） | 電話 | en |

## 判定表

- **A 良好** → 犯人は (c) 窓混入。前回 LOO（混入あり 15s 窓 embedding）との差分が
  窓混入の寄与そのもの。windowing/セグメント単位 embedding 化が次の実装候補になる
- **A 悪 + B/C/D 良好** → 犯人は (b) Zoom 音響。キャプチャ経路・前処理の検討へ
- **B/C/D も悪い** → (a) モデル限界。embedding モデル変更の検討へ
- **C のみ悪い** → モデルの日本語話者での弱さ（(a) の変種）

roster サイズが条件間で異なる（2〜6）ため、条件間比較は margin 分布と
own/impostor cos を主とし、LOO 精度は録音内の参考値とする。

## 実装

- `Tests/QuickTranscriberBenchmarks/PureSpanExtractor.swift` — 抽出ロジック（TDD）
- `Tests/QuickTranscriberBenchmarks/PureSpanExtractorTests.swift` — モデル不要ユニットテスト
- `Tests/QuickTranscriberBenchmarks/SeparabilityBenchmarkTests.swift` — 条件別に
  スパン embedding を計算し `/tmp/separability_<dataset>.json` に書き出す
- `docs/benchmarks/2026-07-14-separability/separability_analysis.py` — LOO 分析
- `Package.swift` — ベンチターゲットに FluidAudio product を追加（テスト依存のみ）
- **production コード変更なし**（バージョン定数以外）

## 成功基準

4 条件の分離性サマリ（LOO 精度・own/impostor cos・margin）が揃い、判定表の
いずれかに帰着すること。結果は `docs/benchmarks/2026-07-14-separability/report.md`
にまとめ、handoff を更新する。

## Non-goals

- 修正の実装（windowing 改善・前処理・モデル変更はいずれも本診断の次の別 PR）
- DER 等の E2E diarization 指標（tracker/Viterbi が交絡するため使わない）
