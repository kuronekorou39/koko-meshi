import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geocoding/geocoding.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../providers/meal_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/backup_service.dart';
import '../../services/cloud_photo_rescue.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../theme/app_theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];
  String _appVersion = '';

  /// AIで自動解析するか(= 端末内Gemmaを使うか)
  bool _aiEnabled = true;

  /// クラウドにしか無く未取り込みの写真数(>0のときだけ取り込み導線を出す)
  int _cloudPending = 0;

  @override
  void initState() {
    super.initState();
    _aiEnabled = AppSettings.aiMode == AiAnalysisMode.onDevice;
    _loadSavedPlaces();
    _loadVersion();
    _loadCloudPending();
    GemmaDownloadManager.instance.refreshInstalled(GemmaModelKind.e2b);
  }

  Future<void> _setAiEnabled(bool enabled) async {
    await AppSettings.setAiMode(
        enabled ? AiAnalysisMode.onDevice : AiAnalysisMode.off);
    if (mounted) setState(() => _aiEnabled = enabled);
  }

  Future<void> _downloadModel() async {
    try {
      await GemmaDownloadManager.instance.download(GemmaModelKind.e2b);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('モデルのダウンロードに失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  Future<void> _loadSavedPlaces() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (mounted) setState(() => _savedPlaces = places);
  }

  Future<void> _loadCloudPending() async {
    try {
      final n = await CloudPhotoRescue.pendingCount();
      if (mounted) setState(() => _cloudPending = n);
    } catch (_) {}
  }

  Future<void> _deleteSavedPlace(SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('場所を削除'),
          content: Text('「${place.name}」を削除しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await LocalDatabase.deleteSavedPlace(place.id);
      _loadSavedPlaces();
    }
  }

  IconData _iconForType(String iconType) {
    return switch (iconType) {
      'home' => Icons.home_outlined,
      'favorite' => Icons.star_outline,
      _ => Icons.place_outlined,
    };
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;
      final parts = <String>[
        if (p.administrativeArea?.isNotEmpty == true) p.administrativeArea!,
        if (p.locality?.isNotEmpty == true) p.locality!,
        if (p.subLocality?.isNotEmpty == true) p.subLocality!,
        if (p.thoroughfare?.isNotEmpty == true) p.thoroughfare!,
        if (p.subThoroughfare?.isNotEmpty == true) p.subThoroughfare!,
      ];
      return parts.isEmpty ? null : parts.join('');
    } catch (_) {
      return null;
    }
  }

  // ─── バックアップと移行 ───

  Future<void> _exportBackup() async {
    _showBlockingProgress('バックアップを作成しています…');
    String? zipPath;
    try {
      zipPath = await BackupService.export();
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('バックアップの作成に失敗しました: $e')),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;

    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipPath)],
          text: 'ココメシのバックアップ',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('共有に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    if (!path.toLowerCase().endsWith('.zip')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('zipファイルを選んでください')),
      );
      return;
    }

    final manifest = await BackupService.readManifest(path);
    if (!mounted) return;
    if (manifest == null ||
        manifest.formatVersion != BackupService.currentFormatVersion) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('このアプリで読み込めるバックアップではありません')),
      );
      return;
    }

    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックアップから復元'),
        content: Text(
          'この端末の現在の記録・写真・設定は、すべてバックアップの内容に'
          '置き換えられます。この操作は取り消せません。\n\n'
          'バックアップ日時: ${manifest.exportedAt.replaceFirst('T', ' ').split('.').first}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('復元する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    _showBlockingProgress('復元しています…');
    try {
      await BackupService.restore(path);
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      ref.invalidate(mealLogsProvider);
      _loadSavedPlaces();
      _loadCloudPending();
      setState(() => _aiEnabled = AppSettings.aiMode == AiAnalysisMode.onDevice);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('復元が完了しました'),
          content: const Text(
            'バックアップを読み込みました。表示を確実に反映するため、'
            'アプリを一度再起動することをおすすめします。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('復元に失敗しました（元のデータは保持されています）: $e')),
        );
      }
    }
  }

  Future<void> _rescueCloudPhotos() async {
    final progress = ValueNotifier<String>('準備しています…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (context, v, child) => Text(v),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      final result = await CloudPhotoRescue.rescueAll(
        onProgress: (d, t) =>
            progress.value = 'クラウドの写真を取り込み中… ($d/$t)',
      );
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      ref.invalidate(mealLogsProvider);
      _loadCloudPending();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('取り込み完了'),
          content: Text(
            '${result.rescued}枚を取り込みました'
            '${result.failed > 0 ? '（${result.failed}枚は取得できませんでした）' : ''}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取り込みに失敗しました: $e')),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  void _showBlockingProgress(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _sectionLabel('AI自動解析'),
          _buildAiSection(),

          _sectionLabel('バックアップ'),
          _sectionCard([
            ListTile(
              leading: const Icon(Icons.save_alt_outlined),
              title: const Text('バックアップを作成'),
              subtitle: const Text('すべての記録と写真をファイルに書き出して保存'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _exportBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('バックアップから復元'),
              subtitle: const Text('書き出したファイルを読み込む（現在のデータは置き換わります）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _importBackup,
            ),
            // クラウドに未取り込みの写真が残っているときだけ出す(移行用)
            if (_cloudPending > 0)
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('以前の写真を取り込む'),
                subtitle: Text('$_cloudPending 枚がまだこの端末にありません。タップして取り込み'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _rescueCloudPhotos,
              ),
          ]),

          _sectionLabel('保存した場所'),
          _sectionCard(
            _savedPlaces.isEmpty
                ? [
                    const ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('保存した場所はありません'),
                      subtitle: Text('マップ画面から登録できます'),
                    ),
                  ]
                : _savedPlaces
                    .map((place) => ListTile(
                          leading: Icon(_iconForType(place.iconType)),
                          title: Text(place.name),
                          subtitle: FutureBuilder<String?>(
                            future:
                                _reverseGeocode(place.latitude, place.longitude),
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return Text(
                                  snapshot.data!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                              }
                              return Text(
                                '${place.latitude.toStringAsFixed(4)}, ${place.longitude.toStringAsFixed(4)}',
                              );
                            },
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteSavedPlace(place),
                          ),
                        ))
                    .toList(),
          ),

          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Center(
              child: Text(
                'ココメシ v$_appVersion',
                style: TextStyle(fontSize: 12, color: tokens.textFaint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(text, style: KokoTokens.of(context).sectionLabel),
    );
  }

  Widget _sectionCard(List<Widget> tiles) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const Divider(indent: 16, endIndent: 16),
            tiles[i],
          ],
        ],
      ),
    );
  }

  /// AI自動解析セクション。トグル1つ + (オンでモデル未DLなら)ダウンロード案内。
  Widget _buildAiSection() {
    return _sectionCard([
      SwitchListTile(
        secondary: const Icon(Icons.auto_awesome_outlined),
        title: const Text('AIで自動解析する'),
        subtitle: const Text('料理名・価格・カロリーを端末内で自動推定'
            '（オフライン・無料・写真は外部送信なし）'),
        value: _aiEnabled,
        onChanged: _setAiEnabled,
      ),
      if (_aiEnabled) _buildModelStatusTile(),
    ]);
  }

  /// モデルのDL状態に応じた案内タイル。進捗はGemmaDownloadManagerが保持する
  /// ので、DL中に画面を離れて戻っても復元される。
  Widget _buildModelStatusTile() {
    final mgr = GemmaDownloadManager.instance;
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<GemmaDownloadState>(
      valueListenable: mgr.stateOf(GemmaModelKind.e2b),
      builder: (context, dl, _) {
        if (dl.downloading) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                      value: dl.progress / 100, minHeight: 6),
                ),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'AIモデルを準備中 '),
                      TextSpan(
                        text: '${dl.progress}%',
                        style: tokens.numeral.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                  style: TextStyle(fontSize: 12, color: tokens.textMuted),
                ),
              ],
            ),
          );
        }
        return ValueListenableBuilder<bool?>(
          valueListenable: mgr.installedOf(GemmaModelKind.e2b),
          builder: (context, installed, _) {
            if (installed == true) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: tokens.success),
                    const SizedBox(width: 6),
                    Text('AIモデルの準備ができています',
                        style:
                            TextStyle(fontSize: 12, color: tokens.textMuted)),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AIを使うには、最初に一度モデルのダウンロードが必要です。',
                    style: TextStyle(fontSize: 12, color: tokens.textMuted),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _downloadModel,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(
                        'AIモデルをダウンロード（${GemmaModelKind.e2b.approxSize}・Wi-Fi推奨）',
                      ),
                    ),
                  ),
                  if (dl.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        dl.error!,
                        style: TextStyle(fontSize: 12, color: scheme.error),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
