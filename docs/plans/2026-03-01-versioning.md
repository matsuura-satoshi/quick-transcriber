# バージョン管理導入（Major.Minor.PR#）

## Context
バージョンを継続的に管理するため、`Major.Minor.PR#`形式（例: `1.0.58`）を導入する。現在はAboutViewに `"Version 1.0"` がハードコードされているのみで、バージョン管理の仕組みがない。

## バージョン形式
- `Major.Minor.Patch` — Patch = PR番号
- 現在値: `1.0.58`（このPRが #58 になる想定）
- Major/Minor は開発者が手動で上げる
- Patch は PR作成時に自動更新（CLAUDE.md指示による運用）

## 変更内容

### 1. Constants.swift に Version enum 追加
`Sources/QuickTranscriber/Constants.swift`

```swift
public enum Version {
    public static let major = 1
    public static let minor = 0
    public static let patch = 58
    public static let string = "\(major).\(minor).\(patch)"
}
```

### 2. ウィンドウタイトルにバージョン表示
`Sources/QuickTranscriber/Views/ContentView.swift:42`

```swift
// 変更前
.navigationTitle("Quick Transcriber")
// 変更後
.navigationTitle("Quick Transcriber v\(Constants.Version.string)")
```

### 3. About画面のバージョン表示を定数参照に
`Sources/QuickTranscriberApp/QuickTranscriberApp.swift:171`

```swift
// 変更前
Text("Version 1.0")
// 変更後
Text("Version \(Constants.Version.string)")
```

### 4. 起動ログにバージョン出力
`Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` — `loadModel()` 冒頭

```swift
NSLog("[QuickTranscriber] v\(Constants.Version.string) — Loading model: \(modelName)")
```
既存の `NSLog("[QuickTranscriber] Loading model: \(modelName)")` を置換。

### 5. CLAUDE.md に運用ルール追記
`CLAUDE.md` の適切な場所に追記:

```markdown
## Versioning
- 形式: `Major.Minor.PR#`（例: 1.0.58）
- 定義場所: `Constants.Version`（Constants.swift）
- PR作成時に `Constants.Version.patch` を該当PR番号に更新すること
```

## 変更対象ファイル
| ファイル | 変更内容 |
|---------|---------|
| `Sources/QuickTranscriber/Constants.swift` | Version enum 追加 |
| `Sources/QuickTranscriber/Views/ContentView.swift` | navigationTitle にバージョン追加 |
| `Sources/QuickTranscriberApp/QuickTranscriberApp.swift` | AboutView のバージョン定数参照 |
| `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` | 起動ログにバージョン追加 |
| `CLAUDE.md` | バージョン運用ルール追記 |

## 検証
- `swift build` でビルド確認
- `swift run QuickTranscriber` で起動、Console.app でバージョン付きログ確認
- About画面に "Version 1.0.58" 表示確認
- ウィンドウタイトルが "Quick Transcriber v1.0.58" であること
