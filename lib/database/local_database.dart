import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/restaurant.dart';
import '../models/saved_place.dart';

class LocalDatabase {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'koko_meshi.db');

    return openDatabase(
      path,
      version: 9,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE restaurants (
        id TEXT PRIMARY KEY,
        google_place_id TEXT,
        name TEXT NOT NULL,
        address TEXT,
        latitude REAL,
        longitude REAL,
        cuisine_genre TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE meal_logs (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        meal_type TEXT NOT NULL,
        restaurant_id TEXT,
        eaten_at TEXT NOT NULL,
        total_price INTEGER,
        note TEXT,
        location_tag TEXT,
        latitude REAL,
        longitude REAL,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        FOREIGN KEY (restaurant_id) REFERENCES restaurants(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE meal_photos (
        id TEXT PRIMARY KEY,
        meal_log_id TEXT NOT NULL,
        local_path TEXT NOT NULL,
        original_local_path TEXT,
        original_url TEXT,
        thumbnail_url TEXT,
        ai_status TEXT NOT NULL DEFAULT 'pending',
        ai_menu_name TEXT,
        ai_estimated_price INTEGER,
        ai_estimated_calories INTEGER,
        ai_cuisine_genre TEXT,
        ai_model TEXT,
        user_corrected_name TEXT,
        user_corrected_price INTEGER,
        user_corrected_calories INTEGER,
        upload_status TEXT NOT NULL DEFAULT 'pending',
        skip_ai INTEGER NOT NULL DEFAULT 0,
        edit_params TEXT,
        shot_at TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (meal_log_id) REFERENCES meal_logs(id)
      )
    ''');
    await _createSavedPlacesTable(db);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSavedPlacesTable(db);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE meal_photos ADD COLUMN ai_model TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE meal_logs ADD COLUMN location_tag TEXT');
      await db.execute('ALTER TABLE meal_logs ADD COLUMN latitude REAL');
      await db.execute('ALTER TABLE meal_logs ADD COLUMN longitude REAL');
    }
    // oldVersion < 5: ai_usage_logテーブルを作成していたが、
    // クラウドAI判定の廃止に伴いv9で削除するためno-op化
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE meal_photos ADD COLUMN skip_ai INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE meal_photos ADD COLUMN original_local_path TEXT');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE meal_photos ADD COLUMN edit_params TEXT');
    }
    if (oldVersion < 9) {
      // クラウドAI判定の廃止: レート制限用の使用ログテーブルを撤去
      await db.execute('DROP TABLE IF EXISTS ai_usage_log');
    }
  }

  static Future<void> _createSavedPlacesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_places (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        icon_type TEXT NOT NULL DEFAULT 'custom',
        created_at TEXT NOT NULL
      )
    ''');
  }

  // --- MealLog CRUD ---

  static Future<void> insertMealLog(MealLog log) async {
    final db = await database;
    await db.insert('meal_logs', log.toMap());
  }

  static Future<List<MealLog>> getMealLogs() async {
    final db = await database;
    final maps = await db.query('meal_logs', orderBy: 'eaten_at DESC');
    return maps.map((m) => MealLog.fromMap(m)).toList();
  }

  static Future<MealLog?> getMealLog(String id) async {
    final db = await database;
    final maps = await db.query('meal_logs', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return MealLog.fromMap(maps.first);
  }

  static Future<void> updateMealLog(MealLog log) async {
    final db = await database;
    await db.update('meal_logs', log.toMap(), where: 'id = ?', whereArgs: [log.id]);
  }

  static Future<void> deleteMealLog(String id) async {
    final db = await database;
    await db.delete('meal_photos', where: 'meal_log_id = ?', whereArgs: [id]);
    await db.delete('meal_logs', where: 'id = ?', whereArgs: [id]);
  }

  // --- MealPhoto CRUD ---

  static Future<void> insertMealPhoto(MealPhoto photo) async {
    final db = await database;
    await db.insert('meal_photos', photo.toMap());
  }

  static Future<MealPhoto?> getMealPhoto(String id) async {
    final db = await database;
    final maps = await db.query('meal_photos', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return MealPhoto.fromMap(maps.first);
  }

  static Future<List<MealPhoto>> getPhotosForMealLog(String mealLogId) async {
    final db = await database;
    final maps = await db.query(
      'meal_photos',
      where: 'meal_log_id = ?',
      whereArgs: [mealLogId],
      orderBy: 'shot_at ASC',
    );
    return maps.map((m) => MealPhoto.fromMap(m)).toList();
  }

  static Future<List<MealPhoto>> getPendingAiPhotos() async {
    final db = await database;
    final maps = await db.query(
      'meal_photos',
      where: 'ai_status = ? AND skip_ai = 0',
      whereArgs: ['pending'],
    );
    return maps.map((m) => MealPhoto.fromMap(m)).toList();
  }

  static Future<List<MealPhoto>> getFailedAiPhotos() async {
    final db = await database;
    final maps = await db.query(
      'meal_photos',
      where: 'ai_status = ? AND skip_ai = 0',
      whereArgs: ['failed'],
    );
    return maps.map((m) => MealPhoto.fromMap(m)).toList();
  }

  /// processing状態で止まっている写真を取得（中断されたもの）
  static Future<List<MealPhoto>> getStuckAiPhotos() async {
    final db = await database;
    final maps = await db.query(
      'meal_photos',
      where: 'ai_status = ? AND skip_ai = 0',
      whereArgs: ['processing'],
    );
    return maps.map((m) => MealPhoto.fromMap(m)).toList();
  }

  static Future<List<MealPhoto>> getPendingUploadPhotos() async {
    final db = await database;
    final maps = await db.query(
      'meal_photos',
      where: 'upload_status = ?',
      whereArgs: ['pending'],
    );
    return maps.map((m) => MealPhoto.fromMap(m)).toList();
  }

  static Future<void> updateMealPhoto(MealPhoto photo) async {
    final db = await database;
    await db.update('meal_photos', photo.toMap(), where: 'id = ?', whereArgs: [photo.id]);
  }

  // --- Restaurant CRUD ---

  static Future<void> insertRestaurant(Restaurant restaurant) async {
    final db = await database;
    await db.insert(
      'restaurants',
      restaurant.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<Restaurant?> getRestaurant(String id) async {
    final db = await database;
    final maps = await db.query('restaurants', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Restaurant.fromMap(maps.first);
  }

  static Future<Restaurant?> getRestaurantByPlaceId(String placeId) async {
    final db = await database;
    final maps = await db.query(
      'restaurants',
      where: 'google_place_id = ?',
      whereArgs: [placeId],
    );
    if (maps.isEmpty) return null;
    return Restaurant.fromMap(maps.first);
  }

  // --- SavedPlace CRUD ---

  static Future<void> insertSavedPlace(SavedPlace place) async {
    final db = await database;
    await db.insert('saved_places', place.toMap());
  }

  static Future<List<SavedPlace>> getSavedPlaces() async {
    final db = await database;
    final maps = await db.query('saved_places', orderBy: 'created_at ASC');
    return maps.map((m) => SavedPlace.fromMap(m)).toList();
  }

  static Future<void> deleteSavedPlace(String id) async {
    final db = await database;
    await db.delete('saved_places', where: 'id = ?', whereArgs: [id]);
  }
}
