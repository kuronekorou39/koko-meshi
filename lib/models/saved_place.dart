/// ユーザーが登録するカスタム場所（自宅、友人宅など）
class SavedPlace {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String iconType; // home / friend / custom
  final DateTime createdAt;

  const SavedPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.iconType = 'custom',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'icon_type': iconType,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory SavedPlace.fromMap(Map<String, dynamic> map) {
    return SavedPlace(
      id: map['id'] as String,
      name: map['name'] as String,
      latitude: map['latitude'] as double,
      longitude: map['longitude'] as double,
      iconType: map['icon_type'] as String? ?? 'custom',
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
