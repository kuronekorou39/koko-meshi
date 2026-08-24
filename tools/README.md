# tools

写真の日時と場所から「食べ歩きの動き」をアニメーションで見るための、
ブラウザだけで動く2枚組。どちらも単体のHTMLで、**通信は一切しない**
(ダブルクリックで開くだけ。オフラインでも動く)。

| ファイル | 役割 |
|---|---|
| `trace-extract.html` | 写真をドロップ → EXIFから日時と位置を抽出 → JSONに書き出す |
| `trace-viewer.html` | そのJSONを開いて、時間を進めながら地図上で再生する |
| `exifr.full.umd.js` | 抽出側が使うEXIFリーダー(埋め込み元。下記参照) |

## 使い方

1. `trace-extract.html` を開き、写真かフォルダをドロップする
2. 近い場所・近い時間の写真はまとめられる(既定は50m以内・2時間以内。
   アプリ内のグルーピングと同じ基準。画面上で変えられる)
3. JSONをダウンロードし、`trace-viewer.html` にドロップする

ビューアは「サンプルを見る」で合成データのデモも見られる。

## 入力について

iPhoneのSafariやAndroidのブラウザから写真ピッカー経由で選ぶと、OSが位置情報を
削って渡してくることがある。**PCに原本を持ってきて、フォルダごとドロップする**
のが確実。

ココメシで記録した写真は、設定の「位置情報を付けて保存する」をオンにして
カメラロールに保存すると、ここで読める形になる。

## JSONの形式

```json
{
  "format": "meshi-trace",
  "version": 1,
  "points": [
    { "t": "2026-08-15T13:25:07", "lat": 35.5152, "lng": 139.6871,
      "count": 3, "label": "鶴見", "kind": "photo" }
  ]
}
```

`end`(まとめた区間の終わり)、`label`、`kind`(`meal` / `photo`)は任意。
ビューアは `points` の配列だけでも読む。

## exifr の更新

`trace-extract.html` にはEXIFリーダー([exifr](https://github.com/MikeKovarik/exifr)
7.1.3, MIT)を埋め込んである。差し替えるときは:

```sh
curl -sL -o tools/exifr.full.umd.js https://unpkg.com/exifr@<version>/dist/full.umd.js
```

を取得し直し、`trace-extract.html` の中の該当する `<script>` の中身を丸ごと
置き換える(HTML内に `</script>` を含まないことだけ確認する)。
