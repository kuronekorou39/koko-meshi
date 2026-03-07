# ココメシ (KokoMeshi)

「撮るだけ」で食事を全自動記録する食事ログ＆グルメマップアプリ。

料理の写真を撮るだけで、メニュー名・価格・カロリーをAIが自動推定。
高画質のままクラウドに保存し、いつでも閲覧・ダウンロードできます。
外食・自炊・出前、すべての食事を記録します。

## 主な機能

- 料理写真の撮影・クラウド保存（高画質オリジナル）
- AIによるメニュー名・価格・カロリーの自動推定
- 外食時のレストラン自動特定（GPS + Google Places API）
- パーソナル・グルメマップ（外食のピンを地図上に表示）
- 食事記録の一覧・フィルタリング

## 技術スタック

| 領域 | 技術 |
|---|---|
| モバイル | Flutter (Dart) |
| バックエンド / DB / Auth | Supabase |
| 画像ストレージ | Cloudflare R2 |
| 画像解析（AI） | Claude API (Vision) |
| 地図 / 店舗特定 | Google Maps SDK + Places API |

## セットアップ

```bash
flutter pub get
flutter run
```

## ドキュメント

- [要件定義書](docs/requirements.md)
