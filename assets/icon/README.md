# アプリアイコン

| ファイル | 用途 |
|---|---|
| `source-koko-meshi-icon.png` | 元絵（1900x1900・背景透過）。加工前の原本 |
| `app_icon.png` | 通常アイコン（1024x1024・不透明）。iOSとAndroid 7以下 |
| `app_icon_foreground.png` | Adaptive Icon の前景（1024x1024・透過） |
| `preview-background.png` | 背景色候補の比較（`--preview` で生成。gitignore対象） |

このディレクトリは `pubspec.yaml` の `assets:` に `assets/` としか書いていないため
APKには含まれない（Flutterのアセット指定はサブディレクトリを再帰的に取り込まない）。

## 再生成

```bash
python tool/make_app_icon.py     # 素材を作り直す
dart run flutter_launcher_icons  # mipmap 一式を生成
```

生成先は `android/app/src/main/res/`（mipmap-*, drawable-*, mipmap-anydpi-v26,
values/colors.xml）と `ios/Runner/Assets.xcassets/`。

## 設計判断

**背景色は薄紫 `#D4C6F7`**。元絵の背景つきバージョンと同じ色で、作者の指定。
アプリ内のデザインシステム（和の食記録帳）には無い色だが、アイコンはホーム画面で
他のアプリと並ぶものなので、絵柄ごと1つの作品として扱っている。
（一時期はダーク下地の夜 `#17130E` にしていた。白フチのステッカーが際立つが、
絵の意図とは別の見た目になっていた）。候補の比較は次のコマンドで作れる:

```bash
python tool/make_app_icon.py --preview   # 薄紫 / 漆 / 生成り / 夜 / 抹茶
```

**前景の倍率は 0.70**。Adaptive Icon は 108dp のうち中央 72dp（66%）しか表示が
保証されないため、最も削られる円マスクでもカメラが切れないことを実機で確認して
決めた。

色を変えるときは `tool/make_app_icon.py` の `BACKGROUND` と `pubspec.yaml` の
`adaptive_icon_background` / `background_color_ios` の3か所を揃えること。
