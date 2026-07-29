import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/local_database.dart';
import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/restaurant.dart';
import '../models/saved_place.dart';

/// 食事記録一覧
final mealLogsProvider = AsyncNotifierProvider<MealLogsNotifier, List<MealLog>>(
  MealLogsNotifier.new,
);

class MealLogsNotifier extends AsyncNotifier<List<MealLog>> {
  @override
  Future<List<MealLog>> build() async {
    return LocalDatabase.getMealLogs();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
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
