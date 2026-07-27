import 'package:flutter/material.dart';

/// 写真の上に文字を載せるための下部グラデーション(スクリム)。
///
/// デザインシステムでは装飾目的のグラデーションを使わない方針だが、
/// 写真上のテキストの可読性確保だけは例外として認めている。
/// 装飾として面や区切りにグラデーションを使うことは引き続きしない。
///
/// 高さは中身に追従する(固定高にしない)ので、フォントスケールを大きくしても
/// テキストがスクリムからはみ出さない。
class PhotoScrim extends StatelessWidget {
  const PhotoScrim({
    super.key,
    required this.child,
    required this.padding,
  });

  final Widget child;

  /// 中身の余白。上側の余白がそのままフェード領域の厚みになる。
  final EdgeInsets padding;

  /// 写真上に置くテキストの色(スクリムが暗いのでテーマ非依存の白)
  static const Color textColor = Colors.white;

  /// 同・二次テキスト(価格や時刻などのメタ情報)
  static const Color mutedTextColor = Color(0xD9FFFFFF);

  /// 同・異常を示すテキスト(解析失敗など)。スクリムは常に暗いので、
  /// テーマの error ではなくダークテーマ側の朱(_errorNight)に合わせる
  static const Color errorTextColor = Color(0xFFE29181);

  /// スクリムを外れた位置にテキストが伸びたときの保険。
  /// 通常はスクリムだけで足りるので、ごく控えめにかける。
  static const List<Shadow> textShadows = [
    Shadow(color: Color(0x8A000000), blurRadius: 8),
  ];

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // 2行タイトルでも1行目が十分暗い下地に載るよう、早めに立ち上げる
          colors: [
            scrim.withValues(alpha: 0),
            scrim.withValues(alpha: 0.48),
            scrim.withValues(alpha: 0.86),
          ],
          stops: const [0, 0.42, 1],
        ),
      ),
      child: child,
    );
  }
}
