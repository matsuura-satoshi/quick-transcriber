# Settings UI Restructure Design

## Problem

Registered Speakersセクションが`Form > Section > ForEach`で全プロファイルを一括描画している。各`SpeakerProfileRow`にTextField + FlowLayout(タグ) + ポップオーバーがあり、100名規模でパフォーマンスが劣化する。

## Design

### 1. Registered Speakers セクション最適化

`ForEach`を`ScrollView + LazyVStack`に置き換え、固定高さ(350pt)のスクロール領域内でDisclosureGroupによる展開/折りたたみを実装する。

**折りたたみ時**: 名前 + タグ(読み取り専用ピル)
- `displayName`があれば名前のみ表示
- なければ`"Speaker \(label)"`をフォールバック
- タグはインラインピル(×ボタンなし)

**展開時**: 名前TextField + セッション情報 + タグ編集 + 削除ボタン
- 名前のonSubmitで`renameSpeaker`呼び出し
- セッション数 + 最終使用日時
- タグの追加/削除(既存UIを再利用)
- 削除ボタン

### 2. コンポーネント分割

`SpeakerProfileRow` → 2つに分割:
- **SpeakerProfileSummaryView**: 折りたたみラベル(名前 + タグピル)
- **SpeakerProfileDetailView**: 展開コンテンツ(名前編集 + メタデータ + タグ編集 + 削除)

### 3. 表示ロジック変更

Registered Speakers一覧での表示名:
- `displayName`あり → displayNameのみ表示(ラベル非表示)
- `displayName`なし → "Speaker A" (フォールバック)

理由: `label`はセッションごとに変わりうる値であり、永続的な識別子としては`id: UUID`が使われているため、名前設定後のlabel表示は冗長。

### 4. 変更しないもの

- 検索フィールド、タグフィルタピル
- Active Speakersセクション
- Speaker Detectionセクション
- データモデル(`SpeakerProfileStore`, `StoredSpeakerProfile`)
