import 'package:flutter/foundation.dart';

/// 端末内AIの経過(モデルDL・ロード・解析)を端末内に残す。
///
/// iOS実機ではPCからログを読む手段が無く(macOS/Xcodeが必要)、パッケージ側の
/// ログは `if (!kDebugMode) return;` でリリースビルドでは消える。アプリ側も
/// 失敗を `debugPrint` に流すだけの箇所が多く、実機では「動かない」以上の
/// 情報が手元に来ない状態が続いた。DLの原因究明もロードが進まない件も、
/// どちらもここが無いと当て推量になる。
///
/// 切り分けに要る情報だけを残す:
/// 状態遷移・HTTPコード・例外・応答の先頭・期待サイズ・経過秒。
/// 進捗は10%刻みに間引く(2.4GBのDLで数千行になるのを防ぐ)。
class AiLog {
  AiLog._();

  static final AiLog instance = AiLog._();

  /// 古い行から捨てる上限。1回のDLは間引き後せいぜい数十行になる
  static const _maxLines = 200;

  final List<String> _lines = [];
  DateTime? _start;
  int _lastLoggedPercent = -1;

  /// 行が増えたことをUIに知らせるための世代番号
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool get isEmpty => _lines.isEmpty;

  /// コピー用の全文
  String get text => _lines.join('\n');

  /// DL開始時に呼ぶ。経過秒の基点を置き直し、前回分は残したまま区切りを入れる
  /// (「1回目は途中まで進んだが2回目は即失敗」のような差が分かるように)。
  void startAttempt(String label) {
    _start = DateTime.now();
    _lastLoggedPercent = -1;
    if (_lines.isNotEmpty) _push('');
    _push('=== $label ${_start!.toIso8601String()} ===');
  }

  void add(String line) => _push('${_elapsed()} $line');

  /// 進捗を10%刻みで記録する。どこで止まったかが分かればよい
  void addProgress(int percent, {int? expectedBytes, String? speed}) {
    final bucket = percent - (percent % 10);
    if (bucket <= _lastLoggedPercent) return;
    _lastLoggedPercent = bucket;
    final parts = <String>[
      '進捗 $percent%',
      if (expectedBytes != null && expectedBytes > 0) '期待 $expectedBytes バイト',
      if (expectedBytes != null && expectedBytes <= 0) '期待サイズ不明($expectedBytes)',
      ?speed,
    ];
    _push('${_elapsed()} ${parts.join(' / ')}');
  }

  void clear() {
    _lines.clear();
    _start = null;
    _lastLoggedPercent = -1;
    revision.value++;
  }

  String _elapsed() {
    final start = _start;
    if (start == null) return '[--:--]';
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '[$m:$s]';
  }

  void _push(String line) {
    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeRange(0, _lines.length - _maxLines);
    debugPrint('[GemmaDL] $line');
    revision.value++;
  }
}
