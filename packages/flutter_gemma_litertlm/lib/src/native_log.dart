/// ココメシ vendorパッチ: ネイティブ(LiteRT-LM/absl)の出力をリリースビルドでも
/// 拾えるようにする。
///
/// パッケージ既定では、stderr をファイルへ逃がす仕込み
/// (`stream_proxy_redirect_stderr`)は `kDebugMode` のときだけ入り、
/// 読み出し側の `gemmaLog` も `if (!kDebugMode) return;` で消える。
/// iOS実機の配布ビルドはPCからログを読む手段が無いため、
/// 「エンジンは作れたのに conversation が null で返る」のような失敗が
/// `Exception: Failed to create conversation` の一行だけになり、
/// 原因(メモリ不足・アクセラレータ未搭載・サンプラー未実装など)は
/// ネイティブ側のログにしか無いのに誰も読めない、という状態になる。
///
/// true にすると:
/// - stderr のリダイレクトをリリースビルドでも行う
///   (対象は iOS / macOS / Linux。Android は stderr が logcat に出るので
///    リダイレクトすると逆に見えなくなる)
/// - エンジン / conversation の作成に失敗したとき、直前のネイティブ出力の
///   末尾を例外メッセージに添える。呼び出し側はそれをアプリ内のログに残せる
///
/// 副作用: リダイレクト中はネイティブのクラッシュ出力もファイルへ行くので、
/// os_log 側には出なくなる。切り分けが済んだら false に戻してよい。
bool litertLmCaptureNativeLog = false;
