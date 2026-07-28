/// ビルド時に切り替える機能フラグ。
class AppFeatures {
  AppFeatures._();

  /// 周辺の店舗検索(Google Places)を出すか。**配布ビルドでは無効。**
  ///
  /// Places は従量課金で、利用者が増えるほど費用が比例して増える。無料で
  /// 配っているアプリに素で載せると、使われるほど赤字が膨らむ形になる。
  /// 収益化の形(誰がその費用を負担するのか)が決まるまでは、開発者の手元
  /// でだけ動かして仕様を詰める。
  ///
  /// 有効にしてビルドする:
  ///     flutter build apk --release --dart-define=PLACE_SEARCH=true \
  ///       --target-platform android-arm64,android-arm
  ///
  /// CIのリリースビルド(.github/workflows/release.yml)は渡していないので、
  /// 配布物では自動的に「準備中」表示になる。
  static const placeSearch =
      bool.fromEnvironment('PLACE_SEARCH', defaultValue: false);
}
