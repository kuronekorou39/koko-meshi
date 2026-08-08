import 'dart:io';

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

  /// 記録に残す端末の素性。iOSは機種識別子と物理メモリまで取る。
  ///
  /// 端末内AIが動くかどうかは実質メモリ量で決まる(モデルが2.4GBあり、iOSは
  /// アプリ1つが使えるメモリを端末のRAMから割った上限で切る)のに、実機から
  /// 回収できる「AIの記録」に端末の情報が無く、ロード失敗の理由が端末なのか
  /// 実装なのか分けられなかった。
  ///
  /// チャネルが無いプラットフォーム(Android)や呼び出し失敗のときはOSの情報
  /// だけを返す。ここで失敗しても解析の流れは止めないこと。
  static Future<String> summary() async {
    final os = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    try {
      final s = await _channel.invokeMethod<String>('deviceSummary');
      if (s != null && s.isNotEmpty) return '$s / $os';
    } catch (_) {
      // 未実装・呼び出し失敗。OSの情報だけで足りることにする
    }
    return os;
  }
}
