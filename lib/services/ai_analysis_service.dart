import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_database.dart';
import '../models/meal_photo.dart';
import 'ai_rate_limit_service.dart';

class AiAnalysisResult {
  final String menuName;
  final int estimatedPrice;
  final int estimatedCalories;
  final String cuisineGenre;

  AiAnalysisResult({
    required this.menuName,
    required this.estimatedPrice,
    required this.estimatedCalories,
    required this.cuisineGenre,
  });

  factory AiAnalysisResult.fromJson(Map<String, dynamic> json) {
    return AiAnalysisResult(
      menuName: json['menu_name'] as String? ?? '不明',
      estimatedPrice: (json['estimated_price'] as num?)?.toInt() ?? 0,
      estimatedCalories: (json['estimated_calories'] as num?)?.toInt() ?? 0,
      cuisineGenre: json['cuisine_genre'] as String? ?? '不明',
    );
  }
}

class AiAnalysisService {
  static const _maxImageSize = 1080;

  /// 匿名ユーザーのAI解析上限に達したかどうか
  static bool anonymousLimitReached = false;

  /// pending状態の写真をすべて解析する
  static Future<void> processPendingPhotos() async {
    // Supabase未初期化の場合は実行不可
    try {
      Supabase.instance.client;
    } catch (_) {
      debugPrint('[AI] Supabase not initialized');
      return;
    }

    // 未認証なら匿名認証を自動実行
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser == null) {
      try {
        await auth.signInAnonymously();
        debugPrint('[AI] Signed in anonymously');
      } catch (e) {
        debugPrint('[AI] Anonymous sign-in failed: $e');
        return;
      }
    }

    var photos = await LocalDatabase.getPendingAiPhotos();
    // failed・processing状態の写真もリトライ対象に含める
    final failedPhotos = await LocalDatabase.getFailedAiPhotos();
    final stuckPhotos = await LocalDatabase.getStuckAiPhotos();
    photos = [...photos, ...failedPhotos, ...stuckPhotos];
    if (photos.isEmpty) return;

    debugPrint('[AI] Processing ${photos.length} pending photos via Edge Function');

    for (final photo in photos) {
      final shouldContinue = await _analyzePhoto(photo);
      if (!shouldContinue) break;
    }
  }

  /// 単一の写真を解析する
  /// Returns false if processing should stop (rate limit reached)
  static Future<bool> _analyzePhoto(MealPhoto photo) async {
    final processingPhoto = photo.copyWith(aiStatus: 'processing');
    await LocalDatabase.updateMealPhoto(processingPhoto);

    try {
      debugPrint('[AI] Resizing photo ${photo.id}...');
      final sw = Stopwatch()..start();
      final imageBase64 = await _resizeAndEncode(photo.localPath);
      debugPrint('[AI] Resize done in ${sw.elapsedMilliseconds}ms '
          '(${imageBase64 != null ? "${(imageBase64.length / 1024).round()}KB" : "null"})');
      if (imageBase64 == null) {
        debugPrint('[AI] Resize failed for ${photo.localPath}');
        await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
        return true;
      }

      // コンテキスト情報を組み立て
      String contextInfo = '';
      if (photo.latitude != null && photo.longitude != null) {
        contextInfo += '撮影位置: 緯度${photo.latitude}, 経度${photo.longitude}\n';
      }
      final mealLog = await LocalDatabase.getMealLog(photo.mealLogId);
      final mealTypeLabel = mealLog?.mealType.label ?? '不明';
      contextInfo += '食事種別: $mealTypeLabel';

      // Edge Function呼び出し
      final response = await Supabase.instance.client.functions.invoke(
        'analyze-meal-photo',
        body: {
          'image_base64': imageBase64,
          'context': contextInfo,
        },
      );

      // response.dataはMap or Stringの場合がある
      final rawData = response.data;
      final Map<String, dynamic> data;
      if (rawData is Map<String, dynamic>) {
        data = rawData;
      } else if (rawData is String) {
        debugPrint('[AI] Response is String, decoding JSON...');
        data = jsonDecode(rawData) as Map<String, dynamic>;
      } else {
        debugPrint('[AI] Unexpected response type: ${rawData.runtimeType}');
        await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
        return true;
      }
      final result = AiAnalysisResult.fromJson(data);
      final model = data['model'] as String? ?? 'unknown';

      final updated = photo.copyWith(
        aiStatus: 'completed',
        aiMenuName: result.menuName,
        aiEstimatedPrice: result.estimatedPrice,
        aiEstimatedCalories: result.estimatedCalories,
        aiCuisineGenre: result.cuisineGenre,
        aiModel: model,
      );
      await LocalDatabase.updateMealPhoto(updated);
      await AiRateLimitService.recordUsage();
      debugPrint('[AI] Completed: ${result.menuName} '
          '(${result.estimatedPrice}円, ${result.estimatedCalories}kcal)');
      return true;
    } on FunctionException catch (e) {
      debugPrint('[AI] Edge Function error: ${e.status} ${e.details}');
      if (e.status == 429) {
        // レート制限 or 匿名上限
        dynamic details = e.details;
        if (details is String) {
          try {
            details = jsonDecode(details);
          } catch (_) {}
        }
        if (details is Map && details['error'] == 'anonymous_limit_reached') {
          anonymousLimitReached = true;
          debugPrint('[AI] Anonymous usage limit reached');
        } else {
          debugPrint('[AI] Rate limit exceeded');
        }
        await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'pending'));
        return false; // stop processing
      }
      await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
      return true;
    } catch (e) {
      debugPrint('[AI] Error analyzing photo ${photo.id}: $e');
      await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
      return true;
    }
  }

  // ─── 画像リサイズ ───

  static Future<String?> _resizeAndEncode(String path) async {
    try {
      return await compute(_resizeAndEncodeSync, path);
    } catch (e) {
      debugPrint('[AI] Image resize failed: $e');
      return null;
    }
  }

  static String? _resizeAndEncodeSync(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;

    final bytes = file.readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) return null;

    img.Image resized;
    if (image.width > _maxImageSize || image.height > _maxImageSize) {
      if (image.width >= image.height) {
        resized = img.copyResize(image, width: _maxImageSize);
      } else {
        resized = img.copyResize(image, height: _maxImageSize);
      }
    } else {
      resized = image;
    }

    final jpegBytes = img.encodeJpg(resized, quality: 80);
    return base64Encode(jpegBytes);
  }
}
