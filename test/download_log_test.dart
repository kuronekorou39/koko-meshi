import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/download_log.dart';

/// シングルトンなので各テストの先頭で消す。
void main() {
  final log = DownloadLog.instance;

  setUp(log.clear);

  test('記録が無いうちは空', () {
    expect(log.isEmpty, isTrue);
    expect(log.text, isEmpty);
  });

  test('startAttempt が見出しを入れる', () {
    log.startAttempt('E2B のDL開始');
    expect(log.isEmpty, isFalse);
    expect(log.text, contains('=== E2B のDL開始'));
  });

  test('状態遷移は経過時間つきで残る', () {
    log.startAttempt('開始');
    log.add('状態: enqueued');
    log.add('状態: running');
    final lines = log.text.split('\n');
    expect(lines.length, 3);
    expect(lines[1], matches(r'^\[\d\d:\d\d\] 状態: enqueued$'));
  });

  test('進捗は10%刻みに間引かれる', () {
    log.startAttempt('開始');
    for (var p = 0; p <= 100; p++) {
      log.addProgress(p);
    }
    // 見出し + 0,10,...,100 の11本
    expect(log.text.split('\n').length, 12);
  });

  test('同じ刻みの中では増えない', () {
    log.startAttempt('開始');
    log.addProgress(11);
    final before = log.text.split('\n').length;
    log.addProgress(12);
    log.addProgress(19);
    expect(log.text.split('\n').length, before);
  });

  test('進捗が巻き戻っても行は増えない(リトライで0%に戻る場合)', () {
    log.startAttempt('開始');
    log.addProgress(50);
    final before = log.text.split('\n').length;
    log.addProgress(10);
    expect(log.text.split('\n').length, before);
  });

  test('startAttempt で刻みがリセットされ、2回目も進捗が残る', () {
    log.startAttempt('1回目');
    log.addProgress(50);
    log.startAttempt('2回目');
    log.addProgress(10);
    expect(log.text, contains('=== 1回目'));
    expect(log.text, contains('=== 2回目'));
    // 2回目の10%が間引かれずに残っていること
    expect(log.text.split('\n').where((l) => l.contains('進捗 10%')).length, 1);
  });

  test('期待サイズが不明なときはそう分かる形で残る', () {
    log.startAttempt('開始');
    log.addProgress(10, expectedBytes: -1);
    expect(log.text, contains('期待サイズ不明(-1)'));
  });

  test('期待サイズが分かるときはバイト数が残る', () {
    log.startAttempt('開始');
    log.addProgress(10, expectedBytes: 2588147712);
    expect(log.text, contains('期待 2588147712 バイト'));
  });

  test('行数が上限で打ち切られる', () {
    log.startAttempt('開始');
    for (var i = 0; i < 500; i++) {
      log.add('行 $i');
    }
    final lines = log.text.split('\n');
    expect(lines.length, 200);
    // 古い方から捨てるので、最後の行は残っている
    expect(lines.last, contains('行 499'));
  });

  test('revision が行の追加で進む', () {
    final before = log.revision.value;
    log.startAttempt('開始');
    expect(log.revision.value, greaterThan(before));
  });

  test('clear で空に戻る', () {
    log.startAttempt('開始');
    log.add('なにか');
    log.clear();
    expect(log.isEmpty, isTrue);
  });
}
