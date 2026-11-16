import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/local_database.dart';
import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/restaurant.dart';
import '../models/saved_place.dart';
import '../services/ai_analysis_service.dart';
import '../services/meal_stats.dart';

/// 食事記録一覧
final mealLogsProvider = AsyncNotifierProvider<MealLogsNotifier, List<MealLog>>(
  MealLogsNotifier.new,
);

class MealLogsNotifier extends AsyncNotifier<List<MealLog>> {
  @override
  Future<List<MealLog>> build() async {
    return LocalDatabase.getMealLogs();
  }

  /// 読み直す。読み込み中の状態を挟まない(挟むと一覧がいったん消えて
  /// 作り直され、解析が1枚終わるたびに画面がちらつく)。
  Future<void> refresh() async {
    state = AsyncData(await LocalDatabase.getMealLogs());
  }

  Future<void> addMealLog(MealLog log) async {
    await LocalDatabase.insertMealLog(log);
    await refresh();
  }

  Future<void> deleteMealLog(String id) async {
    await LocalDatabase.deleteMealLog(id);
    await refresh();
  }
}

/// 全記録の写真(記録ID→写真)。
///
/// 一覧やマップは記録ごとに写真を問い合わせず、ここからまとめて受け取る。
/// 1件ずつ読むと、スクロールで現れたカードが写真なしで一度描かれてから
/// 差し替わり、件数が増えるほど遅れが目につく。
final mealPhotosByLogProvider =
    FutureProvider<Map<String, List<MealPhoto>>>((ref) async {
  // 記録が読み直されたら写真も読み直す
  ref.watch(mealLogsProvider);
  // AI解析の結果が書き込まれたときも(「解析中」が結果に切り替わるように)
  void reload() => ref.invalidateSelf();
  AiAnalysisService.resultsVersion.addListener(reload);
  ref.onDispose(
      () => AiAnalysisService.resultsVersion.removeListener(reload));

  return MealStats.groupPhotos(await LocalDatabase.getAllMealPhotos());
});

/// 特定の食事記録の写真一覧
final mealPhotosProvider = FutureProvider.family<List<MealPhoto>, String>(
  (ref, mealLogId) => LocalDatabase.getPhotosForMealLog(mealLogId),
);

/// 特定の食事記録
final mealLogProvider = FutureProvider.family<MealLog?, String>(
  (ref, id) => LocalDatabase.getMealLog(id),
);

/// 特定の店舗
final restaurantProvider = FutureProvider.family<Restaurant?, String>(
  (ref, id) => LocalDatabase.getRestaurant(id),
);

/// 登録済みのマイプレイス(自宅・職場など)
final savedPlacesProvider = FutureProvider<List<SavedPlace>>(
  (ref) => LocalDatabase.getSavedPlaces(),
);
