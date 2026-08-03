import 'package:background_downloader/background_downloader.dart';

/// ダウンロードの更新を、アプリと flutter_gemma で共有するための入口。
///
/// `FileDownloader().updates` は**単一購読**のストリーム。誰かが直接listen
/// すると他が購読できなくなり、flutter_gemma 側は
/// 「Bad state: Stream has already been listened to」でダウンロードごと
/// 失敗する(一度それで壊した)。
///
/// そこで broadcast 化したものを1つだけ作り、
/// - `FlutterGemma.initialize(downloadUpdatesStream: DownloadUpdates.stream)`
/// - アプリ側の失敗詳細の記録
/// の両方から同じものを使う。
class DownloadUpdates {
  DownloadUpdates._();

  static Stream<TaskUpdate>? _stream;

  /// 何度呼んでも同じ broadcast ストリームを返す
  static Stream<TaskUpdate> get stream =>
      _stream ??= FileDownloader().updates.asBroadcastStream();
}
