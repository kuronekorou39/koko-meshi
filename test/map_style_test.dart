import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/map_style.dart';

List<Map<String, dynamic>> parse(String json) =>
    (jsonDecode(json) as List).cast<Map<String, dynamic>>();

/// そのfeatureTypeを隠すルールが入っているか
bool hides(String style, String featureType) =>
    parse(style).any((r) => r['featureType'] == featureType);

void main() {
  test('既定(すべてオフ)はラベルを全部隠す', () {
    final style = buildMapStyle(const {});
    for (final layer in MapLabelLayer.values) {
      for (final rule in layer.hiddenBy) {
        expect(hides(style, rule.featureType), isTrue,
            reason: '${layer.name} の ${rule.featureType}');
      }
    }
  });

  test('オンにしたレイヤーは隠すルールから消える', () {
    final style = buildMapStyle({MapLabelLayer.stations});
    expect(hides(style, 'transit'), isFalse);
    // 他は隠したまま
    expect(hides(style, 'administrative'), isTrue);
    expect(hides(style, 'poi.business'), isTrue);
  });

  test('複数オンにしてもそれぞれ効く', () {
    final style = buildMapStyle({
      MapLabelLayer.stations,
      MapLabelLayer.places,
      MapLabelLayer.shops,
    });
    expect(hides(style, 'transit'), isFalse);
    expect(hides(style, 'administrative'), isFalse);
    expect(hides(style, 'poi.business'), isFalse);
    expect(hides(style, 'road'), isTrue);
  });

  test('全部オンならルールが空になる(Googleの既定表示)', () {
    final style = buildMapStyle(MapLabelLayer.values.toSet());
    expect(parse(style), isEmpty);
  });

  test('施設名は複数のfeatureTypeをまとめて切り替える', () {
    final off = buildMapStyle(const {});
    final on = buildMapStyle({MapLabelLayer.facilities});
    for (final t in ['poi.attraction', 'poi.school', 'poi.medical']) {
      expect(hides(off, t), isTrue, reason: t);
      expect(hides(on, t), isFalse, reason: t);
    }
  });

  group('生成されるJSONの形', () {
    test('elementTypeを持つものは指定され、持たないものは省かれる', () {
      final rules = parse(buildMapStyle(const {}));
      final road = rules.firstWhere((r) => r['featureType'] == 'road');
      expect(road['elementType'], 'labels', reason: '道路そのものは残す');

      final transit = rules.firstWhere((r) => r['featureType'] == 'transit');
      expect(transit.containsKey('elementType'), isFalse,
          reason: '駅は路線ごと隠すので要素を絞らない');
    });

    test('stylersは visibility off', () {
      final rules = parse(buildMapStyle(const {}));
      for (final r in rules) {
        expect(r['stylers'], [
          {'visibility': 'off'},
        ]);
      }
    });
  });
}
