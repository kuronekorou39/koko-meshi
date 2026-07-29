import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';

/// 復元で何が足されたか。
class RestoreResult {
  const RestoreResult({required this.addedRecords, required this.copiedFiles});

  /// 追加した食事記録の件数(既にあったものは含まない)
  final int addedRecords;

  /// 追加した写真・サムネのファイル数
  final int copiedFiles;

  bool get isEmpty => addedRecords == 0 && copiedFiles == 0;
}

/// バックアップzipのメタ情報。
class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.baseDocsPath,
    required this.dbFileName,
  });

  final int formatVersion;
  final String appVersion;
  final String exportedAt;

  /// エクスポート元端末のアプリドキュメントディレクトリ(写真パスのベース)
  final String baseDocsPath;
  final String dbFileName;

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'appVersion': appVersion,
        'exportedAt': exportedAt,
        'baseDocsPath': baseDocsPath,
        'dbFileName': dbFileName,
      };

  static BackupManifest? tryParse(String jsonStr) {
    try {
      final m = jsonDecode(jsonStr) as Map<String, dynamic>;
      final v = m['formatVersion'];
      if (v is! int) return null;
      return BackupManifest(
        formatVersion: v,
        appVersion: m['appVersion'] as String? ?? '',
        exportedAt: m['exportedAt'] as String? ?? '',
        baseDocsPath: m['baseDocsPath'] as String? ?? '',
        dbFileName: m['dbFileName'] as String? ?? 'koko_meshi.db',
      );
    } catch (_) {
      return null;
    }
  }
}

class BackupService {
  BackupService._();

  /// このバックアップ形式のバージョン。互換性のない変更で上げる。
  static const int currentFormatVersion = 1;
  static const _dbFileName = 'koko_meshi.db';

  /// 端末が変わって写真の絶対パスのベースが変わった場合の書き換え(純関数)。
  static String? remapPath(String? path, String oldBase, String newBase) {
    if (path == null || path.isEmpty) return path;
    if (oldBase.isEmpty || oldBase == newBase) return path;
    if (path.startsWith(oldBase)) {
      return newBase + path.substring(oldBase.length);
    }
    return path;
  }

  // ─── エクスポート ───

  /// 全データ(DB+写真+設定)を1つのzipにまとめ、そのファイルパスを返す。
  /// 呼び出し側で share_plus 等を使って保存先を選ばせる。
  static Future<String> export() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir = await getDatabasesPath();
    final tmpDir = await getTemporaryDirectory();

    final stagingDir =
        Directory(p.join(tmpDir.path, 'backup_staging'));
    if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
    stagingDir.createSync(recursive: true);

    // 1. DBを一瞬だけ閉じてコピー(整合したスナップショットを得る)
    await LocalDatabase.close();
    final dbSrc = File(p.join(dbDir, _dbFileName));
    final dbStaged = File(p.join(stagingDir.path, _dbFileName));
    if (dbSrc.existsSync()) {
      await dbSrc.copy(dbStaged.path);
    }
    // すぐ再オープン(以降アプリは通常どおり動く)
    await LocalDatabase.database;

    // 2. manifest と settings を書き出す
    final info = await PackageInfo.fromPlatform();
    final manifest = BackupManifest(
      formatVersion: currentFormatVersion,
      appVersion: info.version,
      exportedAt: DateTime.now().toIso8601String(),
      baseDocsPath: docsDir.path,
      dbFileName: _dbFileName,
    );
    File(p.join(stagingDir.path, 'manifest.json'))
        .writeAsStringSync(jsonEncode(manifest.toJson()));
    File(p.join(stagingDir.path, 'settings.json'))
        .writeAsStringSync(jsonEncode(await _dumpSettings()));

    // 3. zip化するファイル一覧を作る(dbスナップショット+メタ+写真+サムネ)
    final entries = <_ZipEntry>[
      _ZipEntry(dbStaged.path, 'db/$_dbFileName'),
      _ZipEntry(p.join(stagingDir.path, 'manifest.json'), 'manifest.json'),
      _ZipEntry(p.join(stagingDir.path, 'settings.json'), 'settings.json'),
    ];
    _collectDir(Directory(p.join(docsDir.path, 'photos')), 'photos', entries);
    _collectDir(
        Directory(p.join(docsDir.path, 'thumbnails')), 'thumbnails', entries);

    // 4. 別isolateでストリーミングzip化(メモリに全載せしない)
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:T]'), '-')
        .split('.')
        .first;
    final zipPath = p.join(tmpDir.path, 'kokomeshi-backup-$stamp.zip');
    await Isolate.run(() => _zipEntries(entries, zipPath));

    // 5. staging掃除(zipは呼び出し側が共有後に消す)
    try {
      stagingDir.deleteSync(recursive: true);
    } catch (_) {}

    return zipPath;
  }

  // ─── インポート(復元) ───

  /// zipのmanifestだけを軽く読む(復元前の確認用)。
  static Future<BackupManifest?> readManifest(String zipPath) async {
    try {
      final input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(input);
      final file = archive.findFile('manifest.json');
      if (file == null) return null;
      return BackupManifest.tryParse(utf8.decode(file.content));
    } catch (e) {
      debugPrint('[Backup] readManifest failed: $e');
      return null;
    }
  }

  /// 行を入れる順番。restaurants を先に入れてから、それを参照する
  /// meal_logs、さらに meal_photos の順で積む。
  static const _mergeTables = [
    'restaurants',
    'meal_logs',
    'meal_photos',
    'saved_places',
    'diet_advices',
  ];

  /// 写真のパスを持つ列。復元時にこの端末のパスへ読み替える
  static const _pathColumns = [
    'local_path',
    'original_local_path',
    'thumbnail_url',
  ];

  /// zipから復元する。**この端末にある記録は消さない。**
  ///
  /// バックアップにしか無い記録・写真を「足す」だけで、既にあるものは
  /// 手を付けない(同じidの記録があれば、この端末側を残す)。復元は取り戻す
  /// ための操作なので、間違えたときに失われるものが無いほうを既定にする。
  /// 全部を置き換える方式だと、古いバックアップを選んだだけでそれ以降の
  /// 記録が消え、取り返しがつかない。
  ///
  /// 逆に、この端末で消した記録がバックアップに残っていると復活する。
  /// 消したものが戻るのは消し直せば済むが、消えたものは戻せない。
  ///
  /// 設定(フォント・AI解析のオン/オフ)は触らない。いま使っている設定を
  /// 上書きするのも「消す」ことに当たるため。
  ///
  /// 戻り値は追加した件数。
  static Future<RestoreResult> restore(String zipPath) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final tmpDir = await getTemporaryDirectory();

    final staging = Directory(p.join(tmpDir.path, 'restore_staging'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    try {
      // 1. 別isolateでstagingへ展開
      await Isolate.run(() => extractFileToDisk(zipPath, staging.path));

      // 2. manifest検証
      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      if (!manifestFile.existsSync()) {
        throw const BackupException('バックアップファイルの形式が不正です（manifestなし）');
      }
      final manifest = BackupManifest.tryParse(manifestFile.readAsStringSync());
      if (manifest == null || manifest.formatVersion != currentFormatVersion) {
        throw BackupException(
            'このバージョンでは読み込めないバックアップです（形式v${manifest?.formatVersion ?? '?'}）');
      }

      final dbSrc = File(p.join(staging.path, 'db', manifest.dbFileName));
      if (!dbSrc.existsSync()) {
        throw const BackupException('バックアップファイルの形式が不正です（DBなし）');
      }

      // 3. 写真とサムネを「無いものだけ」置く。既にあるファイルは触らない
      //    (同名でも中身は同じ写真なので、上書きする意味が無い)
      final copiedFiles = _copyMissingFiles(
            Directory(p.join(staging.path, 'photos')),
            Directory(p.join(docsDir.path, 'photos')),
          ) +
          _copyMissingFiles(
            Directory(p.join(staging.path, 'thumbnails')),
            Directory(p.join(docsDir.path, 'thumbnails')),
          );

      // 4. バックアップのDBを読み取り専用で開き、無い行だけを足す
      final added = await _mergeRows(
        backupDbPath: dbSrc.path,
        oldBase: manifest.baseDocsPath,
        newBase: docsDir.path,
      );

      return RestoreResult(addedRecords: added, copiedFiles: copiedFiles);
    } finally {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// バックアップDBの行を現在のDBへ足す。同じidが既にあれば飛ばす。
  /// 追加した meal_logs の件数を返す(利用者に伝えるのはこれが分かりやすい)。
  static Future<int> _mergeRows({
    required String backupDbPath,
    required String oldBase,
    required String newBase,
  }) async {
    // 読み取り専用で開く。バージョンを指定して開くとスキーマの
    // マイグレーションが走り、バックアップ側のファイルを書き換えてしまう
    final backupDb = await openReadOnlyDatabase(backupDbPath);
    try {
      return await mergeInto(
        target: await LocalDatabase.database,
        source: backupDb,
        oldBase: oldBase,
        newBase: newBase,
      );
    } finally {
      await backupDb.close();
    }
  }

  /// [source] の行を [target] へ足す。**既にある行は書き換えず、消しもしない。**
  /// 追加した meal_logs の件数を返す。
  ///
  /// 同一性は主キー(id)で見る。idはUUIDなので、別端末で作られた記録と
  /// ぶつかることは実質起きない。ぶつかったら [target] 側を残す。
  @visibleForTesting
  static Future<int> mergeInto({
    required DatabaseExecutor target,
    required DatabaseExecutor source,
    required String oldBase,
    required String newBase,
  }) async {
    var addedLogs = 0;
    for (final table in _mergeTables) {
      final List<Map<String, Object?>> rows;
      try {
        rows = await source.query(table);
      } on DatabaseException catch (e) {
        // 古いバックアップに無いテーブルは飛ばす
        debugPrint('[Backup] skip table $table: $e');
        continue;
      }
      for (final row in rows) {
        final values = Map<String, Object?>.from(row);
        // 写真のパスは端末ごとに違うので、入れる行だけ読み替える
        for (final col in _pathColumns) {
          if (values.containsKey(col)) {
            values[col] = remapPath(values[col] as String?, oldBase, newBase);
          }
        }
        final n = await target.insert(
          table,
          values,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        // ignore で飛ばされると 0 が返る
        if (n != 0 && table == 'meal_logs') addedLogs++;
      }
    }
    return addedLogs;
  }

  /// src配下のファイルを、dstに無いものだけコピーする。コピーした件数を返す。
  static int _copyMissingFiles(Directory src, Directory dst) {
    if (!src.existsSync()) return 0;
    if (!dst.existsSync()) dst.createSync(recursive: true);
    var copied = 0;
    for (final entity in src.listSync(recursive: true)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: src.path);
      final target = File(p.join(dst.path, rel));
      if (target.existsSync()) continue;
      target.parent.createSync(recursive: true);
      entity.copySync(target.path);
      copied++;
    }
    return copied;
  }

  // ─── ヘルパー ───

  static void _collectDir(Directory dir, String prefix, List<_ZipEntry> out) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        final rel = p.relative(entity.path, from: dir.path);
        out.add(_ZipEntry(entity.path, '$prefix/${rel.replaceAll(r'\', '/')}'));
      }
    }
  }

  static Future<Map<String, dynamic>> _dumpSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      out[key] = prefs.get(key);
    }
    return out;
  }

  /// isolate内で実行: ストリーミングでzipを作る(addFileSyncはファイルを
  /// チャンク読みするのでメモリに全載せしない)。
  static void _zipEntries(List<_ZipEntry> entries, String zipPath) {
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    for (final e in entries) {
      final f = File(e.sourcePath);
      if (f.existsSync()) encoder.addFileSync(f, e.archiveName);
    }
    encoder.closeSync();
  }
}

class _ZipEntry {
  const _ZipEntry(this.sourcePath, this.archiveName);
  final String sourcePath;
  final String archiveName;
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
