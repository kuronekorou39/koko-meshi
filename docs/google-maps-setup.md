# Google Maps / Places のセットアップ

APIキーはAPKから平文で取り出せる（`assets/flutter_assets/.env`）。
キーそのものは隠せないので、**キーごとに使えるAPIを絞る**ことと
**割り当て上限で被害額を頭打ちにする**ことで守る。

## 有効化するAPI

Google Cloud Console → APIとサービス → **APIライブラリ**（「有効なAPI」には
有効化済みのものしか出ない）で以下を有効化する。

| API | 用途 |
|---|---|
| Maps SDK for Android | 地図の表示 |
| Maps SDK for iOS | 地図の表示（iOS対応時） |
| Places API (New) | 店舗の検索 |

**Geocoding API は不要。** 住所の逆引き（`placemarkFromCoordinates`）は
`geocoding` パッケージがOS内蔵のジオコーダを使うので、Maps Platform の
課金対象にならない。

## 作るキー

### 先に: 自動生成された「Maps Platform API Key」を消す

Maps Platform を有効化すると、Google が `Maps Platform API Key` という名前の
キーを勝手に1本作る。**たいていアプリケーションの制限が「なし」で、有効化した
APIを全部呼べる**状態になっている。つまりAPKから抜けば誰でも使える。

下記の3本を新しく作り、**この自動生成キーは削除する**。用途のはっきりした
キーを作り直すほうが、既存キーの設定を編集するより間違えにくい。

放置すると、制限なしで全APIを呼べるキーがプロジェクトに残り続ける。
いま閉じようとしている穴そのものなので、必ず消すこと。

### なぜ1本にまとめられないか

アプリケーションの制限は**1キーにつき1種類しか選べない**（なし / HTTPリファラー /
IPアドレス / Androidアプリ / iOSアプリ）。1本のキーをAndroidとiOSの両方に
制限することは原理的にできないので、地図用はプラットフォームごとに分ける。
1本のままだと「なし」しか選べず、抜き取られたキーを誰でも使える状態が続く。

Places を別にするのは、漏れたときの被害範囲を1つのAPIに閉じ込めるため。

| キー名 | APIの制限 | アプリケーションの制限 | .env の変数 |
|---|---|---|---|
| `kokomeshi-maps-android` | Maps SDK for Android | Androidアプリ（下記2ペア） | `GOOGLE_MAPS_API_KEY` |
| `kokomeshi-maps-ios` | Maps SDK for iOS | iOSアプリ（バンドルID） | `GOOGLE_MAPS_API_KEY_IOS` |
| `kokomeshi-places` | Places API (New) | **なし** | `GOOGLE_PLACES_API_KEY` |

### Androidアプリ制限に登録するペア

```
com.kokomeshi.koko_meshi.dev
32:3B:CE:EF:1B:B8:C0:73:86:35:49:AA:FC:6C:D6:77:1F:AD:34:3A

com.kokomeshi.koko_meshi
C7:66:76:A6:6E:69:C4:F7:F0:7E:CA:69:FE:6D:E4:6E:FD:76:B2:90
```

開発ビルドは `.dev` 接尾辞の別アプリで、署名も既定のデバッグ鍵。
別アプリなので**両方登録しないと開発中に地図が出ない**。

SHA-1 の取り直し:

```bash
# リリース署名
keytool -list -v -keystore android/app/kokomeshi-release.keystore -alias kokomeshi

# デバッグ署名
keytool -list -v -keystore ~/.android/debug.keystore \
  -storepass android -keypass android -alias androiddebugkey
```

### iOSアプリ制限に登録するバンドルID

```
com.kokomeshi.kokoMeshi
```

### Places のキーにアプリ制限をかけない理由

Places は `http` パッケージから直接呼んでいる。Androidアプリ制限は
リクエストの `X-Android-Package` / `X-Android-Cert` ヘッダで判定されるが、
Maps SDK と違って `http` はこれを送らない。制限をかけると検索が動かなくなる。

代わりに **API制限（Places API (New) だけ）** と **割り当て上限**で守る。
キーが漏れても被害はPlaces検索に限定され、1日の上限額で頭打ちになる。

将来アプリ制限をかけるなら、`PlacesService._post` にヘッダを追加し、
署名のSHA-1をビルド時定数として埋め込む必要がある。Play App Signing を
使う場合は埋め込むSHA-1がGoogleの署名鍵のものになる点に注意。

## 割り当て上限（これが実質的な防波堤）

`https://console.cloud.google.com/apis/api/places.googleapis.com/quotas`

**API単位ではなくリクエスト種別ごと**に並ぶ。アプリが呼ぶのは2種類だけ。

| 項目 | 初期値 | 設定値 |
|---|---|---|
| `SearchNearbyRequest per day` | 75,000 | **30** |
| `SearchTextRequest per day` | 75,000 | **150** |
| `SearchNearbyRequest per minute` | 600 | **20** |
| `SearchTextRequest per minute` | 600 | **20** |

**Nearby Search は Enterprise ティア**（無料1,000回/月）。周辺検索で評価・
価格帯を出すために `rating` / `userRatingCount` / `priceLevel` を要求して
いるため。31日で割ると約32/日なので、30なら月930回で枠内に収まる。

Text Search は Pro ティアのまま（無料5,000回/月）なので150/日。
31日で4,650回。

なお周辺検索は `--dart-define=PLACE_SEARCH=true` を付けたビルドでしか
動かない（[AppFeatures.placeSearch]）。配布しているAPKからは呼ばれないので、
この上限は開発者1人分の使用量に対する蓋でしかない。**配布時に有効化するなら、
費用を誰が負担するのかを先に決めること。** 1万人が月10回使えば10万回/月で、
無料枠の100倍になる。

### 使っていない種別は 0 にする（こちらのほうが重要）

キーを Places API (New) に制限しても、**その中の使っていないエンドポイントは
全部叩ける**。特に Autocomplete は課金対象で初期値が175,000回/日ある。

| 項目 | 初期値 | 設定値 |
|---|---|---|
| `AutocompletePlacesRequest per day` | 175,000 | **0** |
| `GetPlaceRequest per day` | 125,000 | **0** |
| `GetPhotoMediaRequest per day` | 175,000 | **0** |
| `SearchMediaRequest per minute` | 600 | **0** |
| `SearchReviewPostsRequest per minute` | 600 | **0** |

`SearchMedia` / `SearchReviewPosts` は日次が「無制限」で日次側に蓋ができないので、
分単位で塞ぐ。逆に**日次を0にできた種別は分単位を触らなくてよい**（日次のほうが
上位の制約になるので、分単位が何であれ1件も通らない）。

設定後、一覧に戻って**0がちゃんと保存されているか**を確認すること。0が拒否されても
エラーが出ず元の値のまま、ということがある。その場合は分単位を0にして塞ぐ。

Places の写真を表示するようにしたら `GetPhotoMedia` を戻すこと
（現在はフィールドマスクから写真を外しているので呼ばれない）。

### 「割り当ての調整」は有効にしない

ページ上部に「使用状況に基づいて割り当てが自動で段階的に増加します」とある。
**有効にすると絞った上限が勝手に上がる。** 目的と正反対なので触らない。

### 予算アラート

お支払い → 予算とアラート → $1、閾値 50/90/100%。
**これは通知するだけで課金を止めない。** 止めるのは割り当て上限のほう。両方やる。

## .env

```
GOOGLE_MAPS_API_KEY=<kokomeshi-maps-android>
GOOGLE_MAPS_API_KEY_IOS=<kokomeshi-maps-ios>
GOOGLE_PLACES_API_KEY=<kokomeshi-places>
```

`GOOGLE_PLACES_API_KEY` が空なら `GOOGLE_MAPS_API_KEY` にフォールバックする
（キーを分ける前の .env でも動くように）。

**`.env` を変えたら GitHub Secrets の `DOTENV_BASE64` も更新する。**
CIのリリースビルドはこれを使っている。

```bash
base64 -w0 .env    # 出力を DOTENV_BASE64 に貼る
```

## 反映と確認

- キーの制限が反映されるまで**最大5分**かかる
- 新しいキーで地図と検索が両方動くのを確認してから、古いキーを削除する
- 制限が効いているかは外から確認できる:

```bash
# Places キー: 200 が返る（アプリ制限なしなので通る）
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  'https://places.googleapis.com/v1/places:searchText' \
  -H 'Content-Type: application/json' \
  -H "X-Goog-Api-Key: $PLACES_KEY" \
  -H 'X-Goog-FieldMask: places.id' \
  -d '{"textQuery":"横浜駅","languageCode":"ja","maxResultCount":1}'

# 地図キー: PCから叩くと弾かれる（Androidアプリ制限が効いている証拠）
curl -s "https://maps.googleapis.com/maps/api/geocode/json?address=tokyo&key=$MAPS_KEY"
```

## 参考: 課金されるのはどこか

| 呼び出し | 場所 | 課金 |
|---|---|---|
| `places:searchNearby` | マップの「このエリアで検索」（開発ビルドのみ） | Nearby Search **Enterprise** |
| `places:searchText` | 場所編集の検索欄（500msデバウンス） | Text Search Pro |
| 地図の表示 | `google_maps_flutter` | モバイルネイティブは無料枠 |
| 住所の逆引き | `placemarkFromCoordinates` | 課金対象外（OSのジオコーダ） |

どちらの検索も**利用者がボタンや入力を操作したときだけ**呼ばれる。
撮影・保存の経路からは呼んでいない。

失敗したときは理由を画面に出す（`PlacesError`）。上限に当たったのか
通信できないのかを、0件と区別して伝える。
