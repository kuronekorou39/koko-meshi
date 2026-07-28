import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';

class PlaceInfo {
  final String id;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  final double? rating;
  final int? userRatingCount;

  /// 価格帯 0〜4(0=無料, 1=安い … 4=非常に高い)。未提供なら null
  final int? priceLevel;
  final List<String> types;
  final String? photoUrl;

  const PlaceInfo({
    required this.id,
    required this.name,
    this.address,
    required this.latitude,
    required this.longitude,
    this.rating,
    this.userRatingCount,
    this.priceLevel,
    this.types = const [],
    this.photoUrl,
  });

  /// 「¥¥¥」。価格帯が無ければ null
  String? get priceLabel {
    final lv = priceLevel;
    if (lv == null || lv <= 0) return null;
    return '¥' * lv;
  }
}

/// 検索する料理カテゴリ。Places API の `includedTypes` に展開する。
///
/// 具体的な料理名のタイプ(`ramen_restaurant` 等)を持つ店は、たいてい
/// `restaurant` も一緒に付いている。そのため [all] は大分類だけで足りる
/// はずだが、取りこぼしが見つかったらここに足していく。
enum PlaceCategory {
  all('すべて', [
    'restaurant',
    'cafe',
    'bar',
    'bakery',
    'meal_takeaway',
    'meal_delivery',
    'coffee_shop',
    'fast_food_restaurant',
    'ice_cream_shop',
    'sandwich_shop',
  ]),
  japanese('和食', [
    'japanese_restaurant',
    'sushi_restaurant',
    'ramen_restaurant',
    'seafood_restaurant',
  ]),
  ramen('ラーメン', ['ramen_restaurant']),
  sushi('寿司', ['sushi_restaurant']),
  chinese('中華', ['chinese_restaurant']),
  western('洋食', [
    'italian_restaurant',
    'french_restaurant',
    'american_restaurant',
    'spanish_restaurant',
    'mediterranean_restaurant',
    'steak_house',
    'pizza_restaurant',
    'hamburger_restaurant',
  ]),
  asian('アジア', [
    'korean_restaurant',
    'thai_restaurant',
    'indian_restaurant',
    'vietnamese_restaurant',
    'indonesian_restaurant',
  ]),
  cafe('カフェ', ['cafe', 'coffee_shop', 'breakfast_restaurant']),
  bar('バー・居酒屋', ['bar']),
  sweets('パン・甘味', ['bakery', 'ice_cream_shop']),
  takeaway('持ち帰り', ['meal_takeaway', 'meal_delivery', 'fast_food_restaurant']);

  const PlaceCategory(this.label, this.types);

  final String label;
  final List<String> types;
}

/// 結果の並び順。
///
/// APIが受け付けるのは距離順と人気順の2つだけ。評価順・価格順は取得した
/// 20件をこちら側で並べ替える。**全件から上位を選ぶわけではない**ので、
/// 「この辺りで一番評価が高い店」ではなく「取れた20件のうちで高い順」に
/// なる点に注意。
enum PlaceSortOrder {
  distance('近い順'),
  popularity('人気順'),
  rating('評価が高い順'),
  priceAsc('価格が安い順'),
  priceDesc('価格が高い順');

  const PlaceSortOrder(this.label);

  final String label;

  /// APIの rankPreference。距離順以外は人気順で取ってから並べ替える
  String get rankPreference =>
      this == PlaceSortOrder.distance ? 'DISTANCE' : 'POPULARITY';
}

/// 周辺検索の条件。
class PlaceSearchOptions {
  const PlaceSearchOptions({
    this.radiusMeters = 500,
    this.category = PlaceCategory.all,
    this.sort = PlaceSortOrder.distance,
    this.minRating,
    this.maxPriceLevel,
    this.keyword,
  });

  final double radiusMeters;
  final PlaceCategory category;
  final PlaceSortOrder sort;

  /// この評価未満を除く。Nearby Search に評価の下限を渡す口は無いので、
  /// 取得後にこちらで絞る
  final double? minRating;

  /// この価格帯より高い店を除く(1〜4)。取得後にこちらで絞る
  final int? maxPriceLevel;

  /// 店名の部分一致で絞る。取得後にこちらで絞るので追加の課金は発生しない
  final String? keyword;

  bool get hasNarrowing =>
      category != PlaceCategory.all ||
      minRating != null ||
      maxPriceLevel != null ||
      (keyword?.isNotEmpty ?? false);

  PlaceSearchOptions copyWith({
    double? radiusMeters,
    PlaceCategory? category,
    PlaceSortOrder? sort,
    double? minRating,
    int? maxPriceLevel,
    String? keyword,
    bool clearMinRating = false,
    bool clearMaxPriceLevel = false,
    bool clearKeyword = false,
  }) {
    return PlaceSearchOptions(
      radiusMeters: radiusMeters ?? this.radiusMeters,
      category: category ?? this.category,
      sort: sort ?? this.sort,
      minRating: clearMinRating ? null : (minRating ?? this.minRating),
      maxPriceLevel:
          clearMaxPriceLevel ? null : (maxPriceLevel ?? this.maxPriceLevel),
      keyword: clearKeyword ? null : (keyword ?? this.keyword),
    );
  }
}

/// 検索が失敗した理由。
///
/// 「見つからなかった」と「呼べなかった」を同じ0件で返すと、店が無いのか
/// 上限に当たったのか利用者には区別がつかない。理由まで返して画面で伝える。
enum PlacesError {
  /// APIキーが未設定(自分のキーを使う設定にしていない等)
  notConfigured,

  /// 呼び出しの上限に達した(429)
  quota,

  /// キーの制限や課金設定で拒否された(403)。利用者には直せない
  denied,

  /// 通信できない・応答が遅すぎる
  network,

  /// それ以外
  unknown;

  String get message => switch (this) {
    PlacesError.notConfigured => '場所の検索が設定されていません',
    PlacesError.quota => '検索の上限に達しました。時間をおいて試してください',
    PlacesError.denied => 'いま場所の検索を利用できません',
    PlacesError.network => 'ネットワークに接続できませんでした',
    PlacesError.unknown => '場所を検索できませんでした',
  };
}

/// 検索の結果。0件と失敗を区別する。
class PlacesResult {
  const PlacesResult.success(this.places) : error = null;
  const PlacesResult.failure(this.error) : places = const [];

  final List<PlaceInfo> places;
  final PlacesError? error;

  bool get ok => error == null;
}

class PlacesService {
  /// 応答が返らないまま検索中の表示が残り続けないようにする
  static const _timeout = Duration(seconds: 10);

  /// 写真URLを生成
  static String _buildPhotoUrl(String photoName) {
    final apiKey = Env.googlePlacesApiKey;
    return 'https://places.googleapis.com/v1/$photoName/media?maxWidthPx=200&key=$apiKey';
  }

  /// Places API を叩いて places 配列を取り出す。失敗は理由つきで返す。
  static Future<PlacesResult> _post({
    required String path,
    required String fieldMask,
    required Map<String, dynamic> body,
    required PlaceInfo Function(Map<String, dynamic>) parse,
  }) async {
    final apiKey = Env.googlePlacesApiKey;
    if (apiKey.isEmpty) {
      return const PlacesResult.failure(PlacesError.notConfigured);
    }

    try {
      final response = await http
          .post(
            Uri.parse('https://places.googleapis.com/v1/$path'),
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey,
              'X-Goog-FieldMask': fieldMask,
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        // 原因はキーの設定や課金など開発側の話なので、詳細はログにだけ残す
        debugPrint('[Places] $path ${response.statusCode}: ${response.body}');
        return PlacesResult.failure(switch (response.statusCode) {
          429 => PlacesError.quota,
          403 => PlacesError.denied,
          _ => PlacesError.unknown,
        });
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final places = data['places'] as List<dynamic>? ?? [];
      return PlacesResult.success(
        places.map((p) => parse(p as Map<String, dynamic>)).toList(),
      );
    } on TimeoutException {
      return const PlacesResult.failure(PlacesError.network);
    } on SocketException {
      return const PlacesResult.failure(PlacesError.network);
    } catch (e) {
      debugPrint('[Places] $path failed: $e');
      return const PlacesResult.failure(PlacesError.unknown);
    }
  }

  /// テキストで場所を検索（住所、施設名など）
  static Future<PlacesResult> searchByText(String query) async {
    if (query.trim().isEmpty) return const PlacesResult.success([]);

    return _post(
      path: 'places:searchText',
      fieldMask:
          'places.id,places.displayName,places.formattedAddress,places.location',
      body: {'textQuery': query, 'languageCode': 'ja', 'maxResultCount': 10},
      parse: (p) {
        final location = p['location'] as Map<String, dynamic>;
        final displayName = p['displayName'] as Map<String, dynamic>?;
        return PlaceInfo(
          id: p['id'] as String,
          name: displayName?['text'] as String? ?? '不明',
          address: p['formattedAddress'] as String?,
          latitude: (location['latitude'] as num).toDouble(),
          longitude: (location['longitude'] as num).toDouble(),
        );
      },
    );
  }

  /// 周辺のレストラン・飲食店を検索する。
  ///
  /// Nearby Search は1回あたり **最大20件** しか返さない(APIの上限)。
  /// 並び順を指定しないと既定は人気順になり、レビューの少ない個人店から
  /// 順にこぼれる。既定を距離順にしているのはそのため。
  ///
  /// 費用について: `rating`/`userRatingCount`/`priceLevel` を要求すると
  /// Pro(無料5,000/月) → Enterprise(無料1,000/月) ティアに上がる。
  /// この機能は開発者の手元でしか動かさない前提なので許容している
  /// ([AppFeatures.placeSearch])。配布時に戻すなら、ここのフィールドを
  /// 削ると Pro に落ちる。
  static Future<PlacesResult> searchNearbyRestaurants({
    required double latitude,
    required double longitude,
    PlaceSearchOptions options = const PlaceSearchOptions(),
  }) async {
    final result = await _post(
      path: 'places:searchNearby',
      fieldMask: 'places.id,places.displayName,places.formattedAddress,'
          'places.location,places.types,places.rating,'
          'places.userRatingCount,places.priceLevel',
      body: {
        'includedTypes': options.category.types,
        'maxResultCount': 20,
        'languageCode': 'ja',
        'rankPreference': options.sort.rankPreference,
        'locationRestriction': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': options.radiusMeters,
          },
        },
      },
      parse: (p) {
        final location = p['location'] as Map<String, dynamic>;
        final displayName = p['displayName'] as Map<String, dynamic>?;

        // 写真はフィールドマスクから外してあるので通常は入らない。
        // マスクを戻したときのために取り出しだけ残す
        String? photoUrl;
        final photos = p['photos'] as List<dynamic>?;
        if (photos != null && photos.isNotEmpty) {
          final photoName = photos[0]['name'] as String?;
          if (photoName != null) photoUrl = _buildPhotoUrl(photoName);
        }

        return PlaceInfo(
          id: p['id'] as String,
          name: displayName?['text'] as String? ?? '不明',
          address: p['formattedAddress'] as String?,
          latitude: (location['latitude'] as num).toDouble(),
          longitude: (location['longitude'] as num).toDouble(),
          rating: (p['rating'] as num?)?.toDouble(),
          userRatingCount: p['userRatingCount'] as int?,
          priceLevel: _parsePriceLevel(p['priceLevel'] as String?),
          types: (p['types'] as List<dynamic>?)?.cast<String>() ?? [],
          photoUrl: photoUrl,
        );
      },
    );

    if (!result.ok) return result;
    return PlacesResult.success(narrowAndSort(
      result.places,
      options,
      centerLat: latitude,
      centerLng: longitude,
    ));
  }

  /// `PRICE_LEVEL_MODERATE` のような列挙文字列を 0〜4 に直す
  static int? _parsePriceLevel(String? raw) => switch (raw) {
        'PRICE_LEVEL_FREE' => 0,
        'PRICE_LEVEL_INEXPENSIVE' => 1,
        'PRICE_LEVEL_MODERATE' => 2,
        'PRICE_LEVEL_EXPENSIVE' => 3,
        'PRICE_LEVEL_VERY_EXPENSIVE' => 4,
        _ => null,
      };

  /// 取得済みの結果を絞り込んで並べ替える。
  ///
  /// APIを叩き直さないので、ここでの絞り込み・並べ替えに追加の課金は無い。
  /// ただし対象は取得できた20件までで、その外にある店は考慮されない。
  static List<PlaceInfo> narrowAndSort(
    List<PlaceInfo> places,
    PlaceSearchOptions options, {
    required double centerLat,
    required double centerLng,
  }) {
    final keyword = options.keyword?.trim().toLowerCase();
    final filtered = places.where((p) {
      if (options.minRating != null &&
          (p.rating == null || p.rating! < options.minRating!)) {
        return false;
      }
      // 価格帯が不明な店は落とさない。Googleに情報が無いだけで、
      // 予算オーバーとは限らないため
      if (options.maxPriceLevel != null &&
          p.priceLevel != null &&
          p.priceLevel! > options.maxPriceLevel!) {
        return false;
      }
      if (keyword != null && keyword.isNotEmpty) {
        final haystack = '${p.name}\n${p.address ?? ''}'.toLowerCase();
        if (!haystack.contains(keyword)) return false;
      }
      return true;
    }).toList();

    // 値が無い店を「良い側」に混ぜないよう、欠損は常に末尾へ送る
    int byMissingLast<T extends Comparable<T>>(T? a, T? b, int Function() cmp) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return cmp();
    }

    switch (options.sort) {
      case PlaceSortOrder.distance:
        filtered.sort((a, b) => _distanceSq(a, centerLat, centerLng)
            .compareTo(_distanceSq(b, centerLat, centerLng)));
      case PlaceSortOrder.popularity:
        break; // APIが人気順で返した並びをそのまま使う
      case PlaceSortOrder.rating:
        filtered.sort((a, b) => byMissingLast(
            a.rating, b.rating, () => b.rating!.compareTo(a.rating!)));
      case PlaceSortOrder.priceAsc:
        filtered.sort((a, b) => byMissingLast(a.priceLevel, b.priceLevel,
            () => a.priceLevel!.compareTo(b.priceLevel!)));
      case PlaceSortOrder.priceDesc:
        filtered.sort((a, b) => byMissingLast(a.priceLevel, b.priceLevel,
            () => b.priceLevel!.compareTo(a.priceLevel!)));
    }
    return filtered;
  }

  /// 並べ替えの比較にしか使わないので、平方のまま(平方根を取らない)扱う
  static double _distanceSq(PlaceInfo p, double lat, double lng) {
    final dLat = p.latitude - lat;
    final dLng = (p.longitude - lng) * 0.81; // 日本付近の経度縮み(cos35°)の目安
    return dLat * dLat + dLng * dLng;
  }
}
