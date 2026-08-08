/// ココメシ vendorパッチ: 画像エンコーダ(vision encoder)だけ別のバックエンドで
/// 動かせるようにする。
///
/// LiteRT-LM の C API はエンジン設定で本体 / vision / audio のバックエンドを
/// 別々に受け取るのに、パッケージは vision にも本体と同じ値をそのまま渡して
/// いた。そのため画像対応を有効にすると、画像エンコーダも必ずGPUに載る。
///
/// iPhone 12 Pro (RAM 6GB) の実測では、本体2.4GBを抱えた状態で画像エンコーダを
/// Metalに載せようとして確保に失敗し、conversation の作成ごと落ちていた:
///
/// ```
/// delegate_metal.mm:125] Failed to create DelegateKernelLiteRtMetal:
///   UNKNOWN: Failed to allocate id<MTLTexture>.
/// engine.cc:1028] Failed to create conversation: INTERNAL:
///   [runtime/executor/vision_litert_compiled_model_executor.cc:287]
/// ```
///
/// 画像エンコーダが動くのは1枚につき1回(プリフィルの手前)だけなので、ここを
/// CPUに落としても、トークン生成の速度には効かない。
///
/// null のままなら本体と同じバックエンドを使う(パッチ前と同挙動)。
String? litertLmVisionBackend;
