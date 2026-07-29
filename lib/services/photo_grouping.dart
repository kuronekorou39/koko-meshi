import 'package:geolocator/geolocator.dart';

import '../config/constants.dart';

/// グループ化の判定に使う情報だけを取り出したもの。
/// 画面側の型に依存させないための入力。
class GroupableShot {
  const GroupableShot({this.shotAt, this.latitude, this.longitude});

  final DateTime? shotAt;
  final double? latitude;
  final double? longitude;

  bool get hasPosition => latitude != null && longitude != null;
}

/// 選んだ写真を「1つの食事」ごとに分ける。返すのは元のリストのindexの束。
///
/// ライブラリから複数枚まとめて取り込むと、別の日・別の店の食事が混ざる。
/// それを1つの記録にしてしまうと、日時も場所も一番古い写真のものに揃えられ、
/// 他の写真の情報が記録として失われる。撮影時刻と場所で切り分ける。
///
/// 閾値はマップのグルーピングと同じものを使う([AppConstants])。同じ食事の
/// 判定基準が画面によって違うと、一覧とマップで食い違って見える。
///
/// 判定は隣り合う写真どうしで見る(単連結)。店の中を移動しながら撮った
/// 数枚が、端と端だけを比べたせいで分かれてしまわないようにするため。
///
/// **撮影日時を持たない写真は、1枚ずつ別の組にする。** EXIFの無い写真
/// (保存した画像・スクリーンショット・メッセージ経由の画像など)は珍しく
/// なく、それらをまとめてしまうと、日付も場所も無関係な写真が勝手に1つの
/// 食事にされる。同じ食事だと確かめられないものを束ねてはいけない。
/// まとめたいときは利用者が画面で指定する。
List<List<int>> groupShots(List<GroupableShot> shots) {
  if (shots.isEmpty) return const [];

  final dated = <int>[];
  final undated = <int>[];
  for (var i = 0; i < shots.length; i++) {
    (shots[i].shotAt != null ? dated : undated).add(i);
  }

  dated.sort((a, b) => shots[a].shotAt!.compareTo(shots[b].shotAt!));

  final groups = <List<int>>[];
  for (final index in dated) {
    if (groups.isEmpty || _startsNewGroup(shots[groups.last.last], shots[index])) {
      groups.add([index]);
    } else {
      groups.last.add(index);
    }
  }

  // 日時が無いものは同じ食事だと確かめる手立てが無いので、1枚ずつ独立させる
  for (final index in undated) {
    groups.add([index]);
  }
  return groups;
}

/// [next] を [previous] と別の食事として扱うか
bool _startsNewGroup(GroupableShot previous, GroupableShot next) {
  final gap = next.shotAt!.difference(previous.shotAt!).abs();
  if (gap.inMinutes > AppConstants.groupingTimeWindowHours * 60) return true;

  // 位置はどちらも持っているときだけ見る。EXIFにGPSが無い写真は多いので、
  // 片方でも欠けていたら時間の判定に任せる
  if (previous.hasPosition && next.hasPosition) {
    final distance = Geolocator.distanceBetween(
      previous.latitude!,
      previous.longitude!,
      next.latitude!,
      next.longitude!,
    );
    if (distance > AppConstants.groupingRadiusMeters) return true;
  }
  return false;
}
