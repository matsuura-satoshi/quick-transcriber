# Auto-Update機能の追加

## Context
現在GitHub Releasesでzipを配布しているが、ユーザーが手動でダウンロード・置換する必要がある。アプリ内から最新バージョンをチェックし、自動でダウンロード・置換・再起動できるようにしたい。

**方針:** Sparkleはアドホック署名・SPM executable targetとの相性が悪いため、GitHub APIを使ったカスタム実装で行う。依存追加ゼロ、ビルドスクリプト変更不要。

## 実装概要

### 1. `UpdateChecker`サービス作成
**新規:** `Sources/QuickTranscriber/Services/UpdateChecker.swift`

- GitHub API (`repos/.../releases/latest`) で最新リリースを取得
- セマンティックバージョン比較（`Constants.Version.string` vs `tag_name`）
- 新バージョンがあればダウンロード→展開→quarantine除去→置換→再起動
- `@MainActor ObservableObject` で状態管理（`isChecking`, `updateAvailable`, `downloadProgress`等）

```
GitHubRelease (Codable): tag_name, html_url, assets[].browser_download_url
```

**バージョン比較:** `isNewer("1.0.61", than: "1.0.60")` → true（セマンティック比較）

**アップデートフロー:**
1. `URLSession.shared.download(from:)` でzipをtempディレクトリにDL
2. `/usr/bin/ditto -xk` で展開
3. `xattr -dr com.apple.quarantine` でquarantine属性除去（ユーザー再設定不要）
4. 現在のapp bundleをゴミ箱に移動（`NSWorkspace.shared.recycle()`）
5. 新しいapp bundleを同じ場所にコピー
6. `Process()` + `/usr/bin/open` で新アプリを起動
7. `NSApplication.shared.terminate()` で自身を終了

**フォールバック:** 置換に失敗した場合（/Applications/で権限不足等）はブラウザでリリースページを開く

### 2. GitHub定数追加
**変更:** `Sources/QuickTranscriber/Constants.swift`

```swift
public enum GitHub {
    public static let owner = "matsuura-satoshi"
    public static let repo = "quick-transcriber"
}
```

### 3. メニュー項目追加
**変更:** `Sources/QuickTranscriberApp/QuickTranscriberApp.swift`

- `CommandGroup(after: .appInfo)` に "Check for Updates..." を追加
- 標準的なmacOSメニュー配置（About直下）
- アラート表示: アップデートあり→「ダウンロードしてインストール」/「後で」、なし→「最新版です」

### 4. 起動時自動チェック（1日1回）
- `@AppStorage("lastUpdateCheck")` で最終チェック時刻を保持
- 起動時に24時間経過していればバックグラウンドチェック
- 新バージョンがある場合のみアラート表示

### 5. ユニットテスト
**新規:** `Tests/QuickTranscriberTests/UpdateCheckerTests.swift`

- `isNewer()` バージョン比較テスト（15パターン）
- `GitHubRelease` JSONデコードテスト

## 変更ファイル一覧
| ファイル | 操作 |
|---------|------|
| `Sources/QuickTranscriber/Services/UpdateChecker.swift` | 新規 |
| `Sources/QuickTranscriber/Constants.swift` | 変更（GitHub定数追加） |
| `Sources/QuickTranscriberApp/QuickTranscriberApp.swift` | 変更（メニュー・アラート・自動チェック追加） |
| `Tests/QuickTranscriberTests/UpdateCheckerTests.swift` | 新規 |
