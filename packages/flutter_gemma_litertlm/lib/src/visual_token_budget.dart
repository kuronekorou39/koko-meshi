/// ココメシ vendorパッチ: 画像入力のvisual token budgetを外部から設定する。
///
/// LiteRT-LM は画像1枚をこのトークン数まで圧縮して認識する
/// (Gemma 4 の有効値: 70 / 140 / 280 / 560 / 1120、ネイティブ既定は280
///  ≈ 実効384x384相当。1120で ≈ 768x768相当となり細部の認識に有利)。
/// pub.dev 1.0.4 にはFFIバインディング
/// `litert_lm_conversation_optional_args_set_visual_token_budget` だけが
/// 存在し、公開APIから設定する経路が無いため、このvendorコピーで
/// メッセージ送信時のオプション引数に反映するようパッチしている
/// (litert_lm_client.dart の optional_args 生成箇所2つ)。
///
/// null のままならネイティブ既定値を使う(パッチ前と同挙動)。
int? litertLmVisualTokenBudget;
