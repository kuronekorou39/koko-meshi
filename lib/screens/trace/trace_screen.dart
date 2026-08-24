import 'dart:async';
import 'dart:io';

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

  /// 直近の点を強めに出す窓。全期間に対する割合
  static const _recentWindowRatio = 0.06;

  late final AnimationController _controller;
  GoogleMapController? _mapController;

  List<TracePoint> _points = [];
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
      });
    _load();
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
    // カメラを全体が入る位置へ。地図ができる前は onMapCreated 側で消化する
    _fitCamera();
  }

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

  void _setDuration(int sec) {
    setState(() => _durationSec = sec);
    final at = _controller.value;
    _controller.duration = Duration(seconds: sec);
    if (_controller.isAnimating) {
      _controller.forward(from: at);
    }
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
  DateTime _currentTime() {
    final first = _points.first.at;
    final span = _points.last.end.difference(first);
    return first.add(
      Duration(
        milliseconds: (span.inMilliseconds * _controller.value).round(),
      ),
    );
  }

  /// 出現済みの点(時刻順)
  List<TracePoint> _visible(DateTime now) =>
      _points.where((p) => !p.at.isAfter(now)).toList();

  Set<Marker> _buildMarkers(List<TracePoint> visible, DateTime now) {
    final span = _points.last.end.difference(_points.first.at);
    final recentMs = span.inMilliseconds * _recentWindowRatio;
    final markers = <Marker>{};

    for (var i = 0; i < visible.length; i++) {
      final p = visible[i];
      final ageMs = now.difference(p.at).inMilliseconds.toDouble();
      final fresh = recentMs > 0 && ageMs < recentMs;
      final isLast = i == visible.length - 1;

      markers.add(
        Marker(
          markerId: MarkerId('trace_$i'),
          position: LatLng(p.latitude, p.longitude),
          // 古い点は薄く沈めて、いま進んでいる場所を目立たせる
          alpha: isLast ? 1.0 : (fresh ? 0.85 : 0.45),
          zIndexInt: isLast ? 2 : (fresh ? 1 : 0),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            isLast
                ? BitmapDescriptor.hueOrange
                : (p.fromApp
                    ? BitmapDescriptor.hueRed
                    : BitmapDescriptor.hueCyan),
          ),
          infoWindow: p.label != null
              ? InfoWindow(title: p.label)
              : InfoWindow.noText,
        ),
      );
    }
    return markers;
  }

  Set<Polyline> _buildPolylines(List<TracePoint> visible) {
    if (visible.length < 2) return const {};
    return {
      Polyline(
        polylineId: const PolylineId('trace'),
        points: [
          for (final p in visible) LatLng(p.latitude, p.longitude),
        ],
        color: const Color(0xFFFFB35C),
        width: 3,
        geodesic: true,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('軌跡'),
        actions: [
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
                    final visible = _visible(now);
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
                          markers: _buildMarkers(visible, now),
                          polylines: _buildPolylines(visible),
                          style: buildMapStyle(AppSettings.mapLabelLayers),
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,
                          compassEnabled: false,
                          onMapCreated: (controller) {
                            _mapController = controller;
                            _fitCamera();
                          },
                        ),
                        _buildHud(now, visible.length),
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

  Widget _buildHud(DateTime now, int shown) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final date = '${now.year}/${_two(now.month)}/${_two(now.day)}'
        '（${weekdays[now.weekday - 1]}）';

    return Positioned(
      top: 12,
      left: 16,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _shadowed(
              date,
              const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            _shadowed(
              '$shown / ${_points.length} 地点'
              '${_sourceName != null ? ' ・ $_sourceName' : ''}',
              const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shadowed(String text, TextStyle style) => Text(
        text,
        style: style.copyWith(
          shadows: const [
            Shadow(blurRadius: 6, color: Colors.black87),
            Shadow(blurRadius: 2, color: Colors.black54),
          ],
        ),
      );

  Widget _buildControls() {
    final playing = _controller.isAnimating;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
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
                onPressed: () => _controller.forward(from: 0),
              ),
              Expanded(
                child: Slider(
                  value: _controller.value.clamp(0.0, 1.0),
                  onChanged: (v) {
                    _controller.stop();
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
