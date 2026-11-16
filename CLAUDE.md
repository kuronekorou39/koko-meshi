# ココメシ (KokoMeshi) 開発ガイド

## ビルド

- リリースAPKビルド時は:
  1. `pubspec.yaml` の `version` をインクリメントする（パッチ/マイナー/メジャーは変更規模に応じて判断）
  2. ビルド後、出力ファイルをアプリ名+バージョンにリネームする（例: `kokomeshi-v0.2.0.apk`）
- アプリ内バージョン表示は `package_info_plus` で `pubspec.yaml` から自動取得している。ハードコードしないこと

## リリースと配信

1. `pubspec.yaml` の `version` を上げてコミット・push
2. `v<version>` のタグを push → GitHub Actions (`release.yml`) がAPKをビルドして GitHub Release に付ける(iOS は App Store Connect へ送る)
3. 配信する(下記)

**タグを打っても Android の端末には降りない。** アプリの更新確認は GitHub ではなく
`https://rou39.com/kokomeshi/update.json` を見ていて、これは個人サイトのリポジトリ
(portfolio-rou39-dev)で配信スクリプトを走らせたときだけ書き換わる。OmniVerse と同じ形。

```bash
# portfolio-rou39-dev で
node scripts/kokomeshi/publish-android.mjs --beta --notes "..."   # 自分の端末だけで試す
node scripts/kokomeshi/publish-android.mjs --notes "..."          # 全員に配る
```

- `--beta` は `update-beta.json` だけを書き換える。届くのは「テスト版も受け取る」をオンにした端末だけ
  (設定画面のいちばん下、バージョン表示を長押しで切り替え)
- 確かめて問題なければ `--beta` を付けずにもう一度走らせる(APKは同じものなので上げ直さない)
- iOS は App Store に出ている版を照会するので、配信スクリプトの対象外
- **同じバージョン番号でリリースを差し替えない。** 更新確認はバージョン番号の比較なので、番号が変わらないと届かない
