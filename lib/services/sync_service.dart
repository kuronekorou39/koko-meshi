import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../services/app_settings_service.dart';
import '../services/auth_service.dart';
import '../services/photo_service.dart';

class SyncService {
  SyncService._();

  static bool get _isReady =>
      AuthService.isSupabaseConfigured && AuthService.isLoggedIn;

  static SupabaseClient get _client => Supabase.instance.client;

  /// 未同期のデータをすべてクラウドに同期
  static Future<SyncResult> syncAll() async {
    if (!_isReady) return SyncResult.notLoggedIn();

    int synced = 0;
    int failed = 0;
    final errors = <String>[];

    // 1. 食事記録を同期
    final logs = await LocalDatabase.getMealLogs();
    final pendingLogs = logs.where((l) => l.syncStatus == 'pending').toList();

    for (final log in pendingLogs) {
      try {
        await _syncMealLog(log);
        synced++;
      } catch (e) {
        failed++;
        errors.add('MealLog ${log.id}: $e');
        debugPrint('[Sync] Failed to sync meal log: $e');
      }
    }

    // 2. 写真をアップロード
    final pendingPhotos = await LocalDatabase.getPendingUploadPhotos();
    for (final photo in pendingPhotos) {
      try {
        await _uploadPhoto(photo);
        synced++;
      } catch (e) {
        failed++;
        errors.add('Photo ${photo.id}: $e');
        debugPrint('[Sync] Failed to upload photo: $e');
      }
    }

    debugPrint('[Sync] Completed: synced=$synced, failed=$failed');
    return SyncResult(synced: synced, failed: failed, errors: errors);
  }

  /// 食事記録をSupabaseにアップサート
  static Future<void> _syncMealLog(MealLog log) async {
    final userId = AuthService.currentUser!.id;

    await _client.from('meal_logs').upsert({
      'id': log.id,
      'user_id': userId,
      'meal_type': log.mealType.value,
      'restaurant_id': log.restaurantId,
      'eaten_at': log.eatenAt.toIso8601String(),
      'total_price': log.totalPrice,
      'note': log.note,
      'location_tag': log.locationTag,
      'latitude': log.latitude,
      'longitude': log.longitude,
      'created_at': log.createdAt.toIso8601String(),
    });

    // ローカルDBのsync_statusを更新
    final updated = log.copyWith(syncStatus: 'synced');
    await LocalDatabase.updateMealLog(updated);

    // 紐づく写真のメタデータも同期
    final photos = await LocalDatabase.getPhotosForMealLog(log.id);
    for (final photo in photos) {
      await _syncPhotoMetadata(photo, userId);
    }
  }

  /// 写真メタデータをSupabaseに同期
  static Future<void> _syncPhotoMetadata(MealPhoto photo, String userId) async {
    await _client.from('meal_photos').upsert({
      'id': photo.id,
      'meal_log_id': photo.mealLogId,
      'user_id': userId,
      'original_url': photo.originalUrl,
      'thumbnail_url': photo.thumbnailUrl,
      'ai_status': photo.aiStatus,
      'ai_menu_name': photo.aiMenuName,
      'ai_estimated_price': photo.aiEstimatedPrice,
      'ai_estimated_calories': photo.aiEstimatedCalories,
      'ai_cuisine_genre': photo.aiCuisineGenre,
      'ai_model': photo.aiModel,
      'user_corrected_name': photo.userCorrectedName,
      'user_corrected_price': photo.userCorrectedPrice,
      'user_corrected_calories': photo.userCorrectedCalories,
      'shot_at': photo.shotAt.toIso8601String(),
      'latitude': photo.latitude,
      'longitude': photo.longitude,
      'created_at': photo.createdAt.toIso8601String(),
    });
  }

  /// 写真ファイルをSupabase Storageにアップロード
  static Future<void> _uploadPhoto(MealPhoto photo) async {
    final userId = AuthService.currentUser!.id;
    final file = File(photo.localPath);
    if (!file.existsSync()) {
      debugPrint('[Sync] Photo file not found: ${photo.localPath}');
      return;
    }

    final ext = p.extension(photo.localPath);
    final storagePath = '$userId/${photo.mealLogId}/${photo.id}$ext';

    // オリジナル写真をアップロード
    await _client.storage.from('meal-photos').upload(
      storagePath,
      file,
      fileOptions: const FileOptions(upsert: true),
    );

    // 公開URLを取得
    final publicUrl = _client.storage
        .from('meal-photos')
        .getPublicUrl(storagePath);

    // ローカルDBを更新
    final updated = photo.copyWith(
      originalUrl: publicUrl,
      uploadStatus: 'uploaded',
    );
    await LocalDatabase.updateMealPhoto(updated);

    // Supabase DBの写真メタデータも更新
    await _syncPhotoMetadata(updated, userId);

    // 設定が有効なら、ローカルのオリジナルを削除（サムネは残す）
    if (AppSettings.deleteAfterUpload) {
      await PhotoService.deleteOriginal(photo.localPath);
    }
  }

  /// 保存場所を同期
  static Future<void> syncSavedPlaces() async {
    if (!_isReady) return;
    final userId = AuthService.currentUser!.id;

    final places = await LocalDatabase.getSavedPlaces();
    for (final place in places) {
      try {
        await _client.from('saved_places').upsert({
          'id': place.id,
          'user_id': userId,
          'name': place.name,
          'latitude': place.latitude,
          'longitude': place.longitude,
          'icon_type': place.iconType,
          'created_at': place.createdAt.toIso8601String(),
        });
      } catch (e) {
        debugPrint('[Sync] Failed to sync saved place: $e');
      }
    }
  }

  /// クラウドからローカルにデータをプル（別端末でのデータを取得）
  static Future<int> pullFromCloud() async {
    if (!_isReady) return 0;
    final userId = AuthService.currentUser!.id;
    int pulled = 0;

    // クラウドの食事記録を取得
    final cloudLogs = await _client
        .from('meal_logs')
        .select()
        .eq('user_id', userId)
        .order('eaten_at', ascending: false);

    for (final data in cloudLogs) {
      final localLog = await LocalDatabase.getMealLog(data['id'] as String);
      if (localLog == null) {
        // ローカルにない場合、挿入（写真のlocalPathはなし）
        final log = MealLog.fromMap({
          ...data,
          'sync_status': 'synced',
        });
        await LocalDatabase.insertMealLog(log);
        pulled++;
      }
    }

    return pulled;
  }
}

class SyncResult {
  final int synced;
  final int failed;
  final List<String> errors;
  final bool loggedIn;

  SyncResult({
    required this.synced,
    required this.failed,
    this.errors = const [],
    this.loggedIn = true,
  });

  factory SyncResult.notLoggedIn() => SyncResult(
    synced: 0,
    failed: 0,
    loggedIn: false,
  );

  bool get hasErrors => failed > 0;
  int get total => synced + failed;
}
