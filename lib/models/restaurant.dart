class Restaurant {
  final String id;
  final String? googlePlaceId;
  final String name;
  final String? address;
  final double? latitude;
  final double? longitude;
  final String? cuisineGenre;
  final DateTime createdAt;

  const Restaurant({
    required this.id,
    this.googlePlaceId,
    required this.name,
    this.address,
    this.latitude,
    this.longitude,
    this.cuisineGenre,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'google_place_id': googlePlaceId,
      'name': name,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'cuisine_genre': cuisineGenre,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Restaurant.fromMap(Map<String, dynamic> map) {
    return Restaurant(
      id: map['id'] as String,
      googlePlaceId: map['google_place_id'] as String?,
      name: map['name'] as String,
      address: map['address'] as String?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      cuisineGenre: map['cuisine_genre'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
