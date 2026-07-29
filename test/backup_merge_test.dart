import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 復元は取り返しのつかないデータを扱うので、「消さない」ことを実DBで確かめる。
///
/// マージは行のマップをそのまま入れ直す作りなので、本物のスキーマ全部は要らない。
/// 主キーとパス列だけ持つ最小のテーブルで意味を確かめる。
const _schema = [
  'CREATE TABLE restaurants (id TEXT PRIMARY KEY, name TEXT)',
  'CREATE TABLE meal_logs (id TEXT PRIMARY KEY, note TEXT)',
  '''CREATE TABLE meal_photos (
       id TEXT PRIMARY KEY,
       meal_log_id TEXT,
       local_path TEXT,
       original_local_path TEXT,
       thumbnail_url TEXT
     )''',
  'CREATE TABLE saved_places (id TEXT PRIMARY KEY, name TEXT)',
  'CREATE TABLE diet_advices (id TEXT PRIMARY KEY, body TEXT)',
];

Future<Database> newDb() async {
  // singleInstance を切らないと、:memory: を開いた2つが同じDBを指してしまう
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  for (final sql in _schema) {
    await db.execute(sql);
  }
  return db;
}

Future<List<String>> idsOf(Database db, String table) async {
  final rows = await db.query(table, orderBy: 'id');
  return rows.map((r) => r['id'] as String).toList();
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database target; // この端末
  late Database source; // バックアップ

  setUp(() async {
    target = await newDb();
    source = await newDb();
  });

  tearDown(() async {
    await target.close();
    await source.close();
  });

  Future<int> merge({String oldBase = '/old', String newBase = '/new'}) =>
      BackupService.mergeInto(
        target: target,
        source: source,
        oldBase: oldBase,
        newBase: newBase,
      );

  group('既存を消さない', () {
    test('この端末にしか無い記録は残る', () async {
      await target.insert('meal_logs', {'id': 'mine', 'note': '手元'});
      await source.insert('meal_logs', {'id': 'backup', 'note': '控え'});

      final added = await merge();

      expect(added, 1);
      expect(await idsOf(target, 'meal_logs'), ['backup', 'mine']);
    });

    test('同じidがあってもこの端末側の内容を上書きしない', () async {
      await target.insert('meal_logs', {'id': 'same', 'note': '編集後'});
      await source.insert('meal_logs', {'id': 'same', 'note': '編集前'});

      final added = await merge();

      expect(added, 0, reason: '既にあるので追加はしない');
      final rows = await target.query('meal_logs');
      expect(rows.single['note'], '編集後', reason: '手元の編集が残る');
    });

    test('自分のバックアップを入れ直しても何も起きない(冪等)', () async {
      await target.insert('meal_logs', {'id': 'a', 'note': 'A'});
      await target.insert('meal_logs', {'id': 'b', 'note': 'B'});
      await source.insert('meal_logs', {'id': 'a', 'note': 'A'});
      await source.insert('meal_logs', {'id': 'b', 'note': 'B'});

      expect(await merge(), 0);
      expect(await idsOf(target, 'meal_logs'), ['a', 'b']);

      // 二度流しても増えない
      expect(await merge(), 0);
      expect(await idsOf(target, 'meal_logs'), ['a', 'b']);
    });

    test('空のバックアップを入れても記録は消えない', () async {
      await target.insert('meal_logs', {'id': 'mine', 'note': '手元'});

      expect(await merge(), 0);
      expect(await idsOf(target, 'meal_logs'), ['mine']);
    });
  });

  group('足りないものを足す', () {
    test('空の端末にはバックアップの内容がそのまま入る', () async {
      await source.insert('restaurants', {'id': 'r1', 'name': '店'});
      await source.insert('meal_logs', {'id': 'l1', 'note': '記録'});
      await source.insert('meal_photos', {'id': 'p1', 'meal_log_id': 'l1'});
      await source.insert('saved_places', {'id': 's1', 'name': '自宅'});
      await source.insert('diet_advices', {'id': 'd1', 'body': '助言'});

      expect(await merge(), 1);
      expect(await idsOf(target, 'restaurants'), ['r1']);
      expect(await idsOf(target, 'meal_logs'), ['l1']);
      expect(await idsOf(target, 'meal_photos'), ['p1']);
      expect(await idsOf(target, 'saved_places'), ['s1']);
      expect(await idsOf(target, 'diet_advices'), ['d1']);
    });

    test('返り値は追加した食事記録の件数だけを数える', () async {
      await source.insert('meal_logs', {'id': 'l1'});
      await source.insert('meal_logs', {'id': 'l2'});
      await source.insert('saved_places', {'id': 's1', 'name': '自宅'});
      await target.insert('meal_logs', {'id': 'l1'});

      expect(await merge(), 1, reason: 'l2 のみ追加');
    });
  });

  group('写真のパス', () {
    test('追加する行のパスはこの端末のベースへ読み替える', () async {
      await source.insert('meal_photos', {
        'id': 'p1',
        'meal_log_id': 'l1',
        'local_path': '/old/photos/a.jpg',
        'original_local_path': '/old/photos/a_orig.jpg',
        'thumbnail_url': '/old/thumbnails/a.jpg',
      });

      await merge();

      final row = (await target.query('meal_photos')).single;
      expect(row['local_path'], '/new/photos/a.jpg');
      expect(row['original_local_path'], '/new/photos/a_orig.jpg');
      expect(row['thumbnail_url'], '/new/thumbnails/a.jpg');
    });

    test('既にある行のパスは書き換えない', () async {
      await target.insert('meal_photos', {
        'id': 'p1',
        'local_path': '/new/photos/keep.jpg',
      });
      await source.insert('meal_photos', {
        'id': 'p1',
        'local_path': '/old/photos/other.jpg',
      });

      await merge();

      final row = (await target.query('meal_photos')).single;
      expect(row['local_path'], '/new/photos/keep.jpg');
    });

    test('パスがnullでも落ちない', () async {
      await source.insert('meal_photos', {'id': 'p1', 'local_path': null});

      await merge();

      expect((await target.query('meal_photos')).single['local_path'], isNull);
    });
  });

  test('バックアップに無いテーブルがあっても止まらない', () async {
    await source.execute('DROP TABLE diet_advices');
    await source.insert('meal_logs', {'id': 'l1'});

    expect(await merge(), 1);
    expect(await idsOf(target, 'meal_logs'), ['l1']);
  });
}
