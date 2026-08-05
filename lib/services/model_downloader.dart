import 'dart:async';
import 'dart:io';

import 'ai_log.dart';

/// 途中まで落ちている `.part` の扱い。
enum ResumePlan {
  /// 先頭から落とす
  fresh,

  /// 続きから落とす
  resume,

  /// すでに全部ある
  alreadyComplete,
}

/// サーバ応答を見て、`.part` に追記していいか作り直すか。
enum WritePlan { append, truncate }

/// `.part` の大きさから、続きから落とせるかを決める。
///
/// 期待サイズを超えているものは信用しない(過去に追記破損で4.85GBの
/// ファイルができた実績がある)。
ResumePlan planResume({required int partBytes, required int expectedBytes}) {
  if (partBytes <= 0 || partBytes > expectedBytes) return ResumePlan.fresh;
  if (partBytes == expectedBytes) return ResumePlan.alreadyComplete;
  return ResumePlan.resume;
}

/// 応答コードから、追記していいかを決める。
///
/// 続きを要求(Range)したのに 206 ではなく 200 が返ってきたら、サーバは
/// 範囲要求を無視して先頭から送ってきている。そのまま追記すると壊れるので
/// 作り直す。
WritePlan planWrite({required int statusCode, required bool requestedRange}) {
  if (requestedRange && statusCode == HttpStatus.partialContent) {
    return WritePlan.append;
  }
  return WritePlan.truncate;
}

/// DLが期待どおりに終わらなかった。
class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// モデルファイルを自前でダウンロードする。
///
/// **なぜ自前なのか。** iOSでは background_downloader(バックグラウンド
/// URLSession)が2.4GBを転送しきったあとの確定処理で
/// `NSURLErrorCannotCreateFile` を返し、一度も成功しなかった。しかも
/// HuggingFace は範囲要求できない扱い(弱いETag)にされていて再開できないため、
/// 失敗ごとに全体を再DLする。実測で10GB近く使って4回失敗した。
/// パッケージ側にバックグラウンドセッションを使わない設定は無い。
///
/// ここでは [HttpClient] で直接streamし、`.part` に追記して完了時にrenameする。
/// 中断からは `Range` ヘッダで再開する。アプリが前面にある間だけ進むが、
/// モデルDLは設定画面から明示的に始める操作なので実際の使い方と合っている。
class ModelDownloader {
  ModelDownloader._();

  /// この時間だけ1バイトも来なければ、止まったものとして打ち切る。
  /// (接続が生きたまま無音になる状態を無限に待たないため)
  static const _stallTimeout = Duration(seconds: 90);

  /// 進捗を通知する最短間隔。チャンクごとに呼ぶと描画が潰れる
  static const _progressInterval = Duration(milliseconds: 500);

  /// この量を書くごとに受信を止めてflushする。ディスクが通信に追いつかない
  /// 場合にsinkの内部キューが膨らみ続けるのを防ぐ
  static const _flushEvery = 8 * 1024 * 1024;

  /// [url] を [destPath] に落とす。成功したら [destPath] を返す。
  ///
  /// [expectedBytes] と一致しなければ例外にする(中途半端なファイルを
  /// 「入っている」と誤認させないため)。`.part` は消さずに残すので、
  /// もう一度呼べば続きから再開する。
  static Future<String> download({
    required String url,
    required String destPath,
    required int expectedBytes,
    void Function(int percent)? onProgress,
  }) async {
    final dest = File(destPath);
    await dest.parent.create(recursive: true);
    final part = File('$destPath.part');

    final partBytes = await part.exists() ? await part.length() : 0;
    final plan = planResume(partBytes: partBytes, expectedBytes: expectedBytes);
    AiLog.instance
        .add('自前DL: ${plan.name} (途中 $partBytes / $expectedBytes バイト)');

    if (plan == ResumePlan.alreadyComplete) {
      if (await dest.exists()) await dest.delete();
      await part.rename(destPath);
      onProgress?.call(100);
      return destPath;
    }

    final offset = plan == ResumePlan.resume ? partBytes : 0;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      // 既定(15秒)だと持続接続が切られて再接続が増える
      ..idleTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      // HuggingFaceは署名付きCDNへ302で飛ばすので余裕を持たせる
      request.maxRedirects = 10;
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close();
      AiLog.instance.add(
        '自前DL: HTTP ${response.statusCode} / 本文長 ${response.contentLength}',
      );

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        // 本文は読み捨てる(エラーページを丸ごとファイルに書かないため)
        await response.drain<void>();
        throw ModelDownloadException(
          'サーバがモデルを返しませんでした (HTTP ${response.statusCode})',
        );
      }

      final writePlan = planWrite(
        statusCode: response.statusCode,
        requestedRange: offset > 0,
      );
      final append = writePlan == WritePlan.append;
      if (!append && offset > 0) {
        AiLog.instance.add('自前DL: 範囲要求が効かないので先頭から落とし直す');
      }

      final sink =
          part.openWrite(mode: append ? FileMode.append : FileMode.writeOnly);
      try {
        await _pump(
          response: response,
          sink: sink,
          alreadyWritten: append ? offset : 0,
          expectedBytes: expectedBytes,
          onProgress: onProgress,
        );
      } finally {
        await sink.close();
      }

      final actual = await part.length();
      AiLog.instance.add('自前DL: 受信完了 $actual / $expectedBytes バイト');
      if (actual != expectedBytes) {
        throw ModelDownloadException(
          'ダウンロードしたモデルの大きさが合いません '
          '($actual / $expectedBytes バイト)。'
          'もう一度実行すると途中から再開します',
        );
      }

      if (await dest.exists()) await dest.delete();
      await part.rename(destPath);
      onProgress?.call(100);
      return destPath;
    } finally {
      client.close(force: true);
    }
  }

  /// 応答をファイルへ流し込む。無音が続いたら打ち切る。
  static Future<void> _pump({
    required HttpClientResponse response,
    required IOSink sink,
    required int alreadyWritten,
    required int expectedBytes,
    void Function(int percent)? onProgress,
  }) async {
    var total = alreadyWritten;
    var sinceFlush = 0;
    var lastByteAt = DateTime.now();
    var lastProgressAt = DateTime.now();
    var lastPercent = -1;

    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        lastByteAt = DateTime.now();
        sink.add(chunk);
        total += chunk.length;
        sinceFlush += chunk.length;
        if (sinceFlush >= _flushEvery) {
          sinceFlush = 0;
          sub.pause(sink.flush());
        }
        final now = DateTime.now();
        if (now.difference(lastProgressAt) >= _progressInterval) {
          lastProgressAt = now;
          final percent = (total * 100 / expectedBytes).floor().clamp(0, 100);
          if (percent != lastPercent) {
            lastPercent = percent;
            onProgress?.call(percent);
            AiLog.instance
                .addProgress(percent, expectedBytes: expectedBytes);
          }
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      cancelOnError: true,
    );

    final watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().difference(lastByteAt) <= _stallTimeout) return;
      if (done.isCompleted) return;
      done.completeError(ModelDownloadException(
        '${_stallTimeout.inSeconds}秒のあいだ通信が進みませんでした。'
        '電波の良い場所でもう一度実行すると途中から再開します',
      ));
    });

    try {
      await done.future;
    } finally {
      watchdog.cancel();
      // 打ち切った場合、受信を確実に止める(残した接続が裏で流れ続けないように)
      await sub.cancel();
    }
  }
}
