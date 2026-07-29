import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geocoding/geocoding.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../providers/app_settings_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/backup_service.dart';
import '../../services/device_capability.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import 'analysis_bench_screen.dart';
import 'font_settings_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];
  String _appVersion = '';

  /// 出ている新しいバージョン(無ければ null)
  AppUpdate? _update;
  bool _checkingUpdate = false;

  /// AIで自動解析するか(= 端末内Gemmaを使うか)
  bool _aiEnabled = true;

  @override
  void initState() {
    super.initState();
    _aiEnabled = AppSettings.aiMode == AiAnalysisMode.onDevice;
    _loadSavedPlaces();
    _loadVersion();
    _checkUpdate();
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

  Future<void> _checkUpdate({bool force = false}) async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final update = await UpdateService.check(force: force);
    if (!mounted) return;
    setState(() {
      _update = update;
      _checkingUpdate = false;
    });
    if (force && update == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('お使いのバージョンが最新です')),
      );
    }
  }

  Future<void> _openUpdatePage() async {
    final update = _update;
    if (update == null) return;
    await launchUrl(Uri.parse(update.url), mode: LaunchMode.externalApplication);
  }

  Future<void> _loadSavedPlaces() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (mounted) setState(() => _savedPlaces = places);
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
    // 何が書き出されるのか(写真も含む=ファイルが大きい)は、一覧に常時
    // 書いておくより、実行する直前に伝えたほうが読まれる
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックアップを作成'),
        content: const Text(
          'すべての記録・写真・設定を1つのzipファイルに書き出します。\n\n'
          '写真を含むので、記録が多いとファイルは数百MBになります。'
          '作成後に共有先を選んで保存してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('作成する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

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
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + context.systemBottomInset),
        children: [
          _sectionLabel('AI自動解析'),
          _buildAiSection(),

          _sectionLabel('表示'),
          _sectionCard([
            ListTile(
              leading: const Icon(Icons.text_fields_outlined),
              title: const Text('フォント'),
              subtitle: Text(ref.watch(appFontProvider).label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FontSettingsScreen()),
              ),
            ),
          ]),

          // 何をする項目かは名前で分かる。詳しい説明は実行するかを尋ねる
          // ダイアログ側に置いて、一覧は読まずに見渡せるようにする
          _sectionLabel('バックアップ'),
          _sectionCard([
            ListTile(
              leading: const Icon(Icons.save_alt_outlined),
              title: const Text('バックアップを作成'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _exportBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('バックアップから復元'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _importBackup,
            ),
          ]),

          // 開発ビルドのみ。プロンプト調整の効果を測るための計測画面
          if (kDebugMode) ...[
            _sectionLabel('開発者'),
            _sectionCard([
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: const Text('解析ベンチ'),
                subtitle: const Text('修正済みの記録を正解としてAIの精度を測る'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const AnalysisBenchScreen()),
                ),
              ),
            ]),
          ],

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

          // ストア配布ではないので、更新は自分から知らせるしかない
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Center(
              child: Column(
                children: [
                  Text(
                    'ココメシ v$_appVersion',
                    style: TextStyle(fontSize: 12, color: tokens.textFaint),
                  ),
                  const SizedBox(height: 6),
                  if (_update != null)
                    FilledButton.tonalIcon(
                      onPressed: _openUpdatePage,
                      icon: const Icon(Icons.system_update_alt, size: 16),
                      label: Text('v${_update!.version} が出ています'),
                    )
                  else
                    TextButton(
                      onPressed:
                          _checkingUpdate ? null : () => _checkUpdate(force: true),
                      child: Text(
                        _checkingUpdate ? '確認中…' : '更新を確認',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
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
  /// 端末内AIが動かない端末では、トグルごと無効にして事情を書く。
  Widget _buildAiSection() {
    if (!DeviceCapability.onDeviceAi) return _buildAiUnsupportedSection();
    return _sectionCard([
      SwitchListTile(
        secondary: const Icon(Icons.auto_awesome_outlined),
        title: const Text('AIで自動解析する'),
        // 何ができるかは料理名が出れば分かる。ここで言う価値があるのは
        // 「通信しない・お金がかからない」の一点だけなので、それだけ残す
        subtitle: const Text('オフラインで動作・無料'),
        value: _aiEnabled,
        onChanged: _setAiEnabled,
      ),
      if (_aiEnabled) _buildModelStatusTile(),
    ]);
  }

  /// 端末内AI非対応(32bit端末)のときのAIセクション。
  ///
  /// ここでダウンロードを止めるのが一番大事。3GB落としてから使えないと
  /// 分かるのが最悪なので、ボタンそのものを出さない。
  Widget _buildAiUnsupportedSection() {
    final tokens = KokoTokens.of(context);
    return _sectionCard([
      ListTile(
        leading: Icon(Icons.phonelink_off, color: tokens.textFaint),
        title: const Text('AIで自動解析する'),
        subtitle: const Text('この端末では使えません'),
        enabled: false,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Text(
          '端末内AIは64bit(arm64)端末にのみ対応しています。'
          'この端末は32bitのため、AIモデルをダウンロードしても解析できません。\n'
          '撮影・記録・マップ・バックアップはすべてお使いいただけます。'
          '料理名や価格は手入力で記録できます。',
          style: TextStyle(fontSize: 12, color: tokens.textMuted),
        ),
      ),
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
