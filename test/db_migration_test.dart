import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// スキーマを変えたときに既存の記録が壊れないことを確かめる。
///
/// マイグレーションは失敗しても静かに壊れる(列が増えないだけでアプリは
/// 起動し、書き込み時に初めて落ちる)ので、ここで先に踏んでおく。
///
/// v12 の meal_photos。v13 で ai_confidence / ai_candidates を足した
const _v12Schema = '''
CREATE TABLE meal_photos (
  id TEXT PRIMARY KEY,
  meal_log_id TEXT NOT NULL,
  local_path TEXT NOT NULL,
  original_local_path TEXT,
  original_url TEXT,
  thumbnail_url TEXT,
  ai_status TEXT NOT NULL DEFAULT 'pending',
  ai_error TEXT,
  ai_menu_name TEXT,
  ai_estimated_price INTEGER,
  ai_estimated_calories INTEGER,
  ai_cuisine_genre TEXT,
  ai_model TEXT,
  user_corrected_name TEXT,
  user_corrected_price INTEGER,
  user_corrected_calories INTEGER,
  ai_hint TEXT,
  ai_advice TEXT,
  upload_status TEXT NOT NULL DEFAULT 'pending',
  skip_ai INTEGER NOT NULL DEFAULT 0,
  edit_params TEXT,
  shot_at TEXT NOT NULL,
  latitude REAL,
  longitude REAL,
  created_at TEXT NOT NULL
)
''';

/// local_database の v13 部分と同じもの。ここがずれたら気づけるように
/// テスト側にも書いておく
const _v13Migration = [
  'ALTER TABLE meal_photos ADD COLUMN ai_confidence TEXT',
  'ALTER TABLE meal_photos ADD COLUMN ai_candidates TEXT',
];

Future<Database> openV12WithData() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute(_v12Schema);
  await db.insert('meal_photos', {
    'id': 'p1',
    'meal_log_id': 'l1',
    'local_path': '/photos/a.jpg',
    'ai_status': 'completed',
    'ai_menu_name': '味噌ラーメン',
    'ai_estimated_calories': 600,
    'user_corrected_name': '家系ラーメン',
    'shot_at': '2026-07-31T12:00:00.000',
    'created_at': '2026-07-31T12:00:00.000',
  });
  return db;
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('v12 の記録は v13 のあとも中身が変わらない', () async {
    final db = await openV12WithData();
    for (final sql in _v13Migration) {
      await db.execute(sql);
    }

    final row = (await db.query('meal_photos')).single;
    expect(row['id'], 'p1');
    expect(row['ai_menu_name'], '味噌ラーメン');
    expect(row['user_corrected_name'], '家系ラーメン', reason: '手修正が残る');
    expect(row['ai_estimated_calories'], 600);
    await db.close();
  });

  test('増えた列は既存行では null(未判定として扱える)', () async {
    final db = await openV12WithData();
    for (final sql in _v13Migration) {
      await db.execute(sql);
    }

    final row = (await db.query('meal_photos')).single;
    expect(row['ai_confidence'], isNull);
    expect(row['ai_candidates'], isNull);
    await db.close();
  });

  test('移行後は新しい列に書き込める', () async {
    final db = await openV12WithData();
    for (final sql in _v13Migration) {
      await db.execute(sql);
    }

    await db.update(
      'meal_photos',
      {'ai_confidence': 'low', 'ai_candidates': '["唐揚げ弁当","唐揚げ定食"]'},
      where: 'id = ?',
      whereArgs: ['p1'],
    );

    final row = (await db.query('meal_photos')).single;
    expect(row['ai_confidence'], 'low');
    expect(row['ai_candidates'], '["唐揚げ弁当","唐揚げ定食"]');
    await db.close();
  });
}
