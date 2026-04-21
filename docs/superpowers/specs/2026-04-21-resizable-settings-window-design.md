# Resizable Settings Window & Zebra-Striped Speaker Lists

**Date:** 2026-04-21
**Status:** Design approved, pending implementation plan

## Motivation

会議中、特に参加者が多い会議で `cmd+,` の設定ウインドウの Speakers タブを頻繁に開閉して Active Speakers と Registered Speakers の間を往復する。現状の設定ウインドウはサイズが固定（幅 520pt、高さ実質固定）で、上下のスクロールが増えて視認性・操作性が悪い。横方向にも広げて一度に多くの情報を見たい。

また、ウインドウを広げると視線は左側（名前・バッジ）、クリックは右端（削除ボタン・トグル）となるため、行の対応を追いやすいよう縞模様背景で視認性を上げる。

## Goals

1. 設定ウインドウを **縦方向・横方向の両方向にリサイズ可能** にする
2. ユーザーがリサイズしたサイズを **アプリ再起動後も記憶** する
3. Active Speakers / Registered Speakers の両リストに **縞模様背景**（奇数=現状、偶数=少し濃い色）を適用する

## Non-Goals

- タブ別にサイズを記憶する（単一の共有サイズでよい）
- 横幅の上限・下限を厳密にチューニングする（最小 520pt を維持、上限なし）
- 他ビュー（メインウインドウ、About 等）のリサイズ挙動変更
- 縞模様の色のダークモード別最適化（`Color.primary.opacity(_:)` により自動対応）

## Design

### 1. リサイズ可能化

#### `SettingsView` の frame 制約変更

`Sources/QuickTranscriber/Views/SettingsView.swift`:

変更前:
```swift
.frame(minWidth: 520, maxWidth: 520, minHeight: 500, maxHeight: 5000)
```

変更後:
```swift
.frame(minWidth: 520, minHeight: 500)
```

`maxWidth` と `maxHeight` を外し、最小サイズのみ制約。

#### Settings シーンにリサイズ許可を付与

`Sources/QuickTranscriberApp/QuickTranscriberApp.swift`:

```swift
Settings {
    SettingsView(viewModel: viewModel)
}
.windowResizability(.contentSize)
```

`.windowResizability(.contentSize)` により、Settings ウインドウは `SettingsView` の `.frame` 制約に従いユーザーがドラッグでリサイズ可能になる（macOS 13+ API、本プロジェクトは macOS 15）。

### 2. サイズ記憶

macOS 標準の `NSWindow.setFrameAutosaveName(_:)` を使う。これは `com.apple.NSWindow Frame <name>` キーで `UserDefaults` にサイズ・位置を自動保存・復元する仕組み。

実装:
- `SettingsView` 内に `WindowAccessor` という軽量 `NSViewRepresentable` を置く
- `makeNSView` 内で `DispatchQueue.main.async` を用いて親ウインドウを取得
- 取得したウインドウに `setFrameAutosaveName("QuickTranscriberSettings")` を設定

```swift
private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("QuickTranscriberSettings")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

`SettingsView.body` の末尾に `.background(SettingsWindowAccessor())` を付与。

**注意点:**
- `setFrameAutosaveName` は同名が他ウインドウで使われていると `false` を返して失敗するが、本アプリで Settings は単一なので問題なし
- 初回起動時（保存データなし）は `.frame` の最小値＋コンテンツの自然サイズで開く
- 保存されるのは **位置とサイズ両方**。ユーザーの期待通り

### 3. 縞模様背景

#### 対象
- `activeSpeakersSection` 内の `ForEach(viewModel.activeSpeakers)`
- `registeredSpeakersSection` 内の `ForEach(filteredProfiles)`

#### 配色
- 奇数行（index 0, 2, 4, ... = 1 番目, 3 番目, ...）: 背景なし（現状維持）
- 偶数行（index 1, 3, 5, ... = 2 番目, 4 番目, ...）: `Color.primary.opacity(0.04)`

`Color.primary` を使うことで Light/Dark モードどちらでも破綻しない。opacity は初期値 0.04 で実装し、実機確認後に 0.04–0.08 の範囲で微調整する余地を残す。

#### 実装

インデックス付き `ForEach` に変換し、条件付き背景を適用する:

```swift
ForEach(Array(viewModel.activeSpeakers.enumerated()), id: \.element.id) { index, speaker in
    ActiveSpeakerRow(...)
        .listRowBackground(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
        // もしくは .background(...) — Form/Section 構成に合わせる
}
```

Form（`.grouped`）配下では `.listRowBackground` が期待通り動かないケースがあるため、実装時は両方試して `.background()` を当該行全体に当てる形にフォールバックする。具体的には:

```swift
.background(
    index.isMultiple(of: 2)
        ? Color.clear
        : Color.primary.opacity(0.04)
)
```

Registered Speakers の `DisclosureGroup` は、ラベル＋展開内容のコンテナ全体に背景を適用する（ラベルだけでなく内部の展開ビューも同色に）。これは `DisclosureGroup { ... } label: { ... }` を `VStack` で包み、外側に `.background` を掛けることで実現する。

### 4. データフロー / 既存コンポーネントへの影響

- 既存 `ActiveSpeakerRow` / `SpeakerProfileSummaryView` / `SpeakerProfileDetailView` の内部は **無変更**
- 呼び出し側（`ForEach` ブロック）のみ編集
- `ParametersStore` / `TranscriptionViewModel` への影響なし
- Speaker state mutation 周りにも影響なし（表示のみの変更）

## Testing

- **ユニットテスト**: 表示のみの変更のため既存のテストが壊れないことを確認（`swift test --filter QuickTranscriberTests`）
- **手動 UI テスト**:
  1. `swift run QuickTranscriber` → `cmd+,`
  2. 設定ウインドウを縦横両方向にドラッグしてリサイズできることを確認
  3. 一度閉じて再度開き、サイズ・位置が保持されていることを確認
  4. アプリを終了→再起動し、再度開いてもサイズ・位置が保持されていることを確認
  5. Speakers タブで Active / Registered の両リストに縞模様が出ていることを確認（奇数行素地、偶数行薄グレー）
  6. Light / Dark モード切替で縞模様が両方自然に見えることを確認
  7. Registered の DisclosureGroup 展開時、展開内容の背景色が行の背景色と一致していることを確認

## Risks & Alternatives

- **リスク: `.windowResizability(.contentSize)` が Settings シーンで期待通り動かない可能性**
  - 緩和策: macOS 15 で動作確認済みの API。万一効かない場合は `.automatic` にしたうえで `WindowAccessor` 経由で styleMask に `.resizable` を追加する代替手段がある
- **リスク: `setFrameAutosaveName` が macOS のウインドウ復元ロジックと競合**
  - 緩和策: SwiftUI の Settings シーンは state restoration の対象外で手動管理と整合的。実機で確認
- **却下された代替案: `@AppStorage` でサイズを手動保存**
  - 理由: 初期サイズ注入が SwiftUI Settings シーンからは困難で、結局 NSWindow を触る必要があり、素の `setFrameAutosaveName` の方が簡潔かつネイティブ

## File Changes Summary

| File | Change |
|------|--------|
| `Sources/QuickTranscriber/Views/SettingsView.swift` | frame 制約変更、Active/Registered Speakers の ForEach に index 付き縞模様背景、`SettingsWindowAccessor` 追加 |
| `Sources/QuickTranscriberApp/QuickTranscriberApp.swift` | `Settings {}` シーンに `.windowResizability(.contentSize)` 付与 |
