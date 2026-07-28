import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/places_service.dart';

/// 検索の中心。ここからの距離で並べ替えを確かめる
const centerLat = 35.4658;
const centerLng = 139.6222;

PlaceInfo place(
  String name, {
  double? rating,
  int? priceLevel,
  double latOffset = 0,
  String? address,
}) =>
    PlaceInfo(
      id: name,
      name: name,
      address: address,
      latitude: centerLat + latOffset,
      longitude: centerLng,
      rating: rating,
      priceLevel: priceLevel,
    );

List<String> namesOf(List<PlaceInfo> places) =>
    places.map((p) => p.name).toList();

List<PlaceInfo> run(List<PlaceInfo> places, PlaceSearchOptions options) =>
    PlacesService.narrowAndSort(places, options,
        centerLat: centerLat, centerLng: centerLng);

void main() {
  group('並べ替え', () {
    test('近い順', () {
      final result = run([
        place('遠い', latOffset: 0.01),
        place('近い', latOffset: 0.001),
        place('中間', latOffset: 0.005),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.distance));
      expect(namesOf(result), ['近い', '中間', '遠い']);
    });

    test('人気順はAPIの並びをそのまま使う', () {
      final result = run([
        place('B', latOffset: 0.01),
        place('A', latOffset: 0.001),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.popularity));
      expect(namesOf(result), ['B', 'A']);
    });

    test('評価が高い順', () {
      final result = run([
        place('低', rating: 3.2),
        place('高', rating: 4.6),
        place('中', rating: 4.0),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.rating));
      expect(namesOf(result), ['高', '中', '低']);
    });

    test('評価が無い店は末尾へ送る(良い側に紛れさせない)', () {
      final result = run([
        place('評価なし'),
        place('低い', rating: 3.0),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.rating));
      expect(namesOf(result), ['低い', '評価なし']);
    });

    test('価格が安い順', () {
      final result = run([
        place('高い', priceLevel: 3),
        place('安い', priceLevel: 1),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.priceAsc));
      expect(namesOf(result), ['安い', '高い']);
    });

    test('価格が高い順でも、価格不明は末尾', () {
      final result = run([
        place('不明'),
        place('安い', priceLevel: 1),
        place('高い', priceLevel: 4),
      ], const PlaceSearchOptions(sort: PlaceSortOrder.priceDesc));
      expect(namesOf(result), ['高い', '安い', '不明']);
    });
  });

  group('絞り込み', () {
    test('評価の下限で切る', () {
      final result = run([
        place('4.5', rating: 4.5),
        place('3.0', rating: 3.0),
      ], const PlaceSearchOptions(minRating: 4.0));
      expect(namesOf(result), ['4.5']);
    });

    test('評価の下限を指定すると、評価が無い店も落ちる', () {
      final result = run(
        [place('評価なし'), place('4.5', rating: 4.5)],
        const PlaceSearchOptions(minRating: 4.0),
      );
      expect(namesOf(result), ['4.5']);
    });

    test('価格の上限で切る', () {
      final result = run([
        place('¥', priceLevel: 1),
        place('¥¥¥¥', priceLevel: 4),
      ], const PlaceSearchOptions(maxPriceLevel: 2));
      expect(namesOf(result), ['¥']);
    });

    test('価格が不明な店は上限指定でも落とさない(情報が無いだけなので)', () {
      final result = run(
        [place('不明'), place('高い', priceLevel: 4)],
        const PlaceSearchOptions(maxPriceLevel: 2),
      );
      expect(namesOf(result), ['不明']);
    });

    test('キーワードは店名と住所の両方を見る', () {
      final result = run([
        place('らーめん太郎'),
        place('寿司次郎', address: '横浜市中区'),
        place('カレー三郎', address: '川崎市'),
      ], const PlaceSearchOptions(keyword: '横浜'));
      expect(namesOf(result), ['寿司次郎']);
    });

    test('キーワードは大文字小文字を区別しない', () {
      final result = run(
        [place('Cafe Lumine'), place('らーめん太郎')],
        const PlaceSearchOptions(keyword: 'cafe'),
      );
      expect(namesOf(result), ['Cafe Lumine']);
    });

    test('絞り込みと並べ替えは同時に効く', () {
      final result = run([
        place('高評価だが高い', rating: 4.8, priceLevel: 4),
        place('安くて高評価', rating: 4.5, priceLevel: 1),
        place('安いが低評価', rating: 3.0, priceLevel: 1),
      ], const PlaceSearchOptions(
        maxPriceLevel: 2,
        minRating: 4.0,
        sort: PlaceSortOrder.rating,
      ));
      expect(namesOf(result), ['安くて高評価']);
    });
  });

  group('PlaceSearchOptions', () {
    test('既定では絞り込んでいない', () {
      expect(const PlaceSearchOptions().hasNarrowing, isFalse);
    });

    test('並び順と範囲だけを変えても絞り込みとは見なさない', () {
      const o = PlaceSearchOptions(
        radiusMeters: 2000,
        sort: PlaceSortOrder.rating,
      );
      expect(o.hasNarrowing, isFalse);
    });

    test('ジャンル・評価・価格・キーワードは絞り込み扱い', () {
      expect(
        const PlaceSearchOptions(category: PlaceCategory.ramen).hasNarrowing,
        isTrue,
      );
      expect(const PlaceSearchOptions(minRating: 4).hasNarrowing, isTrue);
      expect(const PlaceSearchOptions(maxPriceLevel: 2).hasNarrowing, isTrue);
      expect(const PlaceSearchOptions(keyword: '寿司').hasNarrowing, isTrue);
    });

    test('clearするとnullに戻る', () {
      const o = PlaceSearchOptions(minRating: 4, keyword: '寿司');
      final cleared = o.copyWith(clearMinRating: true, clearKeyword: true);
      expect(cleared.minRating, isNull);
      expect(cleared.keyword, isNull);
    });

    test('距離順だけがAPIのDISTANCEになる', () {
      expect(PlaceSortOrder.distance.rankPreference, 'DISTANCE');
      for (final s in PlaceSortOrder.values.where((s) => s != PlaceSortOrder.distance)) {
        expect(s.rankPreference, 'POPULARITY', reason: s.name);
      }
    });
  });

  group('価格表示', () {
    test('価格帯の数だけ¥を並べる', () {
      expect(place('a', priceLevel: 2).priceLabel, '¥¥');
      expect(place('a', priceLevel: 4).priceLabel, '¥¥¥¥');
    });

    test('不明・無料は出さない', () {
      expect(place('a').priceLabel, isNull);
      expect(place('a', priceLevel: 0).priceLabel, isNull);
    });
  });
}
