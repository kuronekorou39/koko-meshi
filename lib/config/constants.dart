/// アプリ全体の定数
class AppConstants {
  AppConstants._();

  /// アプリ名
  static const appName = 'ココメシ';

  /// グルーピング: 同一食事と判定するGPS半径（メートル）
  static const groupingRadiusMeters = 50.0;

  /// グルーピング: 同一食事と判定する時間差（時間）
  static const groupingTimeWindowHours = 2;

  /// AI解析用の画像リサイズ最大幅
  static const aiImageMaxWidth = 1080;

  /// サムネイルの最大幅
  static const thumbnailMaxWidth = 200;
}
