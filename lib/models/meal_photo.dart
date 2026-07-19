class MealPhoto {
  final String id;
  final String mealLogId;
  final String localPath;
  final String? originalLocalPath; // 編集前のオリジナル画像パス
  final String? originalUrl;
  final String? thumbnailUrl;
  final String aiStatus; // pending / processing / completed / failed
  final String? aiError; // 解析失敗の理由(failed時のみ。表示用)
  final String? aiMenuName;
  final int? aiEstimatedPrice;
  final int? aiEstimatedCalories;
  final String? aiCuisineGenre;
  final String? aiModel; // 解析に使用したAIモデル名
  final String? userCorrectedName;
  final int? userCorrectedPrice;
  final int? userCorrectedCalories;
  final String? aiHint; // 再解析時にユーザーが与える料理特定のキーワード(ローカル専用)
  final String uploadStatus; // pending / uploaded
  final bool skipAi; // AI解析をスキップ（顔写真など）
  final String? editParamsJson; // 切り抜き編集パラメータ（JSON）
  final DateTime shotAt;
  final double? latitude;
  final double? longitude;
  final DateTime createdAt;

  const MealPhoto({
    required this.id,
    required this.mealLogId,
    required this.localPath,
    this.originalLocalPath,
    this.originalUrl,
    this.thumbnailUrl,
    this.aiStatus = 'pending',
    this.aiError,
    this.aiMenuName,
    this.aiEstimatedPrice,
    this.aiEstimatedCalories,
    this.aiCuisineGenre,
    this.aiModel,
    this.userCorrectedName,
    this.userCorrectedPrice,
    this.userCorrectedCalories,
    this.aiHint,
    this.uploadStatus = 'pending',
    this.skipAi = false,
    this.editParamsJson,
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
      'original_local_path': originalLocalPath,
      'original_url': originalUrl,
      'thumbnail_url': thumbnailUrl,
      'ai_status': aiStatus,
      'ai_error': aiError,
      'ai_menu_name': aiMenuName,
      'ai_estimated_price': aiEstimatedPrice,
      'ai_estimated_calories': aiEstimatedCalories,
      'ai_cuisine_genre': aiCuisineGenre,
      'ai_model': aiModel,
      'user_corrected_name': userCorrectedName,
      'user_corrected_price': userCorrectedPrice,
      'user_corrected_calories': userCorrectedCalories,
      'ai_hint': aiHint,
      'upload_status': uploadStatus,
      'skip_ai': skipAi ? 1 : 0,
      'edit_params': editParamsJson,
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
      originalLocalPath: map['original_local_path'] as String?,
      originalUrl: map['original_url'] as String?,
      thumbnailUrl: map['thumbnail_url'] as String?,
      aiStatus: map['ai_status'] as String? ?? 'pending',
      aiError: map['ai_error'] as String?,
      aiMenuName: map['ai_menu_name'] as String?,
      aiEstimatedPrice: map['ai_estimated_price'] as int?,
      aiEstimatedCalories: map['ai_estimated_calories'] as int?,
      aiCuisineGenre: map['ai_cuisine_genre'] as String?,
      aiModel: map['ai_model'] as String?,
      userCorrectedName: map['user_corrected_name'] as String?,
      userCorrectedPrice: map['user_corrected_price'] as int?,
      userCorrectedCalories: map['user_corrected_calories'] as int?,
      aiHint: map['ai_hint'] as String?,
      uploadStatus: map['upload_status'] as String? ?? 'pending',
      skipAi: (map['skip_ai'] as int?) == 1,
      editParamsJson: map['edit_params'] as String?,
      shotAt: DateTime.parse(map['shot_at'] as String),
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  MealPhoto copyWith({
    String? localPath,
    String? originalLocalPath,
    String? originalUrl,
    String? thumbnailUrl,
    String? aiStatus,
    String? aiError,
    bool clearAiError = false,
    String? aiMenuName,
    int? aiEstimatedPrice,
    int? aiEstimatedCalories,
    String? aiCuisineGenre,
    String? aiModel,
    String? userCorrectedName,
    int? userCorrectedPrice,
    int? userCorrectedCalories,
    bool clearUserCorrections = false,
    String? aiHint,
    bool clearAiHint = false,
    String? uploadStatus,
    bool? skipAi,
    String? editParamsJson,
    bool clearEditParams = false,
  }) {
    return MealPhoto(
      id: id,
      mealLogId: mealLogId,
      localPath: localPath ?? this.localPath,
      originalLocalPath: originalLocalPath ?? this.originalLocalPath,
      originalUrl: originalUrl ?? this.originalUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      aiStatus: aiStatus ?? this.aiStatus,
      aiError: clearAiError ? null : (aiError ?? this.aiError),
      aiMenuName: aiMenuName ?? this.aiMenuName,
      aiEstimatedPrice: aiEstimatedPrice ?? this.aiEstimatedPrice,
      aiEstimatedCalories: aiEstimatedCalories ?? this.aiEstimatedCalories,
      aiCuisineGenre: aiCuisineGenre ?? this.aiCuisineGenre,
      aiModel: aiModel ?? this.aiModel,
      userCorrectedName:
          clearUserCorrections ? null : (userCorrectedName ?? this.userCorrectedName),
      userCorrectedPrice:
          clearUserCorrections ? null : (userCorrectedPrice ?? this.userCorrectedPrice),
      userCorrectedCalories: clearUserCorrections
          ? null
          : (userCorrectedCalories ?? this.userCorrectedCalories),
      aiHint: clearAiHint ? null : (aiHint ?? this.aiHint),
      uploadStatus: uploadStatus ?? this.uploadStatus,
      skipAi: skipAi ?? this.skipAi,
      editParamsJson: clearEditParams ? null : (editParamsJson ?? this.editParamsJson),
      shotAt: shotAt,
      latitude: latitude,
      longitude: longitude,
      createdAt: createdAt,
    );
  }
}
