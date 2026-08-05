import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'ai_log.dart';

/// 端末内AI解析中に、アプリがバックグラウンドへ回ったり画面が消えたりしても
/// OSにプロセスを凍結されないよう保つためのフォアグラウンドサービスの薄い
/// ラッパー。解析ロジック自体はメインisolateで動き続ける。ここはプロセスの
/// キープアライブと、通知バーへの進捗表示(「AI解析中 (2/5)」)だけを担う。
///
/// サービスisolateでコードを動かす必要はないため、TaskHandlerは何もしない
/// no-op。定期イベント(onRepeatEvent)も使わない。
class AnalysisForegroundService {
  AnalysisForegroundService._();

  static const _channelId = 'ai_analysis';
  static const _channelName = 'AI解析';
  static const _channelDescription = '端末内AIで食事写真を解析している間に表示される通知';

  /// 他のサービス/通知と衝突しない任意のID
  static const _serviceId = 2718;
  static const _notificationTitle = 'ココメシ';

  /// FlutterForegroundTask.init は静的フィールドを設定するだけの軽量処理。
  /// AIモードがオフ/クラウドのときは呼ばれないよう、初回start時に一度だけ行う。
  static bool _initialized = false;

  /// サービス起動中かどうか(このラッパー側での追跡)。起動に失敗した場合や
  /// 未起動のときにupdate/stopを空振りさせるために使う。
  static bool _running = false;

  /// 起動処理の打ち切り時間。
  ///
  /// 通知許可の要求もサービス起動もOSの応答待ちで、返ってこないことがある
  /// (許可ダイアログが出たまま放置される、対応していないプラットフォームで
  /// 応答が来ない等)。[start] は解析バッチがモデルをロードする手前で
  /// awaitされるので、ここで止まると「解析の順番待ち」のまま永久に進まない。
  /// 通知はあくまで補助なので、待てなければ諦めて解析を進める。
  static const _startTimeout = Duration(seconds: 15);

  static void _ensureInitialized() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: _channelDescription,
        // 進捗更新のたびに音やバイブで通知しない
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 解析はメインisolateで進むため定期イベントは不要
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  /// 解析バッチ開始時に呼ぶ。通知許可の取得を試み(拒否されても解析は続行)、
  /// フォアグラウンドサービスを起動する。
  ///
  /// Android 12+ ではバックグラウンドからのFGS起動が制限される。モデルDL完了
  /// フック経由などアプリが背面にいる状態で呼ばれると起動に失敗しうるため、
  /// 失敗は握って通常解析にフォールバックする(通知が出ないだけで解析は動く)。
  static Future<void> start(int total) async {
    if (_running) {
      // 前バッチの停止が未完了などで既に起動中なら進捗更新に切り替える
      await updateProgress(0, total);
      return;
    }
    _ensureInitialized();
    try {
      await _requestNotificationPermission().timeout(_startTimeout);
      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: _notificationTitle,
        notificationText: _progressText(0, total),
        callback: analysisForegroundTaskCallback,
      ).timeout(_startTimeout);
      _running = result is ServiceRequestSuccess;
      if (!_running && result is ServiceRequestFailure) {
        AiLog.instance.add('通知サービスの起動に失敗(続行): ${result.error}');
      }
    } on TimeoutException {
      _running = false;
      AiLog.instance
          .add('通知サービスの起動が${_startTimeout.inSeconds}秒で返らないので諦めて続行');
    } catch (e) {
      _running = false;
      AiLog.instance.add('通知サービスの起動でエラー(続行): ${e.runtimeType} $e');
    }
  }

  /// 写真1枚の解析が終わるごとに呼び、通知の進捗を更新する。
  static Future<void> updateProgress(int done, int total) async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: _notificationTitle,
        notificationText: _progressText(done, total),
      );
    } catch (e) {
      debugPrint('[AI][FGS] update error: $e');
    }
  }

  /// バッチ終了時に呼び、サービスを停止して通知を消す。
  static Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[AI][FGS] stop error: $e');
    }
  }

  /// 通知許可(Android 13+)の取得を試みる。拒否されてもサービス自体は動く
  /// ため、失敗は握る(通知が表示されないだけ)。
  static Future<void> _requestNotificationPermission() async {
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      debugPrint('[AI][FGS] notification permission error: $e');
    }
  }

  static String _progressText(int done, int total) {
    if (total <= 0) return 'AI解析中';
    return 'AI解析中 ($done/$total)';
  }
}

/// フォアグラウンドサービスisolateのエントリポイント。
/// 解析はメインisolateで動くため、ここでは何もしないTaskHandlerを設定する
/// (通知によるプロセスのキープアライブが目的)。
@pragma('vm:entry-point')
void analysisForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_NoopTaskHandler());
}

/// 何もしないTaskHandler。サービスisolateでの処理は不要。
class _NoopTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
