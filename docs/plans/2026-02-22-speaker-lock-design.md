# Speaker Lock Design

## Purpose

Registered speakerの誤削除を防止するため、プロファイルにロック機能を追加する。

## Model

`StoredSpeakerProfile`に`isLocked: Bool`を追加（デフォルト`false`）。既存JSONとのCodable互換性を維持する。

## Store

- `delete(id:)`, `deleteMultiple(ids:)`, `deleteAll()`でisLocked == trueのプロファイルをサイレントにスキップ
- `setLocked(id:locked:)`メソッドを追加

## ViewModel

- `TranscriptionViewModel.setLocked(id:locked:)`を追加し、ストアに委譲

## UI

- **SpeakerProfileSummaryView（畳んだ行）**: lockedなら名前の左に`lock.fill`アイコンを表示（表示のみ）
- **SpeakerProfileDetailView（展開内）**: Toggle("Lock")でロック/アンロック操作
- 削除操作時はlockedプロファイルがサイレントにスキップされる
