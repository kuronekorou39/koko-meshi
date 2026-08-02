import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// この端末で何ができるか。いまは端末内AIが動くかどうかだけ。
///
/// 端末内AIの実体(LiteRT-LM)は Android では arm64-v8a 版しか無い。32bit端末を
/// 弾いてしまえば話は早いが、このアプリの本体は食事の記録であって、AIはその
/// 補助でしかない。AI解析オフのモードも元からあるので、32bit端末では
/// 「AIだけ使えないアプリ」として動かす。
///
/// iOS は arm64 のみなのでこの区別が要らず、常に対応として扱う。
class DeviceCapability {
  DeviceCapability._();

  static const _channel = MethodChannel('com.kokomeshi.koko_meshi/device');

  static bool _onDeviceAi = true;

  /// 端末内AIが使えるか。
  ///
  /// 既定は true。判定できなかったとき(チャネル未実装のプラットフォーム、
  /// 呼び出し失敗)に機能を潰してしまうより、従来どおり動かして実際の
  /// ロード失敗に任せるほうが安全側になる。
  static bool get onDeviceAi => _onDeviceAi;

  /// 起動時に一度だけ確認する。端末が変わることは無いので以後は使い回す。
  ///
  /// 確認するのは Android だけ。32bit端末という区別があるのは Android の
  /// 話で、iOS は arm64 しか無いため常に対応している(CIのビルドでも
  /// LiteRtLm.framework と LiteRtMetalAccelerator.framework が
  /// 同梱されることを確認済み)。
  static Future<void> init() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final ok = await _channel.invokeMethod<bool>('isOnDeviceAiSupported');
      if (ok != null) _onDeviceAi = ok;
      if (!_onDeviceAi) {
        debugPrint('[Device] 端末内AI非対応(LiteRT-LMのライブラリが無い)');
      }
    } catch (e) {
      debugPrint('[Device] 端末内AIの対応確認に失敗: $e');
    }
  }
}
