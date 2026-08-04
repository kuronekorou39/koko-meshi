import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

import 'ai_analysis_service.dart';
import 'download_log.dart';
import 'download_updates.dart';
import 'gemma_ondevice_service.dart';

/// モデルDLの現在状態(不変オブジェクト)。
class GemmaDownloadState {
  const GemmaDownloadState({
    this.downloading = false,
    this.progress = 0,
    this.error,
  });

  final bool downloading;

  /// DL進捗 0-100
  final int progress;

  /// 直近のDL失敗メッセージ。次のDL開始でクリアされる
  final String? error;
}

/// DLしたモデルファイルが期待サイズと一致しない(追記破損等)ときの例外。
class GemmaModelCorruptedException implements Exception {
  GemmaModelCorruptedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// オンデバイスGemmaモデルDLのシングルトンマネージャ。
///
/// DLの進捗・エラー・インストール済みフラグをモデル種別ごとに
/// [ValueNotifier] で公開する。状態が画面Stateではなくここにあるので、
/// DL中に画面を離れて戻っても進捗表示が復元されるし、複数画面
/// (設定・PoC・食事詳細)が同じ状態を購読できる。
class GemmaDownloadManager {
  GemmaDownloadManager._() {
    _watchDownloadFailures();
    // 起動時(正確には初回アクセス時)にインストール済みフラグを埋める
    for (final k in GemmaModelKind.values) {
      refreshInstalled(k);
    }
  }

  static final GemmaDownloadManager instance = GemmaDownloadManager._();

  /// ダウンロードが失敗したときの生の情報。
  ///
  /// flutter_gemma は失敗の詳細(HTTPコード・例外)を gemmaLog に出すが、
  /// あれは `if (!kDebugMode) return;` でリリースビルドでは消える。
  /// 呼び出し側に届くのは「Download failed after N attempts: ...」のような
  /// 原因を含まない文字列だけ。実機で困るのはリリースビルドなので、
  /// こちらでも同じ更新を聞いて原因を残す。
  ///
  /// **購読は必ず [DownloadUpdates.stream] 経由にすること。**
  /// `FileDownloader().updates` は単一購読で、直接listenすると
  /// flutter_gemma 側が購読できず「Stream has already been listened to」で
  /// ダウンロードそのものが死ぬ(実際にそれで壊した)。
  String? _lastFailureDetail;

  /// 直近の失敗の詳細(HTTPコードなど)。無ければ null
  String? get lastFailureDetail => _lastFailureDetail;

  void _watchDownloadFailures() {
    DownloadUpdates.stream.listen((update) {
      if (update is TaskProgressUpdate) {
        DownloadLog.instance.addProgress(
          (update.progress * 100).round(),
          expectedBytes: update.expectedFileSize,
          speed: update.networkSpeed > 0
              ? '${update.networkSpeed.toStringAsFixed(1)}MB/s'
              : null,
        );
        return;
      }
      if (update is! TaskStatusUpdate) return;

      // 成功も含めて全部の遷移を残す。「enqueued のまま何も来ない」のか
      // 「running まで行って落ちた」のかで原因が全く違う
      final body = update.responseBody;
      final parts = <String>[
        '状態: ${update.status.name}',
        if (update.responseStatusCode != null)
          'HTTP: ${update.responseStatusCode}',
        if (update.exception != null)
          '例外: ${update.exception.runtimeType} ${update.exception}',
        if (body != null && body.isNotEmpty)
          '応答: ${body.length > 200 ? '${body.substring(0, 200)}…' : body}',
      ];
      final line = parts.join(' / ');
      DownloadLog.instance.add(line);

      if (update.status == TaskStatus.failed ||
          update.status == TaskStatus.notFound ||
          update.status == TaskStatus.canceled) {
        _lastFailureDetail = line;
      }
    });
  }

  final Map<GemmaModelKind, ValueNotifier<GemmaDownloadState>> _states = {
    for (final k in GemmaModelKind.values)
      k: ValueNotifier(const GemmaDownloadState()),
  };

  final Map<GemmaModelKind, ValueNotifier<bool?>> _installed = {
    for (final k in GemmaModelKind.values) k: ValueNotifier(null),
  };

  final Map<GemmaModelKind, Future<GemmaInstallSource>> _inFlight = {};

  /// DL状態(DL中か・進捗0-100・エラー)。UIはどの画面からでも購読できる
  ValueListenable<GemmaDownloadState> stateOf(GemmaModelKind kind) =>
      _states[kind]!;

  /// インストール済みフラグ。null=未確認
  ValueListenable<bool?> installedOf(GemmaModelKind kind) => _installed[kind]!;

  /// インストール済みフラグを実際の状態から更新する
  Future<void> refreshInstalled(GemmaModelKind kind) async {
    try {
      final ok = await GemmaOnDeviceService.instance.isInstalled(kind);
      _installed[kind]!.value = ok;
    } catch (e) {
      // 確認失敗時はnull(未確認)のまま
      debugPrint('[GemmaDL] インストール確認失敗 (${kind.label}): $e');
    }
  }

  /// モデルをDLしてインストールする。同じモデルのDLが進行中なら
  /// 同一のFutureを返す(二重DL防止)。
  Future<GemmaInstallSource> download(GemmaModelKind kind) {
    final inFlight = _inFlight[kind];
    if (inFlight != null) return inFlight;
    final future = _download(kind).whenComplete(() => _inFlight.remove(kind));
    _inFlight[kind] = future;
    return future;
  }

  Future<GemmaInstallSource> _download(GemmaModelKind kind) async {
    final notifier = _states[kind]!;
    notifier.value = const GemmaDownloadState(downloading: true);
    DownloadLog.instance.startAttempt('${kind.label} のDL開始');
    try {
      final source = await GemmaOnDeviceService.instance.install(
        kind,
        onProgress: (p) {
          notifier.value = GemmaDownloadState(downloading: true, progress: p);
        },
      );
      DownloadLog.instance.add('install() 完了 (元: ${source.name})');
      // ネットワークDLは中断時の追記破損が既知問題なのでサイズ検証する。
      // fromFile経路(adb push配置)はファイルがDocuments外にあるため対象外
      if (source == GemmaInstallSource.network) {
        await _verifyInstalledSize(kind);
      }
      _installed[kind]!.value = true;
      notifier.value = const GemmaDownloadState(progress: 100);
      // 解析可能になったので、溜まっているpending写真の解析を起動する
      // (DLを待っていた写真が「解析中」表示のまま止まるのを防ぐ。
      //  モードや対象写真の有無はprocessPendingPhotos側が判定する)
      unawaited(AiAnalysisService.processPendingPhotos());
      return source;
    } catch (e) {
      DownloadLog.instance.add('例外で終了: ${e.runtimeType} $e');
      // パッケージが返す文言は原因を含まないので、拾っておいた詳細を添える
      final detail = _lastFailureDetail;
      notifier.value = GemmaDownloadState(
        error: detail == null ? e.toString() : '$e\n\n[詳細] $detail',
      );
      rethrow;
    }
  }

  /// DL完了後のサイズ検証。破損ファイルを「インストール済み」と誤認しない
  /// よう、不一致なら削除してから例外を投げる(過去に追記破損した4.85GBの
  /// ファイルがインストール済み扱いになった実績がある)。
  Future<void> _verifyInstalledSize(GemmaModelKind kind) async {
    final file = await _installedModelFile(kind);
    final actual = await file.exists() ? await file.length() : 0;
    DownloadLog.instance
        .add('サイズ検証: $actual / ${kind.expectedBytes} @ ${file.path}');
    if (actual == kind.expectedBytes) return;

    try {
      await FlutterGemma.uninstallModel(kind.fileName);
    } catch (e) {
      debugPrint('[GemmaDL] 破損モデルの削除に失敗 (${kind.label}): $e');
    }
    _installed[kind]!.value = false;
    throw GemmaModelCorruptedException(
      'ダウンロードしたモデルファイルが壊れていたため削除しました'
      '(サイズ不一致: $actual / ${kind.expectedBytes} バイト)。'
      '通信環境の良い場所で再ダウンロードしてください',
    );
  }

  /// flutter_gemma(モバイル)のモデル設置先。
  /// PlatformFileSystemServiceの実装より、Android/iOSでは
  /// アプリDocumentsディレクトリ直下に `fileName` で置かれる。
  Future<File> _installedModelFile(GemmaModelKind kind) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}${kind.fileName}');
  }
}
