import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/app_settings_service.dart';
import '../../services/map_style.dart';
import '../../services/trace_service.dart';
import '../../theme/app_theme.dart';

/// 記録した日時と場所を、時間を進めながら地図の上で再生する。
///
/// 食べた場所が並ぶだけの地図と違って、「いつ・どう動いたか」が見える。
/// 写真から取り出したJSON(tools/trace-extract.html)も読み込めるので、
/// 食事以外も含めた濃い軌跡にできる。
class TraceScreen extends StatefulWidget {
  const TraceScreen({super.key});

  @override
  State<TraceScreen> createState() => _TraceScreenState();
}

class _TraceScreenState extends State<TraceScreen>
    with SingleTickerProviderStateMixin {
  /// 全体を再生しきる長さの選択肢
  static const _durations = <int, String>{
    15: '15秒',
    30: '30秒',
    60: '60秒',
    180: '3分',
  };

  /// 動きのない時間をどこまで見せるか(「間を詰める」がオンのとき)
  static const _stillCap = Duration(minutes: 20);

  /// 軌跡の色。地図は明るい配色なので、テーマの漆をそのまま濃く乗せる
  static const _traceColor = Color(0xFFB0492A);

  /// 先頭とその手前。進んでいる場所を一目で拾えるように明るくする
  static const _traceHeadColor = Color(0xFFFF6B2C);

  /// 追いかけるときの縮尺。街区の移動が分かる程度
  static const _followZoom = 13.5;

  late final AnimationController _controller;
  GoogleMapController? _mapController;

  /// 先頭に置く丸いドット。用意できるまでマーカーは出さない
  BitmapDescriptor? _headIcon;

  /// 再生位置から実際の時刻を引くための時間軸。点や設定が変わったら作り直す
  TraceTimeline? _timeline;

  /// 動きのない時間を詰めるか
  bool _skipStill = true;

  /// 先頭を追いかけるか。
  ///
  /// 全体が入るように引くと、遠出が1本混じっただけで日々の移動が点に潰れて
  /// しまう。既定では寄って追いかけ、全体を見たいときだけ引く。
  bool _follow = true;

  /// カメラを合わせ終えた区間。同じ区間で何度もカメラを動かさないための印
  int _cameraLeg = -1;

  List<TracePoint> _points = [];

  /// 全区間を足した距離。毎フレーム数えずに済むよう読み込み時に出しておく
  double _totalMeters = 0;

  bool _loading = true;
  String? _error;

  /// 読み込んだJSONの名前(アプリの記録を見ているときは null)
  String? _sourceName;

  int _durationSec = 30;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: _durationSec),
    )..addStatusListener((status) {
        // 終わったら再生ボタンの見た目を戻す
        if (status == AnimationStatus.completed) setState(() {});
      })
      ..addListener(_followHead);
    _prepareHeadIcon();
    _load();
  }

  /// 再生に合わせてカメラを動かす。
  ///
  /// 毎フレーム位置を送るとカクつくので、区間(地点から次の地点まで)に入った
  /// ときに一度だけ、その区間の再生時間ぶんのアニメーションを地図に任せる。
  /// 補間はSDK側が60fpsで行うため滑らかに流れる。
  ///
  /// 行き先が今の画面に収まっているなら動かさない。収まっているのに追いかける
  /// と、地図が細かく揺れて見づらいだけになる。
  Future<void> _followHead() async {
    if (!_follow || _points.isEmpty) return;
    final controller = _mapController;
    if (controller == null) return;

    final cursor = TraceService.cursorAt(_points, _currentTime());
    final leg = cursor.legIndex;
    if (leg < 0 || leg == _cameraLeg) return; // 同じ区間には一度だけ
    _cameraLeg = leg;

    final from = _points[leg];
    final to = _points[leg + 1];
    final target = _legBounds(from, to);

    // すでに見えているなら動かさない
    final region = await controller.getVisibleRegion();
    if (_boundsContains(region, target)) return;
    if (!mounted || _cameraLeg != leg) return;

    // 基本は区間の再生時間に合わせる。ただし詰めた停滞のせいで一瞬になる
    // ことがあり、それだと飛んだように見える。距離なりの時間は最低限かける
    final share = (_timeline ??= _buildTimeline())
        .weightOfRange(from.end, to.at)
        .clamp(0.0, 1.0);
    final playMs = (_durationSec * 1000 * share).round();
    final km = TraceService.distanceM(
          from.latitude,
          from.longitude,
          to.latitude,
          to.longitude,
        ) /
        1000;
    final minMs = km < 5
        ? 500
        : km < 50
            ? 800
            : 1200;

    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(target, 72),
      duration: Duration(milliseconds: playMs.clamp(minMs, 2500)),
    );
  }

  /// 区間の両端が入る範囲。同じ場所どうしでつぶれないよう少し広げる
  LatLngBounds _legBounds(TracePoint a, TracePoint b) {
    final minLat = a.latitude < b.latitude ? a.latitude : b.latitude;
    final maxLat = a.latitude > b.latitude ? a.latitude : b.latitude;
    final minLng = a.longitude < b.longitude ? a.longitude : b.longitude;
    final maxLng = a.longitude > b.longitude ? a.longitude : b.longitude;
    // 近所の移動で寄りすぎないよう、最低でもこのくらいの幅を確保する
    const minSpan = 0.004;
    final padLat = ((minSpan - (maxLat - minLat)) / 2).clamp(0.0, minSpan);
    final padLng = ((minSpan - (maxLng - minLng)) / 2).clamp(0.0, minSpan);
    return LatLngBounds(
      southwest: LatLng(minLat - padLat, minLng - padLng),
      northeast: LatLng(maxLat + padLat, maxLng + padLng),
    );
  }

  /// [outer] が [inner] を完全に含むか。日付変更線をまたぐ場合は諦めて false
  bool _boundsContains(LatLngBounds outer, LatLngBounds inner) {
    if (outer.northeast.longitude < outer.southwest.longitude) return false;
    return outer.southwest.latitude <= inner.southwest.latitude &&
        outer.northeast.latitude >= inner.northeast.latitude &&
        outer.southwest.longitude <= inner.southwest.longitude &&
        outer.northeast.longitude >= inner.northeast.longitude;
  }

  @override
  void dispose() {
    _controller.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final points = await TraceService.fromMealLogs();
      if (!mounted) return;
      setState(() {
        _points = points;
        _totalMeters = TraceService.totalDistanceM(points);
        _timeline = null;
        _cameraLeg = -1;
        _sourceName = null;
        _loading = false;
        _error = points.isEmpty ? '場所の記録がまだありません' : null;
      });
      if (points.isNotEmpty) _start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '読み込みに失敗しました: $e';
        });
      }
    }
  }

  /// tools/trace-extract.html で作ったJSONを開く
  Future<void> _openJson() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;

    try {
      final source = await File(path).readAsString();
      final points = TraceService.mergePoints(
        TraceService.parseTraceJson(source),
      );
      if (!mounted) return;
      setState(() {
        _points = points;
        _totalMeters = TraceService.totalDistanceM(points);
        _timeline = null;
        _cameraLeg = -1;
        _sourceName = result!.files.single.name;
        _error = null;
      });
      _fitCamera();
      _start();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込めませんでした: $e')),
        );
      }
    }
  }

  void _start() {
    _controller
      ..duration = Duration(seconds: _durationSec)
      ..forward(from: 0);
    // 地図ができる前は onMapCreated 側で消化する
    _resetCamera();
  }

  void _resetCamera() => _follow ? _zoomToHead() : _fitCamera();

  void _togglePlay() {
    setState(() {
      if (_controller.isAnimating) {
        _controller.stop();
      } else {
        _controller.forward(
          from: _controller.value >= 1 ? 0 : _controller.value,
        );
      }
    });
  }

  /// 動きのない時間を詰めるかを切り替える。
  ///
  /// 見ている時刻を保ったまま切り替えたいので、いまの時刻が新しい時間軸の
  /// どこに当たるかを二分探索で拾い直す。
  void _toggleSkipStill() {
    final now = _currentTime();
    setState(() {
      _skipStill = !_skipStill;
      _timeline = _buildTimeline();
    });

    final timeline = _timeline!;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (timeline.timeAt(mid).isBefore(now)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final wasPlaying = _controller.isAnimating;
    if (wasPlaying) {
      _controller.forward(from: lo);
    } else {
      _controller.value = lo;
    }
  }

  void _setDuration(int sec) {
    setState(() => _durationSec = sec);
    final at = _controller.value;
    _controller.duration = Duration(seconds: sec);
    if (_controller.isAnimating) {
      _controller.forward(from: at);
    }
  }

  /// 追いかけるか、全体を見るかを切り替える
  void _toggleFollow() {
    setState(() => _follow = !_follow);
    if (_follow) {
      _cameraLeg = -1;
      _zoomToHead();
    } else {
      _fitCamera();
    }
  }

  /// 先頭に寄る。日々の移動が読み取れるくらいの縮尺にする
  Future<void> _zoomToHead() async {
    final controller = _mapController;
    if (controller == null || _points.isEmpty) return;
    final head = TraceService.cursorAt(_points, _currentTime()).head;
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(head.latitude, head.longitude),
        _followZoom,
      ),
    );
  }

  /// 全ての点が入るようにカメラを合わせる
  Future<void> _fitCamera() async {
    final controller = _mapController;
    if (controller == null || _points.isEmpty) return;

    var minLat = _points.first.latitude, maxLat = minLat;
    var minLng = _points.first.longitude, maxLng = minLng;
    for (final p in _points) {
      minLat = minLat < p.latitude ? minLat : p.latitude;
      maxLat = maxLat > p.latitude ? maxLat : p.latitude;
      minLng = minLng < p.longitude ? minLng : p.longitude;
      maxLng = maxLng > p.longitude ? maxLng : p.longitude;
    }
    // 1点しかないと境界がつぶれてカメラが決まらないので少し広げる
    const pad = 0.002;
    final bounds = LatLngBounds(
      southwest: LatLng(minLat - pad, minLng - pad),
      northeast: LatLng(maxLat + pad, maxLng + pad),
    );
    try {
      await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 56));
    } catch (_) {
      // 地図の大きさが決まる前だと失敗することがある。次の操作に任せる
    }
  }

  /// いま表示すべき時刻
  DateTime _currentTime() =>
      (_timeline ??= _buildTimeline()).timeAt(_controller.value);

  TraceTimeline _buildTimeline() => TraceTimeline.build(
        _points,
        cap: _skipStill ? _stillCap : null,
      );

  LatLng _toLatLng(TraceLatLng p) => LatLng(p.latitude, p.longitude);

  /// 動いている先頭だけを出す。訪れた場所にピンを残すと、増えるほど地図が
  /// 埋まって肝心の経路が見えなくなる
  Set<Marker> _buildMarkers(TraceCursor cursor) {
    final icon = _headIcon;
    if (icon == null) return const {};
    return {
      Marker(
        markerId: const MarkerId('trace_head'),
        position: _toLatLng(cursor.head),
        icon: icon,
        anchor: const Offset(0.5, 0.5),
        zIndexInt: 2,
      ),
    };
  }

  Set<Polyline> _buildPolylines(TraceCursor cursor) {
    if (cursor.path.length < 2) return const {};
    final path = cursor.path.map(_toLatLng).toList();

    // 直近の区間だけ明るく重ねる。通った跡はしっかり残したいので、古い方も
    // 薄くしすぎない(この画面は軌跡そのものを見るためのもの)
    const recentLegs = 6;
    final tail =
        path.length > recentLegs ? path.sublist(path.length - recentLegs) : path;

    return {
      // 白の下敷き。地図の地色や道路の上でも線の輪郭が立つ
      Polyline(
        polylineId: const PolylineId('trace_outline'),
        points: path,
        color: Colors.white.withValues(alpha: 0.9),
        width: 9,
        geodesic: true,
      ),
      Polyline(
        polylineId: const PolylineId('trace_past'),
        points: path,
        color: _traceColor,
        width: 5,
        zIndex: 1,
        geodesic: true,
      ),
      Polyline(
        polylineId: const PolylineId('trace_recent'),
        points: tail,
        color: _traceHeadColor,
        width: 6,
        zIndex: 2,
        geodesic: true,
      ),
    };
  }

  /// 先頭に置く丸いドット。既定のピンは影と尖りで場所を指すので、動いている
  /// ものには合わない
  Future<void> _prepareHeadIcon() async {
    const size = 38.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const center = Offset(size / 2, size / 2);

    // 外側のにじみ → 白フチ → 芯。地図の上でも埋もれないように三重にする
    canvas.drawCircle(
      center,
      size / 2,
      Paint()..color = _traceHeadColor.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      center,
      size / 3.4,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      size / 3.4 - 3.5,
      Paint()..color = _traceHeadColor,
    );

    final image = await recorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || !mounted) return;
    setState(() {
      _headIcon = BitmapDescriptor.bytes(bytes.buffer.asUint8List());
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('軌跡'),
        actions: [
          IconButton(
            icon: Icon(
              _follow ? Icons.my_location : Icons.zoom_out_map,
              color: _follow ? _traceColor : null,
            ),
            tooltip: _follow ? '現在地を追いかけている' : '全体を表示している',
            onPressed: _points.isEmpty ? null : _toggleFollow,
          ),
          IconButton(
            icon: Icon(
              _skipStill ? Icons.compress : Icons.schedule,
              color: _skipStill ? _traceColor : null,
            ),
            tooltip: _skipStill ? '止まっている時間を詰めている' : '実際の時間で流している',
            onPressed: _points.isEmpty ? null : _toggleSkipStill,
          ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'JSONを開く',
            onPressed: _openJson,
          ),
          if (_sourceName != null)
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: '記録に戻す',
              onPressed: _load,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _points.isEmpty
              ? _buildEmpty(tokens)
              : AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final now = _currentTime();
                    final cursor = TraceService.cursorAt(_points, now);
                    return Stack(
                      children: [
                        GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: LatLng(
                              _points.first.latitude,
                              _points.first.longitude,
                            ),
                            zoom: 12,
                          ),
                          markers: _buildMarkers(cursor),
                          polylines: _buildPolylines(cursor),
                          style: buildMapStyle(AppSettings.mapLabelLayers),
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,
                          compassEnabled: false,
                          onMapCreated: (controller) {
                            _mapController = controller;
                            _resetCamera();
                          },
                        ),
                        _buildHud(now, cursor),
                        _buildControls(),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _buildEmpty(KokoTokens tokens) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timeline, size: 48, color: tokens.textFaint),
            const SizedBox(height: 16),
            Text(
              _error ?? '場所の記録がまだありません',
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.textMuted),
            ),
            const SizedBox(height: 8),
            Text(
              '位置情報のついた食事を記録するか、写真から作ったJSONを開いてください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: tokens.textFaint),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: const Text('JSONを開く'),
              onPressed: _openJson,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHud(DateTime now, TraceCursor cursor) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final date = '${now.year}/${_two(now.month)}/${_two(now.day)}'
        '（${weekdays[now.weekday - 1]}）';

    return Positioned(
      top: 12,
      left: 12,
      child: IgnorePointer(
        // 地図と軌跡の上に重なるので、下地を敷かないと色によって読めなくなる
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 14, 9),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                date,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    TraceService.formatDistance(cursor.traveledMeters),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _traceHeadColor,
                    ),
                  ),
                  Text(
                    ' / ${TraceService.formatDistance(_totalMeters)}',
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                '${_two(now.hour)}:${_two(now.minute)}'
                ' ・ ${cursor.visitedCount} / ${_points.length} 地点'
                '${cursor.moving ? ' ・ 移動中' : ''}'
                '${_sourceName != null ? ' ・ $_sourceName' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final playing = _controller.isAnimating;
    return Positioned(
      left: 12,
      right: 12,
      // 地図は画面いっぱいに敷くので、ジェスチャーバーやナビゲーションバーの
      // 下に潜り込まないよう自分でよける
      bottom: 12 + context.systemBottomInset,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                tooltip: playing ? '一時停止' : '再生',
                onPressed: _togglePlay,
              ),
              IconButton(
                icon: const Icon(Icons.replay),
                tooltip: '最初から',
                onPressed: () {
                  _cameraLeg = -1;
                  _controller.forward(from: 0);
                  _resetCamera();
                },
              ),
              Expanded(
                child: Slider(
                  value: _controller.value.clamp(0.0, 1.0),
                  onChanged: (v) {
                    _controller.stop();
                    // 飛んだ先は続きではないので、カメラも合わせ直す
                    _cameraLeg = -1;
                    _controller.value = v;
                  },
                ),
              ),
              PopupMenuButton<int>(
                tooltip: '再生の長さ',
                initialValue: _durationSec,
                onSelected: _setDuration,
                itemBuilder: (context) => [
                  for (final entry in _durations.entries)
                    PopupMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_durations[_durationSec] ?? ''),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _two(int n) => n.toString().padLeft(2, '0');
}
