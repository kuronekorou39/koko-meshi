import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../theme/app_theme.dart';

/// オンデバイス Gemma 4 (vision) の実機PoC画面。
/// E2B / E4B の両方を個別にDLでき、どちらをロードするか選べる。
class GemmaPocScreen extends StatefulWidget {
  const GemmaPocScreen({super.key});

  @override
  State<GemmaPocScreen> createState() => _GemmaPocScreenState();
}

class _GemmaPocScreenState extends State<GemmaPocScreen> {
  final _svc = GemmaOnDeviceService.instance;
  final _mgr = GemmaDownloadManager.instance;
  final _picker = ImagePicker();

  /// DL状態とインストール済みフラグ(全モデル分)の変化をまとめて購読する
  late final Listenable _mgrListenable = Listenable.merge([
    for (final k in GemmaModelKind.values) ...[
      _mgr.stateOf(k),
      _mgr.installedOf(k),
    ],
  ]);

  final Map<GemmaModelKind, List<int>> _latencies = {
    for (final k in GemmaModelKind.values) k: [],
  };

  GemmaModelKind? _busyKind; // ロード中のモデル
  bool _analyzing = false;
  GemmaModelKind? _loadedKind;
  int? _loadMs;
  String _status = '';

  File? _lastImage;
  GemmaAnalysisResult? _result;

  bool _selfTesting = false;
  int _selfTestDone = 0;
  GemmaSelfTestResult? _selfTest;

  bool get _downloading =>
      GemmaModelKind.values.any((k) => _mgr.stateOf(k).value.downloading);

  bool get _busy =>
      _busyKind != null || _analyzing || _selfTesting || _downloading;

  @override
  void initState() {
    super.initState();
    for (final k in GemmaModelKind.values) {
      _mgr.refreshInstalled(k);
    }
  }

  Future<void> _install(GemmaModelKind k) async {
    setState(() => _status = '${k.label} をDL中（${k.approxSize}）...');
    try {
      final src = await _mgr.download(k);
      if (mounted) {
        setState(() {
          _status = src == GemmaInstallSource.localFile
              ? '${k.label} 準備完了（端末内ファイルから）'
              : '${k.label} DL完了（ネットワーク）';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '${k.label} DL失敗: $e');
    }
  }

  Future<void> _load(GemmaModelKind k) async {
    setState(() {
      _busyKind = k;
      _status = '${k.label} をロード中...';
    });
    try {
      final ms = await _svc.load(k);
      if (mounted) {
        setState(() {
          _loadedKind = k;
          _loadMs = ms;
          _status = '${k.label} ロード完了（${ms}ms）';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '${k.label} ロード失敗: $e');
    } finally {
      if (mounted) setState(() => _busyKind = null);
    }
  }

  Future<void> _runSelfTest() async {
    final loaded = _loadedKind;
    if (loaded == null) return;
    setState(() {
      _selfTesting = true;
      _selfTestDone = 0;
      _selfTest = null;
      _status = '${loaded.label} で端末動作テスト中...';
    });
    try {
      final res = await _svc.runSelfTest(
        onProgress: (done, total) {
          if (mounted) setState(() => _selfTestDone = done);
        },
      );
      if (mounted) {
        setState(() {
          _selfTest = res;
          for (final r in res.results) {
            if (r.modelKind != null) _latencies[r.modelKind]!.add(r.inferenceMs);
          }
          _status = '動作テスト完了（平均 ${res.avgSeconds.toStringAsFixed(1)}s/枚）';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '動作テスト失敗: $e');
    } finally {
      if (mounted) setState(() => _selfTesting = false);
    }
  }

  Future<void> _pickAndAnalyze(ImageSource source) async {
    final loaded = _loadedKind;
    if (loaded == null) return;
    final x = await _picker.pickImage(source: source);
    if (x == null) return;
    setState(() {
      _analyzing = true;
      _lastImage = File(x.path);
      _result = null;
      _status = '${loaded.label} で解析中...';
    });
    try {
      final bytes = await File(x.path).readAsBytes();
      final res = await _svc.analyze(bytes);
      if (mounted) {
        setState(() {
          _result = res;
          if (res.modelKind != null) _latencies[res.modelKind]!.add(res.inferenceMs);
          _status = '解析完了（${res.inferenceMs}ms）';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '解析失敗: $e');
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('オンデバイスGemma PoC')),
      // DL進捗はGemmaDownloadManagerが画面をまたいで保持しているので、
      // 画面を離れて戻ってもここで購読し直すだけで進捗表示が復元される
      body: ListenableBuilder(
        listenable: _mgrListenable,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('モデルを選んでロード', style: tokens.sectionLabel),
            const SizedBox(height: 8),
            ...GemmaModelKind.values.map(_buildModelCard),

            const SizedBox(height: 12),
            // 端末動作テスト（バンドル画像3枚・ギャラリー不要で確実に測れる）
            FilledButton.icon(
              onPressed: _busy || _loadedKind == null ? null : _runSelfTest,
              icon: const Icon(Icons.speed_outlined),
              label: Text(
                _selfTesting ? 'テスト中... ($_selfTestDone/3)' : 'この端末で動作テスト（3枚）',
              ),
            ),
            if (_selfTest != null) _buildVerdict(_selfTest!),

            const SizedBox(height: 16),
            Text('自分の写真で試す', style: tokens.sectionLabel),
            const SizedBox(height: 8),
            // 解析
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _loadedKind == null
                        ? null
                        : () => _pickAndAnalyze(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('写真から'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _loadedKind == null
                        ? null
                        : () => _pickAndAnalyze(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('撮影'),
                  ),
                ),
              ],
            ),
            if (_loadedKind == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('先にモデルをロードしてください',
                    style: TextStyle(color: tokens.textFaint, fontSize: 12)),
              ),

            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_status,
                    style: TextStyle(color: tokens.textMuted, fontSize: 13)),
              ),

            if (_lastImage != null) ...[
              const Divider(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(_lastImage!,
                    height: 220, width: double.infinity, fit: BoxFit.cover),
              ),
              const SizedBox(height: 12),
            ],
            if (_result != null) _buildResult(_result!),

            // モデル別の推論速度サマリ
            ..._latencies.entries
                .where((e) => e.value.length >= 2)
                .map((e) => _buildLatencySummary(e.key, e.value)),
          ],
        ),
      ),
    );
  }

  Widget _buildModelCard(GemmaModelKind k) {
    final tokens = KokoTokens.of(context);
    final installed = _mgr.installedOf(k).value ?? false;
    final dl = _mgr.stateOf(k).value;
    final loaded = _loadedKind == k;
    final downloading = dl.downloading;

    Widget action;
    if (!installed) {
      action = FilledButton.tonal(
        onPressed: _busy ? null : () => _install(k),
        child: Text('DL（${k.approxSize}）'),
      );
    } else if (loaded) {
      action = Chip(
        avatar: Icon(Icons.check_circle, color: tokens.success, size: 18),
        label: const Text('ロード済み'),
      );
    } else {
      action = FilledButton(
        onPressed: _busy ? null : () => _load(k),
        child: const Text('ロード'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${k.label}  ',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          '${k.note} ・ ${installed ? "インストール済" : "未DL ${k.approxSize}"}'
                          '${loaded && _loadMs != null ? " ・ ロード ${_loadMs}ms" : ""}',
                          style:
                              TextStyle(fontSize: 12, color: tokens.textMuted),
                        ),
                      ],
                    ),
                  ),
                  action,
                ],
              ),
              if (downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: dl.progress / 100),
                      Text(
                        '${dl.progress}%',
                        style: tokens.numeral
                            .copyWith(fontSize: 12, color: tokens.textMuted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerdict(GemmaSelfTestResult t) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color color, IconData icon) = switch (t.verdict) {
      GemmaDeviceVerdict.smooth => (
          'この端末で快適に動作します',
          tokens.success,
          Icons.check_circle_outline,
        ),
      GemmaDeviceVerdict.usable => (
          'この端末で実用的に動作します',
          tokens.success,
          Icons.check_circle_outline,
        ),
      GemmaDeviceVerdict.slow => (
          '動作しますが遅めです',
          tokens.warning,
          Icons.warning_amber,
        ),
      GemmaDeviceVerdict.unstable => (
          '不安定（一部パース失敗）',
          scheme.error,
          Icons.error_outline,
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: color.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: color)),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                '${t.modelKind?.label ?? "-"} ・ 平均 ${t.avgSeconds.toStringAsFixed(1)}s/枚 ・ '
                'JSON成功 ${t.parseOk}/${t.count}',
                style: tokens.numeral.copyWith(fontSize: 13),
              ),
              const Divider(height: 16),
              ...List.generate(t.results.length, (i) {
                final r = t.results[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${i + 1}. ${r.menuName ?? "パース失敗"}'
                    '${r.parsed != null ? " ・ ${r.genre} ・ ${r.price}円 ・ ${r.calories}kcal" : ""}'
                    ' ・ ${(r.inferenceMs / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(fontSize: 13),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResult(GemmaAnalysisResult r) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${r.modelKind?.label ?? "-"} ・ 推論 ${(r.inferenceMs / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(r.parsed != null ? 'JSON OK' : 'パース失敗',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color:
                            r.parsed != null ? tokens.success : scheme.error)),
              ],
            ),
            const SizedBox(height: 8),
            if (r.parsed != null) ...[
              Text(r.menuName ?? '-',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(
                '${r.genre ?? "-"} ・ ${r.price ?? "-"}円 ・ ${r.calories ?? "-"}kcal',
                style: tokens.numeral.copyWith(fontSize: 14),
              ),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('raw',
                  style: TextStyle(fontSize: 12, color: tokens.textMuted)),
              children: [
                Text(r.rawText,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLatencySummary(GemmaModelKind k, List<int> ms) {
    final tokens = KokoTokens.of(context);
    final avg = ms.reduce((a, b) => a + b) / ms.length / 1000;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${k.label} 推論速度（実機）: ${ms.length}回',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '各回: ${ms.map((e) => "${(e / 1000).toStringAsFixed(1)}s").join(", ")}',
            style: tokens.numeral
                .copyWith(fontSize: 13, color: tokens.textMuted),
          ),
          Text(
            '平均: ${avg.toStringAsFixed(1)}s/枚',
            style: tokens.numeral
                .copyWith(fontSize: 13, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}
