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

**背景色は夜 `#17130E`**（デザインシステムのダーク下地）。白フチのステッカーが
最も強く際立ち、暖色系（漆・芥子）と違ってカメラの緑と色相が競合しない。
元絵の別バージョンには薄紫（`#D4C6F7`）の背景つきもあったが、デザインシステムで
紫は使わない方針のため採用していない。候補の比較は次のコマンドで作れる:

```bash
python tool/make_app_icon.py --preview   # 漆 / 生成り / 夜 / 抹茶
```

**前景の倍率は 0.70**。Adaptive Icon は 108dp のうち中央 72dp（66%）しか表示が
保証されないため、最も削られる円マスクでもカメラが切れないことを実機で確認して
決めた。

色を変えるときは `tool/make_app_icon.py` の `BACKGROUND` と `pubspec.yaml` の
`adaptive_icon_background` / `background_color_ios` の3か所を揃えること。
