import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../config/env.dart';
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
  static bool _lastWasRateLimit = false;

  static String get _prompt => '''この料理写真を分析して、以下の情報をJSON形式で返してください。

必ず以下のJSON形式のみで回答してください（説明文は不要）:
{
  "menu_name": "メニュー名（日本語）",
  "estimated_price": 数値（円、整数）,
  "estimated_calories": 数値（kcal、整数）,
  "cuisine_genre": "料理ジャンル（例: ラーメン、寿司、カフェ、中華、イタリアン等）"
}

注意:
- menu_nameは具体的な料理名を推定してください（例: 「味噌ラーメン」「カルボナーラ」）
- 複数の料理が写っている場合はメインの料理名を記載してください
- 価格は日本の一般的な相場から推定してください
- カロリーは一般的な1人前の量から推定してください''';

  /// pending状態の写真をすべて解析する
  static Future<void> processPendingPhotos() async {
    final provider = Env.aiProvider;
    final modelName = provider == 'claude' ? 'claude-haiku-4-5' : 'gemini-2.5-flash';
    final apiKey = provider == 'claude' ? Env.claudeApiKey : Env.geminiApiKey;

    if (apiKey.isEmpty) {
      debugPrint('[AI] $provider API key not configured');
      return;
    }

    var photos = await LocalDatabase.getPendingAiPhotos();
    // failed状態の写真もリトライ対象に含める
    final failedPhotos = await LocalDatabase.getFailedAiPhotos();
    photos = [...photos, ...failedPhotos];
    if (photos.isEmpty) return;

    debugPrint('[AI] Processing ${photos.length} pending photos (provider: $provider)');

    for (final photo in photos) {
      // レート制限チェック
      final canUse = await AiRateLimitService.canAnalyze();
      if (!canUse) {
        debugPrint('[AI] Rate limit exceeded, stopping analysis');
        break;
      }

      await _analyzePhoto(photo, apiKey, provider, modelName);
    }
  }

  /// 単一の写真を解析する
  static Future<void> _analyzePhoto(MealPhoto photo, String apiKey, String provider, String modelName) async {
    final processingPhoto = photo.copyWith(aiStatus: 'processing');
    await LocalDatabase.updateMealPhoto(processingPhoto);

    try {
      debugPrint('[AI] Resizing photo ${photo.id}...');
      final sw = Stopwatch()..start();
      final imageBase64 = await _resizeAndEncode(photo.localPath);
      debugPrint('[AI] Resize done in ${sw.elapsedMilliseconds}ms (${imageBase64 != null ? "${(imageBase64.length / 1024).round()}KB" : "null"})');
      if (imageBase64 == null) {
        debugPrint('[AI] Resize failed for ${photo.localPath}');
        await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
        return;
      }

      // コンテキスト情報を組み立て
      String contextInfo = '';
      if (photo.latitude != null && photo.longitude != null) {
        contextInfo += '撮影位置: 緯度${photo.latitude}, 経度${photo.longitude}\n';
      }
      final mealLog = await LocalDatabase.getMealLog(photo.mealLogId);
      final mealTypeLabel = mealLog?.mealType.label ?? '不明';
      contextInfo += '食事種別: $mealTypeLabel';

      final fullPrompt = '$contextInfo\n\n$_prompt';

      // プロバイダーに応じてAPI呼び出し（429時はリトライ）
      AiAnalysisResult? result;
      for (int attempt = 0; attempt < 3; attempt++) {
        if (provider == 'claude') {
          result = await _callClaude(imageBase64, fullPrompt, apiKey);
        } else {
          result = await _callGemini(imageBase64, fullPrompt, apiKey);
        }
        if (result != null || !_lastWasRateLimit) break;
        debugPrint('[AI] Rate limited, retrying in ${(attempt + 1) * 10}s...');
        await Future.delayed(Duration(seconds: (attempt + 1) * 10));
      }

      if (result != null) {
        final updated = photo.copyWith(
          aiStatus: 'completed',
          aiMenuName: result.menuName,
          aiEstimatedPrice: result.estimatedPrice,
          aiEstimatedCalories: result.estimatedCalories,
          aiCuisineGenre: result.cuisineGenre,
          aiModel: modelName,
        );
        await LocalDatabase.updateMealPhoto(updated);
        await AiRateLimitService.recordUsage();
        debugPrint('[AI] Completed: ${result.menuName} (${result.estimatedPrice}円, ${result.estimatedCalories}kcal)');
      } else {
        await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
      }
    } catch (e) {
      debugPrint('[AI] Error analyzing photo ${photo.id}: $e');
      await LocalDatabase.updateMealPhoto(photo.copyWith(aiStatus: 'failed'));
    }
  }

  // ─── Gemini Flash ───

  static Future<AiAnalysisResult?> _callGemini(
    String imageBase64,
    String prompt,
    String apiKey,
  ) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey';

    try {
      debugPrint('[AI] Calling Gemini API...');
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'inlineData': {
                    'mimeType': 'image/jpeg',
                    'data': imageBase64,
                  },
                },
                {
                  'text': prompt,
                },
              ],
            },
          ],
          'generationConfig': {
            'maxOutputTokens': 1024,
          },
        }),
      );

      _lastWasRateLimit = response.statusCode == 429;
      debugPrint('[AI] Gemini response: ${response.statusCode}');

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final candidates = body['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) {
          debugPrint('[AI] No candidates in response');
          return null;
        }

        final parts = candidates.first['content']?['parts'] as List?;
        if (parts == null || parts.isEmpty) {
          debugPrint('[AI] No parts in response');
          return null;
        }

        // Gemini 2.5はthinking partsを含む場合がある。textパートを探す
        String? text;
        for (final part in parts) {
          if (part['text'] != null && part['thought'] != true) {
            text = part['text'] as String;
            break;
          }
        }
        // fallback: 最後のtextパートを使用
        text ??= parts.lastWhere(
          (p) => p['text'] != null,
          orElse: () => {'text': ''},
        )['text'] as String? ?? '';

        debugPrint('[AI] Response text: ${text.length > 200 ? text.substring(0, 200) : text}');
        final jsonStr = _extractJson(text);
        if (jsonStr == null) {
          debugPrint('[AI] Failed to extract JSON from response');
          return null;
        }

        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        return AiAnalysisResult.fromJson(json);
      } else {
        debugPrint('[AI] Gemini API error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[AI] Gemini API call failed: $e');
      return null;
    }
  }

  // ─── Claude Haiku ───

  static Future<AiAnalysisResult?> _callClaude(
    String imageBase64,
    String prompt,
    String apiKey,
  ) async {
    const apiUrl = 'https://api.anthropic.com/v1/messages';
    const model = 'claude-haiku-4-5-20251001';

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: jsonEncode({
          'model': model,
          'max_tokens': 256,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/jpeg',
                    'data': imageBase64,
                  },
                },
                {
                  'type': 'text',
                  'text': prompt,
                },
              ],
            },
          ],
        }),
      );

      _lastWasRateLimit = response.statusCode == 429;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final content = body['content'] as List;
        if (content.isEmpty) return null;

        final text = content.first['text'] as String;
        final jsonStr = _extractJson(text);
        if (jsonStr == null) return null;

        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        return AiAnalysisResult.fromJson(json);
      } else {
        debugPrint('[AI] Claude API error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[AI] Claude API call failed: $e');
      return null;
    }
  }

  // ─── 共通ユーティリティ ───

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

  static String? _extractJson(String text) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final fencedMatch = fenced.firstMatch(text);
    if (fencedMatch != null) return fencedMatch.group(1)?.trim();

    final braces = RegExp(r'\{[\s\S]*\}');
    final bracesMatch = braces.firstMatch(text);
    if (bracesMatch != null) return bracesMatch.group(0);

    return null;
  }
}
