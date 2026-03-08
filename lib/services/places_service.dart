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
          'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount,places.types,places.photos',
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
