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
    this.types = const [],
    this.photoUrl,
  });
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

  /// 周辺のレストラン・飲食店を検索
  static Future<PlacesResult> searchNearbyRestaurants({
    required double latitude,
    required double longitude,
    double radiusMeters = 500,
  }) async {
    return _post(
      path: 'places:searchNearby',
      // 費用対策: rating/userRatingCount/photos を外し Nearby Search を
      // Enterprise(無料1,000/月) → Pro(無料5,000/月・単価も安)ティアに落とす。
      // photos除外で Place Photo課金($7/1,000)も消える。
      // rating/写真はUI側でnull時プレースホルダ表示するため機能破綻なし。
      fieldMask:
          'places.id,places.displayName,places.formattedAddress,places.location,places.types',
      body: {
        'includedTypes': [
          'restaurant',
          'cafe',
          'bar',
          'meal_takeaway',
          'bakery',
          'ramen_restaurant',
          'sushi_restaurant',
          'japanese_restaurant',
          'chinese_restaurant',
          'italian_restaurant',
        ],
        'maxResultCount': 20,
        'languageCode': 'ja',
        'locationRestriction': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': radiusMeters,
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
          types: (p['types'] as List<dynamic>?)?.cast<String>() ?? [],
          photoUrl: photoUrl,
        );
      },
    );
  }
}
