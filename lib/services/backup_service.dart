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

  /// zipから完全復元する。**現在の端末のデータはすべて置き換えられる。**
  /// 失敗時は退避した元データから復旧する。
  static Future<void> restore(String zipPath) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir = await getDatabasesPath();
    final tmpDir = await getTemporaryDirectory();

    final staging = Directory(p.join(tmpDir.path, 'restore_staging'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    // 1. 別isolateでstagingへ展開
    await Isolate.run(() => extractFileToDisk(zipPath, staging.path));

    // 2. manifest検証
    final manifestFile = File(p.join(staging.path, 'manifest.json'));
    if (!manifestFile.existsSync()) {
      staging.deleteSync(recursive: true);
      throw const BackupException('バックアップファイルの形式が不正です（manifestなし）');
    }
    final manifest = BackupManifest.tryParse(manifestFile.readAsStringSync());
    if (manifest == null ||
        manifest.formatVersion != currentFormatVersion) {
      staging.deleteSync(recursive: true);
      throw BackupException(
          'このバージョンでは読み込めないバックアップです（形式v${manifest?.formatVersion ?? '?'}）');
    }

    // 3. DBを閉じる
    await LocalDatabase.close();

    // 4. 既存データを.bakへ退避しつつ、stagingの内容を配置
    final photosDst = Directory(p.join(docsDir.path, 'photos'));
    final thumbsDst = Directory(p.join(docsDir.path, 'thumbnails'));
    final dbDst = File(p.join(dbDir, manifest.dbFileName));
    final swaps = <_Swap>[];
    try {
      // 写真・サムネ・DBを差し替え(元は.bakへ退避)。swapsへは退避完了時点で
      // 登録されるので、途中で失敗してもロールバックで必ず元へ戻せる
      _swapDir(
          Directory(p.join(staging.path, 'photos')), photosDst, swaps);
      _swapDir(
          Directory(p.join(staging.path, 'thumbnails')), thumbsDst, swaps);
      _swapFile(File(p.join(staging.path, 'db', manifest.dbFileName)), dbDst,
          swaps);
      // 古いWAL/SHMは消しておく(スナップショットと不整合になるため)
      for (final suffix in ['-wal', '-shm']) {
        final f = File('${dbDst.path}$suffix');
        if (f.existsSync()) f.deleteSync();
      }

      // 5. DB再オープン → 写真パスをこの端末のベースへ書き換え
      await LocalDatabase.database;
      await _remapAllPaths(manifest.baseDocsPath, docsDir.path);

      // 6. 設定を復元
      final settingsFile = File(p.join(staging.path, 'settings.json'));
      if (settingsFile.existsSync()) {
        await _restoreSettings(settingsFile.readAsStringSync());
      }

      // 成功: .bak と staging を掃除
      for (final s in swaps) {
        s.cleanupBackup();
      }
      staging.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[Backup] restore failed, rolling back: $e');
      // 失敗: .bak から復旧
      for (final s in swaps.reversed) {
        s.rollback();
      }
      try {
        staging.deleteSync(recursive: true);
      } catch (_) {}
      await LocalDatabase.database;
      rethrow;
    }
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

  static Future<void> _restoreSettings(String jsonStr) async {
    final prefs = await SharedPreferences.getInstance();
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    for (final entry in map.entries) {
      final v = entry.value;
      if (v is bool) {
        await prefs.setBool(entry.key, v);
      } else if (v is int) {
        await prefs.setInt(entry.key, v);
      } else if (v is double) {
        await prefs.setDouble(entry.key, v);
      } else if (v is String) {
        await prefs.setString(entry.key, v);
      } else if (v is List) {
        await prefs.setStringList(
            entry.key, v.map((e) => e.toString()).toList());
      }
    }
  }

  static Future<void> _remapAllPaths(String oldBase, String newBase) async {
    if (oldBase == newBase) return;
    final photos = await LocalDatabase.getAllMealPhotos();
    for (final photo in photos) {
      final newLocal = remapPath(photo.localPath, oldBase, newBase)!;
      final newOrig = remapPath(photo.originalLocalPath, oldBase, newBase);
      final newThumb = remapPath(photo.thumbnailUrl, oldBase, newBase);
      if (newLocal == photo.localPath &&
          newOrig == photo.originalLocalPath &&
          newThumb == photo.thumbnailUrl) {
        continue;
      }
      await LocalDatabase.updateMealPhoto(photo.copyWith(
        localPath: newLocal,
        originalLocalPath: newOrig,
        thumbnailUrl: newThumb,
      ));
    }
  }

  /// srcディレクトリを dst の位置へ配置し、既存 dst は .bak へ退避する。
  /// 退避(rename)が済んだ時点で swaps に登録するので、その後に失敗しても
  /// ロールバックで .bak を戻せる。
  static void _swapDir(Directory src, Directory dst, List<_Swap> swaps) {
    final bak = Directory('${dst.path}.bak');
    if (bak.existsSync()) bak.deleteSync(recursive: true);
    if (dst.existsSync()) {
      dst.renameSync(bak.path);
      swaps.add(_Swap(dst.path, bak.path, isDir: true));
    } else {
      swaps.add(_Swap(dst.path, bak.path, isDir: true));
    }
    if (src.existsSync()) {
      src.renameSync(dst.path);
    } else {
      dst.createSync(recursive: true); // 空でも作る
    }
  }

  static void _swapFile(File src, File dst, List<_Swap> swaps) {
    final bak = File('${dst.path}.bak');
    if (bak.existsSync()) bak.deleteSync();
    if (dst.existsSync()) dst.renameSync(bak.path);
    swaps.add(_Swap(dst.path, bak.path, isDir: false));
    if (src.existsSync()) src.copySync(dst.path);
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

/// 差し替えのロールバック情報。
class _Swap {
  _Swap(this.livePath, this.bakPath, {required this.isDir});
  final String livePath;
  final String bakPath;
  final bool isDir;

  void cleanupBackup() {
    try {
      if (isDir) {
        final d = Directory(bakPath);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } else {
        final f = File(bakPath);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  void rollback() {
    try {
      if (isDir) {
        final live = Directory(livePath);
        if (live.existsSync()) live.deleteSync(recursive: true);
        final bak = Directory(bakPath);
        if (bak.existsSync()) bak.renameSync(livePath);
      } else {
        final live = File(livePath);
        if (live.existsSync()) live.deleteSync();
        final bak = File(bakPath);
        if (bak.existsSync()) bak.renameSync(livePath);
      }
    } catch (_) {}
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
