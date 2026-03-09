import 'meal_type.dart';

class MealLog {
  final String id;
  final String? userId;
  final MealType mealType;
  final String? restaurantId;
  final DateTime eatenAt;
  final int? totalPrice;
  final String? note;
  final String? locationTag; // 'home' / SavedPlace.id / null
  final double? latitude;
  final double? longitude;
  final String syncStatus; // pending / synced
  final DateTime createdAt;

  const MealLog({
    required this.id,
    this.userId,
    required this.mealType,
    this.restaurantId,
    required this.eatenAt,
    this.totalPrice,
    this.note,
    this.locationTag,
    this.latitude,
    this.longitude,
    this.syncStatus = 'pending',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'meal_type': mealType.value,
      'restaurant_id': restaurantId,
      'eaten_at': eatenAt.toIso8601String(),
      'total_price': totalPrice,
      'note': note,
      'location_tag': locationTag,
      'latitude': latitude,
      'longitude': longitude,
      'sync_status': syncStatus,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory MealLog.fromMap(Map<String, dynamic> map) {
    return MealLog(
      id: map['id'] as String,
      userId: map['user_id'] as String?,
      mealType: MealType.fromValue(map['meal_type'] as String),
      restaurantId: map['restaurant_id'] as String?,
      eatenAt: DateTime.parse(map['eaten_at'] as String),
      totalPrice: map['total_price'] as int?,
      note: map['note'] as String?,
      locationTag: map['location_tag'] as String?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      syncStatus: map['sync_status'] as String? ?? 'pending',
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  MealLog copyWith({
    String? userId,
    MealType? mealType,
    String? restaurantId,
    DateTime? eatenAt,
    int? totalPrice,
    String? note,
    String? locationTag,
    double? latitude,
    double? longitude,
    String? syncStatus,
  }) {
    return MealLog(
      id: id,
      userId: userId ?? this.userId,
      mealType: mealType ?? this.mealType,
      restaurantId: restaurantId ?? this.restaurantId,
      eatenAt: eatenAt ?? this.eatenAt,
      totalPrice: totalPrice ?? this.totalPrice,
      note: note ?? this.note,
      locationTag: locationTag ?? this.locationTag,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt,
    );
  }
}
