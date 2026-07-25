import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/backup_service.dart';

void main() {
  group('BackupService.remapPath', () {
    const oldBase = '/data/user/0/com.kokomeshi.koko_meshi/app_flutter';
    const newBase = '/data/data/com.kokomeshi.koko_meshi/app_flutter';

    test('oldBase配下のパスは新baseへ書き換わる', () {
      expect(
        BackupService.remapPath('$oldBase/photos/a.jpg', oldBase, newBase),
        '$newBase/photos/a.jpg',
      );
    });

    test('oldBaseと一致しないパスはそのまま', () {
      expect(
        BackupService.remapPath('/somewhere/else/b.jpg', oldBase, newBase),
        '/somewhere/else/b.jpg',
      );
    });

    test('oldBase==newBaseなら無変更', () {
      expect(
        BackupService.remapPath('$oldBase/x.jpg', newBase, newBase),
        '$oldBase/x.jpg',
      );
    });

    test('nullや空文字はそのまま返す', () {
      expect(BackupService.remapPath(null, oldBase, newBase), isNull);
      expect(BackupService.remapPath('', oldBase, newBase), '');
    });

    test('oldBaseが空なら無変更(誤爆防止)', () {
      expect(
        BackupService.remapPath('$oldBase/x.jpg', '', newBase),
        '$oldBase/x.jpg',
      );
    });

    test('前方一致のみ(部分一致では書き換えない)', () {
      // oldBaseを途中に含むが先頭ではないパスは対象外
      const path = '/other$oldBase/x.jpg';
      expect(BackupService.remapPath(path, oldBase, newBase), path);
    });
  });

  group('BackupManifest', () {
    test('往復でフィールドが保持される', () {
      const m = BackupManifest(
        formatVersion: 1,
        appVersion: '0.7.0',
        exportedAt: '2026-07-20T10:00:00.000',
        baseDocsPath: '/data/app_flutter',
        dbFileName: 'koko_meshi.db',
      );
      final parsed = BackupManifest.tryParse(
          '{"formatVersion":1,"appVersion":"0.7.0",'
          '"exportedAt":"2026-07-20T10:00:00.000",'
          '"baseDocsPath":"/data/app_flutter","dbFileName":"koko_meshi.db"}');
      expect(parsed, isNotNull);
      expect(parsed!.formatVersion, m.formatVersion);
      expect(parsed.appVersion, m.appVersion);
      expect(parsed.baseDocsPath, m.baseDocsPath);
      expect(parsed.dbFileName, m.dbFileName);
    });

    test('formatVersion欠損や不正JSONはnull', () {
      expect(BackupManifest.tryParse('{"appVersion":"x"}'), isNull);
      expect(BackupManifest.tryParse('not json'), isNull);
      expect(BackupManifest.tryParse('{"formatVersion":"1"}'), isNull);
    });
  });
}
