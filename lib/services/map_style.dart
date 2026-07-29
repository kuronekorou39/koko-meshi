import 'dart:convert';

/// 地図に出すラベルの種類。既定はすべてオフで、まっさらな地図にする。
///
/// 自分の記録のピンを主役にしたいので、既定では駅も店も地名も出さない。
/// ただし「この辺に何があるか」を見たいときもあるので、種類ごとに出せる
/// ようにしてある。
///
/// **どれをオンにしても費用は増えない。** スタイルはSDKが端末内で描画に
/// 使うだけで、Maps Platform へのリクエストではない(モバイルの地図表示
/// そのものが無料・無制限)。Places API で店を検索するのとは別の話で、
/// [shops] で出る店名は Google の基本地図に含まれるラベル。
enum MapLabelLayer {
  stations('駅・路線', [MapStyleRule('transit')]),
  places('地名', [MapStyleRule('administrative', 'labels')]),
  shops('店名', [MapStyleRule('poi.business')]),
  roads('道路名', [MapStyleRule('road', 'labels')]),
  parks('公園名', [MapStyleRule('poi.park', 'labels')]),
  facilities('施設名', [
    MapStyleRule('poi.attraction'),
    MapStyleRule('poi.government'),
    MapStyleRule('poi.medical'),
    MapStyleRule('poi.place_of_worship'),
    MapStyleRule('poi.school'),
    MapStyleRule('poi.sports_complex'),
  ]);

  const MapLabelLayer(this.label, this.hiddenBy);

  final String label;

  /// このレイヤーがオフのときに隠すもの
  final List<MapStyleRule> hiddenBy;
}

/// スタイルJSONの1ルール。elementType 省略は要素すべて。
class MapStyleRule {
  const MapStyleRule(this.featureType, [this.elementType]);

  final String featureType;
  final String? elementType;

  Map<String, Object> toJson() => {
        'featureType': featureType,
        'elementType': ?elementType,
        'stylers': const [
          {'visibility': 'off'},
        ],
      };
}

/// google_maps_flutter の `style` に渡すJSONを作る。
///
/// オンにしたレイヤーは「何も指定しない」= Googleの既定表示に任せる。
/// オフのものだけ visibility:off を並べる。
String buildMapStyle(Set<MapLabelLayer> visibleLayers) {
  final rules = <Map<String, Object>>[];
  for (final layer in MapLabelLayer.values) {
    if (visibleLayers.contains(layer)) continue;
    rules.addAll(layer.hiddenBy.map((r) => r.toJson()));
  }
  return jsonEncode(rules);
}
