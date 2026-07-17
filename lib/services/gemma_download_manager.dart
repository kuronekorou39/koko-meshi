import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

import 'ai_analysis_service.dart';
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
    // 起動時(正確には初回アクセス時)にインストール済みフラグを埋める
    for (final k in GemmaModelKind.values) {
      refreshInstalled(k);
    }
  }

  static final GemmaDownloadManager instance = GemmaDownloadManager._();

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
    try {
      final source = await GemmaOnDeviceService.instance.install(
        kind,
        onProgress: (p) {
          notifier.value = GemmaDownloadState(downloading: true, progress: p);
        },
      );
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
      notifier.value = GemmaDownloadState(error: e.toString());
      rethrow;
    }
  }

  /// DL完了後のサイズ検証。破損ファイルを「インストール済み」と誤認しない
  /// よう、不一致なら削除してから例外を投げる(過去に追記破損した4.85GBの
  /// ファイルがインストール済み扱いになった実績がある)。
  Future<void> _verifyInstalledSize(GemmaModelKind kind) async {
    final file = await _installedModelFile(kind);
    final actual = await file.exists() ? await file.length() : 0;
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
