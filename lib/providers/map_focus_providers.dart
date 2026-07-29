import 'package:flutter_riverpod/flutter_riverpod.dart';

/// マップに寄ってほしい場所。
///
/// マップは画面ではなくホームのタブなので、詳細画面から直接開けない。
/// ここに置いてホーム側がタブを切り替え、マップが読んだら消す(受け渡し用の
/// 一時的な値なので、消さないと次にマップを開いたときも寄ってしまう)。
class MapFocus {
  const MapFocus({
    required this.latitude,
    required this.longitude,
    this.label,
  });

  final double latitude;
  final double longitude;

  /// 寄った先で何を見ているのかを伝える文言(店名・自宅など)
  final String? label;
}

final mapFocusProvider = StateProvider<MapFocus?>((ref) => null);
