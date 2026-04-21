# Resizable Settings Window & Zebra-Striped Speaker Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cmd+,` の設定ウインドウを縦横両方向リサイズ可能にし、サイズ・位置を再起動後も記憶する。加えて Active Speakers / Registered Speakers リストに縞模様背景を適用し、幅を広げた時の視認性を改善する。

**Architecture:** SwiftUI の `Settings {}` シーンに `.windowResizability(.contentSize)` を付け、`SettingsView` の frame から max 制約を撤去。`NSViewRepresentable`（`SettingsWindowAccessor`）で NSWindow を掴み、`setFrameAutosaveName("QuickTranscriberSettings")` を呼んで macOS 標準の永続化に乗せる。Speakers タブの 2 つの `ForEach` を enumerated 版に差し替え、偶数行（0-indexed で奇数インデックス）に `Color.primary.opacity(0.04)` の背景を付ける。

**Tech Stack:** Swift, SwiftUI, AppKit (`NSWindow`, `NSViewRepresentable`)、macOS 15+。

**Spec:** `docs/superpowers/specs/2026-04-21-resizable-settings-window-design.md`

---

## File Structure

### Modified
- `Sources/QuickTranscriber/Views/SettingsView.swift` — frame 制約緩和、`SettingsWindowAccessor` 追加、Active Speakers / Registered Speakers の `ForEach` に交互背景
- `Sources/QuickTranscriberApp/QuickTranscriberApp.swift` — `Settings {}` シーンに `.windowResizability(.contentSize)` を付与

### Created
- なし

### Tests
- なし（純粋な SwiftUI View の表示変更でユニットテスト化が困難。ViewInspector 等の依存を増やす価値が低い変更。代わりに Task ごとに手動 UI 検証を必須とする）

---

## Conventions

- ビルド: `swift build`（警告も確認）
- 実行: `swift run QuickTranscriber`
- 既存ユニットテストが壊れないことを確認: `swift test --filter QuickTranscriberTests`
- コミットプレフィックスは既存慣習に従う（`feat:`, `fix:`, `refactor:`, `style:`）
- `Constants.Version.patch` の更新は本プランでは行わない（PR 作成時に別途対応）
- ファイル削除は本プランでは発生しない（CLAUDE.md の `trash` 指針に抵触しない）
- 手動検証の結果（サイズ記憶される／縞模様見える 等）は **実機で確認した上で** コミットに進む（verification-before-completion）

---

## Task 1: Settings ウインドウを縦横リサイズ可能にしサイズを永続化

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`
  - `SettingsView.body` の `.frame` 行（27行目）
  - ファイル末尾に `SettingsWindowAccessor` を追加
- Modify: `Sources/QuickTranscriberApp/QuickTranscriberApp.swift`
  - `Settings { SettingsView(...) }`（119-121行目付近）

- [ ] **Step 1: `SettingsView` の frame 制約を緩和**

`Sources/QuickTranscriber/Views/SettingsView.swift` の 27 行目付近を変更。

変更前:
```swift
        .frame(minWidth: 520, maxWidth: 520, minHeight: 500, maxHeight: 5000)
```

変更後:
```swift
        .frame(minWidth: 520, minHeight: 500)
        .background(SettingsWindowAccessor())
```

`maxWidth` と `maxHeight` を撤去し、最小サイズのみ残す。同時に `.background(SettingsWindowAccessor())` を末尾に追加（次 Step で定義）。

- [ ] **Step 2: `SettingsWindowAccessor` を追加**

`Sources/QuickTranscriber/Views/SettingsView.swift` の末尾（`StepperRow` の直後）に以下を追加:

```swift
// MARK: - Window Size Persistence

/// Settings ウインドウのサイズ・位置を macOS 標準の仕組み（`NSWindow Frame <name>`）で保存・復元する。
/// SwiftUI の `Settings {}` シーンは内部で NSWindow を生成するが、frame autosave 名を設定する手段を
/// 公開していないため、View ツリーから `view.window` を辿って一度だけ設定する。
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

- [ ] **Step 3: Settings シーンに `.windowResizability(.contentSize)` を付与**

`Sources/QuickTranscriberApp/QuickTranscriberApp.swift` の 119-121 行目付近を変更。

変更前:
```swift
        Settings {
            SettingsView(viewModel: viewModel)
        }
```

変更後:
```swift
        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
```

- [ ] **Step 4: ビルドして警告・エラーがないことを確認**

Run: `swift build`
Expected: `Build complete!`、警告なし

- [ ] **Step 5: 既存ユニットテストを実行して破綻していないことを確認**

Run: `swift test --filter QuickTranscriberTests`
Expected: 全テスト PASS（約 2 秒）

- [ ] **Step 6: 手動 UI 検証（リサイズ動作）**

1. `swift run QuickTranscriber` でアプリ起動
2. `cmd+,` で設定ウインドウを開く
3. ウインドウ右下隅・下辺・右辺をドラッグし、**縦横両方向にリサイズできる** ことを確認
4. 最小サイズ以下には縮まない（幅 520pt、高さ 500pt が下限）ことを確認

Expected: ウインドウが自由にリサイズでき、コンテンツがリサイズに追従する

- [ ] **Step 7: 手動 UI 検証（サイズ・位置の永続化）**

1. リサイズしてウインドウを移動した状態で `cmd+w` で閉じる
2. 再度 `cmd+,` で開き、**同じサイズ・位置** で開くことを確認
3. アプリを `cmd+q` で終了
4. `swift run QuickTranscriber` で再起動し、`cmd+,` で開く
5. **前回終了時と同じサイズ・位置** で開くことを確認

Expected: サイズと位置が両方とも記憶されている。`UserDefaults` の `NSWindow Frame QuickTranscriberSettings` に保存されている

- [ ] **Step 8: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift \
        Sources/QuickTranscriberApp/QuickTranscriberApp.swift
git commit -m "$(cat <<'EOF'
feat: make Settings window resizable and persist its size

Remove the fixed-width / capped-height frame on SettingsView, enable
.windowResizability(.contentSize) on the Settings scene, and attach an
NSViewRepresentable that sets NSWindow.setFrameAutosaveName so macOS
persists window size and position across launches.

EOF
)"
```

---

## Task 2: Active Speakers リストに縞模様背景を適用

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`
  - `activeSpeakersSection`（252-262行目付近）の `ForEach`

- [ ] **Step 1: `activeSpeakersSection` の `ForEach` を enumerated 版に置換**

`Sources/QuickTranscriber/Views/SettingsView.swift` の 252 行目付近（`ForEach(viewModel.activeSpeakers) { speaker in` で始まるブロック）を変更。

変更前:
```swift
            ForEach(viewModel.activeSpeakers) { speaker in
                ActiveSpeakerRow(
                    speaker: speaker,
                    onRename: { name in
                        viewModel.tryRenameActiveSpeaker(id: speaker.id, displayName: name)
                    },
                    onRemove: {
                        viewModel.removeActiveSpeaker(id: speaker.id)
                    }
                )
            }
```

変更後:
```swift
            ForEach(Array(viewModel.activeSpeakers.enumerated()), id: \.element.id) { index, speaker in
                ActiveSpeakerRow(
                    speaker: speaker,
                    onRename: { name in
                        viewModel.tryRenameActiveSpeaker(id: speaker.id, displayName: name)
                    },
                    onRemove: {
                        viewModel.removeActiveSpeaker(id: speaker.id)
                    }
                )
                .listRowBackground(zebraBackground(for: index))
                .background(zebraBackground(for: index))
            }
```

`.listRowBackground` は Form/Section が List ベースのレンダリングの場合に効き、`.background` はそれ以外（直接描画）の場合に効く。両方書いておくことで、SwiftUI の内部実装によらず縞模様が出る。実機で片方で十分と確認できれば Step 5 でどちらか削除。

- [ ] **Step 2: `zebraBackground(for:)` ヘルパーを追加**

`SpeakersSettingsTab` 構造体の中（`body` プロパティの直後、`speakerDetectionSection` の直前、173 行目付近）にヘルパーを追加:

```swift
    /// 行 index（0-indexed）に応じた縞模様背景色を返す。
    /// 奇数 index（= 2, 4, 6... 番目の行）にのみ薄い背景を付け、視線追従を助ける。
    private func zebraBackground(for index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04)
    }
```

- [ ] **Step 3: ビルドして警告・エラーがないことを確認**

Run: `swift build`
Expected: `Build complete!`、警告なし

- [ ] **Step 4: 既存ユニットテストを実行**

Run: `swift test --filter QuickTranscriberTests`
Expected: 全テスト PASS

- [ ] **Step 5: 手動 UI 検証（Active Speakers の縞模様）**

1. `swift run QuickTranscriber` でアプリ起動
2. 録音を開始し、複数話者分の音声を入れて Active Speakers に 3 人以上並ぶ状態にする（または Manual モードで "New Speaker..." を 3 回以上クリックして空の speaker を追加）
3. `cmd+,` → Speakers タブ
4. Active Speakers セクションで、**1 番目・3 番目・5 番目の行** に背景なし、**2 番目・4 番目の行** に薄いグレーの背景が出ていることを確認
5. Light / Dark モードを切り替えて（システム環境設定から）両方で自然に見えることを確認
6. `.listRowBackground` と `.background` の両方を設定した場合どちらで縞模様が出ているかを確認し、動いていない方の修飾子を削除する
   - Form（`.grouped`）は内部で List ベースなら `.listRowBackground` が効く可能性が高い
   - 効かなかった方の行を Step 6 で削除

Expected: 縞模様が見え、Light/Dark 両方で視認性が良い

- [ ] **Step 6: 効かない方の背景修飾子を削除して整理**

Step 5 の観察で `.listRowBackground` または `.background` の片方のみで縞模様が出たことを確認したら、効いていない方の行を削除してコードを整理する。両方効いていた場合は色が濃くなりすぎるので、どちらか片方のみ残す（`.background` を優先）。

もし両方効いていなかった場合は、`ActiveSpeakerRow` を自前の `HStack` でラップして `.background` を当てる方式に変更する:

```swift
            ForEach(Array(viewModel.activeSpeakers.enumerated()), id: \.element.id) { index, speaker in
                HStack {
                    ActiveSpeakerRow(
                        speaker: speaker,
                        onRename: { name in
                            viewModel.tryRenameActiveSpeaker(id: speaker.id, displayName: name)
                        },
                        onRemove: {
                            viewModel.removeActiveSpeaker(id: speaker.id)
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .background(zebraBackground(for: index))
            }
```

- [ ] **Step 7: 再度ビルドと手動検証**

Run: `swift build && swift run QuickTranscriber`
Expected: 縞模様が 1 つの方式で安定して描画される

- [ ] **Step 8: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
style: add zebra striping to Active Speakers list

Alternate row backgrounds in the Active Speakers section of the Settings
Speakers tab so the eye can track from name on the left to controls on
the right, which becomes important once the window is widened.

EOF
)"
```

---

## Task 3: Registered Speakers リストに縞模様背景を適用

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`
  - `registeredSpeakersSection` 内の `ForEach`（367-394行目付近）

- [ ] **Step 1: Registered Speakers の `ForEach` を enumerated 版に置換して背景適用**

`Sources/QuickTranscriber/Views/SettingsView.swift` の 367 行目付近（`VStack(alignment: .leading, spacing: 0) {` 内の `ForEach(filteredProfiles, id: \.id) { profile in`）を変更。

変更前:
```swift
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredProfiles, id: \.id) { profile in
                        DisclosureGroup {
                            SpeakerProfileDetailView(
                                profile: profile,
                                allTags: viewModel.allTags,
                                onRename: { name in viewModel.tryRenameSpeaker(id: profile.id, to: name) },
                                onDelete: { viewModel.deleteSpeaker(id: profile.id) },
                                onAddTag: { tag in viewModel.addTag(tag, to: profile.id) },
                                onRemoveTag: { tag in viewModel.removeTag(tag, from: profile.id) },
                                onSetLocked: { locked in viewModel.setLocked(id: profile.id, locked: locked) }
                            )
                        } label: {
                            SpeakerProfileSummaryView(
                                profile: profile,
                                isActive: viewModel.activeProfileIds.contains(profile.id),
                                isDiarizationEnabled: store.parameters.enableSpeakerDiarization,
                                onToggleActive: { newValue in
                                    if newValue {
                                        viewModel.addManualSpeaker(fromProfile: profile.id)
                                    } else {
                                        viewModel.deactivateSpeaker(profileId: profile.id)
                                    }
                                }
                            )
                        }
                        Divider()
                    }
                }
```

変更後:
```swift
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredProfiles.enumerated()), id: \.element.id) { index, profile in
                        DisclosureGroup {
                            SpeakerProfileDetailView(
                                profile: profile,
                                allTags: viewModel.allTags,
                                onRename: { name in viewModel.tryRenameSpeaker(id: profile.id, to: name) },
                                onDelete: { viewModel.deleteSpeaker(id: profile.id) },
                                onAddTag: { tag in viewModel.addTag(tag, to: profile.id) },
                                onRemoveTag: { tag in viewModel.removeTag(tag, from: profile.id) },
                                onSetLocked: { locked in viewModel.setLocked(id: profile.id, locked: locked) }
                            )
                        } label: {
                            SpeakerProfileSummaryView(
                                profile: profile,
                                isActive: viewModel.activeProfileIds.contains(profile.id),
                                isDiarizationEnabled: store.parameters.enableSpeakerDiarization,
                                onToggleActive: { newValue in
                                    if newValue {
                                        viewModel.addManualSpeaker(fromProfile: profile.id)
                                    } else {
                                        viewModel.deactivateSpeaker(profileId: profile.id)
                                    }
                                }
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(zebraBackground(for: index))
                        Divider()
                    }
                }
```

変更点:
- `ForEach(Array(filteredProfiles.enumerated()), id: \.element.id) { index, profile in` にして index を取り出す
- `DisclosureGroup` の直後に `.frame(maxWidth: .infinity, alignment: .leading)` と `.background(zebraBackground(for: index))` を追加（これにより、展開時の詳細ビューも含めて同じ背景色が行全体に掛かる）

- [ ] **Step 2: ビルドして警告・エラーがないことを確認**

Run: `swift build`
Expected: `Build complete!`、警告なし

- [ ] **Step 3: 既存ユニットテストを実行**

Run: `swift test --filter QuickTranscriberTests`
Expected: 全テスト PASS

- [ ] **Step 4: 手動 UI 検証（Registered Speakers の縞模様）**

1. `swift run QuickTranscriber` でアプリ起動
2. `cmd+,` → Speakers タブ
3. Registered Speakers に少なくとも 4 人以上の登録話者がある状態にする（既に登録されているか、録音＋停止で新規作成する）
4. リストで **1 番目・3 番目の行** は背景なし、**2 番目・4 番目の行** は薄いグレーの背景が出ていることを確認
5. DisclosureGroup を展開し、**展開内容（詳細ビュー）の背景も行と同じ色** になっていることを確認（展開しても縞模様が崩れない）
6. 検索テキストでフィルタしても index が再計算され、フィルタ後の表示順で縞模様が正しく交互になっていることを確認
7. Tag フィルタを選択して絞り込んだ場合も同様に正しい順で縞模様が出ることを確認
8. Light / Dark モードを切り替えて両方で自然に見えることを確認

Expected: 縞模様が正しく出て、DisclosureGroup 展開時も背景色が行全体を覆う。フィルタ後の index にも追従する

- [ ] **Step 5: 全体の一貫性を手動確認**

1. Active Speakers と Registered Speakers の縞模様の色味・濃度が同程度であることを確認（どちらも `Color.primary.opacity(0.04)` なので一致するはず）
2. ウインドウを横に広げた状態で、視線が左（名前）→ 右（削除ボタン／トグル）と移動するときに行の対応が追いやすくなっていることを確認
3. Reset to Defaults / New Speaker ボタン等、Section 内の他の要素の見え方に悪影響がないことを確認

Expected: 意図通り、視認性が向上している

- [ ] **Step 6: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
style: add zebra striping to Registered Speakers list

Alternate row backgrounds in the Registered Speakers section so the
visual tracking aid applied to Active Speakers is consistent across
both lists. Background is applied to the DisclosureGroup container so
the stripe color extends over the expanded detail view as well.

EOF
)"
```

---

## Self-Review Checklist

**Spec coverage:**
- Goal 1 (縦横リサイズ可能): Task 1 Step 1–3
- Goal 2 (サイズ永続化): Task 1 Step 2 (`SettingsWindowAccessor`) + Step 7 (手動検証)
- Goal 3 (Active Speakers の縞模様): Task 2 全体
- Goal 3 (Registered Speakers の縞模様): Task 3 全体
- 色 (`Color.primary.opacity(0.04)`): Task 2 Step 2
- 奇数行素地 / 偶数行濃色: `index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04)`（0-indexed で偶数 index = 1 番目・3 番目 = 素地、奇数 index = 2 番目・4 番目 = 濃色）
- DisclosureGroup 展開時も背景が一致: Task 3 Step 1 で `.frame(maxWidth: .infinity)` + `.background` を DisclosureGroup 外側に適用

**Placeholder scan:** TBD / TODO / 省略なし。全ての Step に具体的なコード・コマンド・期待値あり。

**Type consistency:** `zebraBackground(for:) -> Color` を Task 2 Step 2 で定義し、Task 2 Step 1 と Task 3 Step 1 で同じシグネチャで呼び出している。`SettingsWindowAccessor` は `NSViewRepresentable` として Task 1 Step 2 で定義、Task 1 Step 1 で `.background(SettingsWindowAccessor())` として利用。一致。
