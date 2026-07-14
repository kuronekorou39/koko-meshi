import 'dart:convert';
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

class PlacesService {
  /// 写真URLを生成
  static String _buildPhotoUrl(String photoName) {
    final apiKey = Env.googleMapsApiKey;
    return 'https://places.googleapis.com/v1/$photoName/media?maxWidthPx=200&key=$apiKey';
  }

  /// テキストで場所を検索（住所、施設名など）
  static Future<List<PlaceInfo>> searchByText(String query) async {
    final apiKey = Env.googleMapsApiKey;
    if (apiKey.isEmpty || query.trim().isEmpty) return [];

    final url = Uri.parse('https://places.googleapis.com/v1/places:searchText');

    final body = jsonEncode({
      'textQuery': query,
      'languageCode': 'ja',
      'maxResultCount': 10,
    });

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'places.id,places.displayName,places.formattedAddress,places.location',
        },
        body: body,
      );

      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      final places = data['places'] as List<dynamic>? ?? [];

      return places.map((p) {
        final location = p['location'] as Map<String, dynamic>;
        final displayName = p['displayName'] as Map<String, dynamic>?;
        return PlaceInfo(
          id: p['id'] as String,
          name: displayName?['text'] as String? ?? '不明',
          address: p['formattedAddress'] as String?,
          latitude: (location['latitude'] as num).toDouble(),
          longitude: (location['longitude'] as num).toDouble(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// 周辺のレストラン・飲食店を検索
  static Future<List<PlaceInfo>> searchNearbyRestaurants({
    required double latitude,
    required double longitude,
    double radiusMeters = 500,
  }) async {
    final apiKey = Env.googleMapsApiKey;
    if (apiKey.isEmpty) return [];

    final url = Uri.parse('https://places.googleapis.com/v1/places:searchNearby');

    final body = jsonEncode({
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
          'center': {
            'latitude': latitude,
            'longitude': longitude,
          },
          'radius': radiusMeters,
        },
      },
    });

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          // 費用対策: rating/userRatingCount/photos を外し Nearby Search を
          // Enterprise(無料1,000/月) → Pro(無料5,000/月・単価も安)ティアに落とす。
          // photos除外で Place Photo課金($7/1,000)も消える。
          // rating/写真はUI側でnull時プレースホルダ表示するため機能破綻なし。
          'X-Goog-FieldMask':
              'places.id,places.displayName,places.formattedAddress,places.location,places.types',
        },
        body: body,
      );

      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      final places = data['places'] as List<dynamic>? ?? [];

      return places.map((p) {
        final location = p['location'] as Map<String, dynamic>;
        final displayName = p['displayName'] as Map<String, dynamic>?;

        // 最初の写真のURLを取得
        String? photoUrl;
        final photos = p['photos'] as List<dynamic>?;
        if (photos != null && photos.isNotEmpty) {
          final photoName = photos[0]['name'] as String?;
          if (photoName != null) {
            photoUrl = _buildPhotoUrl(photoName);
          }
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
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
