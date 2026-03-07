class MealPhoto {
  final String id;
  final String mealLogId;
  final String localPath;
  final String? originalUrl;
  final String? thumbnailUrl;
  final String aiStatus; // pending / processing / completed / failed
  final String? aiMenuName;
  final int? aiEstimatedPrice;
  final int? aiEstimatedCalories;
  final String? aiCuisineGenre;
  final String? userCorrectedName;
  final int? userCorrectedPrice;
  final int? userCorrectedCalories;
  final String uploadStatus; // pending / uploaded
  final DateTime shotAt;
  final double? latitude;
  final double? longitude;
  final DateTime createdAt;

  const MealPhoto({
    required this.id,
    required this.mealLogId,
    required this.localPath,
    this.originalUrl,
    this.thumbnailUrl,
    this.aiStatus = 'pending',
    this.aiMenuName,
    this.aiEstimatedPrice,
    this.aiEstimatedCalories,
    this.aiCuisineGenre,
    this.userCorrectedName,
    this.userCorrectedPrice,
    this.userCorrectedCalories,
    this.uploadStatus = 'pending',
    required this.shotAt,
    this.latitude,
    this.longitude,
    required this.createdAt,
  });

  /// 表示用のメニュー名（ユーザー修正値を優先）
  String? get displayName => userCorrectedName ?? aiMenuName;

  /// 表示用の価格（ユーザー修正値を優先）
  int? get displayPrice => userCorrectedPrice ?? aiEstimatedPrice;

  /// 表示用のカロリー（ユーザー修正値を優先）
  int? get displayCalories => userCorrectedCalories ?? aiEstimatedCalories;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'meal_log_id': mealLogId,
      'local_path': localPath,
      'original_url': originalUrl,
      'thumbnail_url': thumbnailUrl,
      'ai_status': aiStatus,
      'ai_menu_name': aiMenuName,
      'ai_estimated_price': aiEstimatedPrice,
      'ai_estimated_calories': aiEstimatedCalories,
      'ai_cuisine_genre': aiCuisineGenre,
      'user_corrected_name': userCorrectedName,
      'user_corrected_price': userCorrectedPrice,
      'user_corrected_calories': userCorrectedCalories,
      'upload_status': uploadStatus,
      'shot_at': shotAt.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory MealPhoto.fromMap(Map<String, dynamic> map) {
    return MealPhoto(
      id: map['id'] as String,
      mealLogId: map['meal_log_id'] as String,
      localPath: map['local_path'] as String,
      originalUrl: map['original_url'] as String?,
      thumbnailUrl: map['thumbnail_url'] as String?,
      aiStatus: map['ai_status'] as String? ?? 'pending',
      aiMenuName: map['ai_menu_name'] as String?,
      aiEstimatedPrice: map['ai_estimated_price'] as int?,
      aiEstimatedCalories: map['ai_estimated_calories'] as int?,
      aiCuisineGenre: map['ai_cuisine_genre'] as String?,
      userCorrectedName: map['user_corrected_name'] as String?,
      userCorrectedPrice: map['user_corrected_price'] as int?,
      userCorrectedCalories: map['user_corrected_calories'] as int?,
      uploadStatus: map['upload_status'] as String? ?? 'pending',
      shotAt: DateTime.parse(map['shot_at'] as String),
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  MealPhoto copyWith({
    String? originalUrl,
    String? thumbnailUrl,
    String? aiStatus,
    String? aiMenuName,
    int? aiEstimatedPrice,
    int? aiEstimatedCalories,
    String? aiCuisineGenre,
    String? userCorrectedName,
    int? userCorrectedPrice,
    int? userCorrectedCalories,
    String? uploadStatus,
  }) {
    return MealPhoto(
      id: id,
      mealLogId: mealLogId,
      localPath: localPath,
      originalUrl: originalUrl ?? this.originalUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      aiStatus: aiStatus ?? this.aiStatus,
      aiMenuName: aiMenuName ?? this.aiMenuName,
      aiEstimatedPrice: aiEstimatedPrice ?? this.aiEstimatedPrice,
      aiEstimatedCalories: aiEstimatedCalories ?? this.aiEstimatedCalories,
      aiCuisineGenre: aiCuisineGenre ?? this.aiCuisineGenre,
      userCorrectedName: userCorrectedName ?? this.userCorrectedName,
      userCorrectedPrice: userCorrectedPrice ?? this.userCorrectedPrice,
      userCorrectedCalories: userCorrectedCalories ?? this.userCorrectedCalories,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      shotAt: shotAt,
      latitude: latitude,
      longitude: longitude,
      createdAt: createdAt,
    );
  }
}
