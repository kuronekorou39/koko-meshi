import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/features.dart';
import '../../providers/app_settings_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/backup_service.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import 'analysis_bench_screen.dart';
import 'font_settings_screen.dart';
import 'settings_widgets.dart';

/// 設定の「その他」。毎日は触らない項目をここに集めて、設定の最初の画面を
/// AIと保存した場所だけにする。
class OtherSettingsScreen extends ConsumerStatefulWidget {
  const OtherSettingsScreen({super.key});

  @override
  ConsumerState<OtherSettingsScreen> createState() =>
      _OtherSettingsScreenState();
}

class _OtherSettingsScreenState extends ConsumerState<OtherSettingsScreen> {
  String _appVersion = '';

  /// 出ている新しいバージョン(無ければ null)
  AppUpdate? _update;
  bool _checkingUpdate = false;

  /// カメラロールに保存する写真へ位置情報を埋め込むか
  bool _exportExifGps = false;

  @override
  void initState() {
    super.initState();
    _exportExifGps = AppSettings.exportExifGps;
    _loadVersion();
    _checkUpdate();
  }

  Future<void> _setExportExifGps(bool enabled) async {
    await AppSettings.setExportExifGps(enabled);
    if (mounted) setState(() => _exportExifGps = enabled);
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

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックアップから復元'),
        content: Text(
          'バックアップにしか無い記録と写真を追加します。'
          'いまこの端末にある記録は消えません。\n\n'
          'この端末で削除した記録がバックアップに残っている場合は、'
          'もう一度出てきます。\n\n'
          'バックアップ日時: ${manifest.exportedAt.replaceFirst('T', ' ').split('.').first}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('追加する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    _showBlockingProgress('復元しています…');
    try {
      final result = await BackupService.restore(path);
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      ref.invalidate(mealLogsProvider);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('復元が完了しました'),
          content: Text(
            result.isEmpty
                ? 'このバックアップの記録は、すべてこの端末にありました。'
                    '追加したものはありません。'
                : '${result.addedRecords}件の記録を追加しました。\n'
                    '表示を確実に反映するため、アプリを一度再起動することを'
                    'おすすめします。',
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
      appBar: AppBar(title: const Text('その他')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + context.systemBottomInset),
        children: [
          const SettingsSectionLabel('表示'),
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

          const SettingsSectionLabel('遊び要素'),
          _buildFunSection(tokens),

          const SettingsSectionLabel('写真の書き出し'),
          _sectionCard([
            SwitchListTile(
              secondary: const Icon(Icons.add_location_alt_outlined),
              title: const Text('位置情報を付けて保存する'),
              subtitle: const Text('カメラロールに保存する写真に、記録した場所を埋め込みます'),
              value: _exportExifGps,
              onChanged: _setExportExifGps,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                'オフのときは、撮影日時だけを埋め込みます。'
                '保存した写真を誰かに渡すと、食べた場所も一緒に渡ることに'
                'なるため、既定ではオフにしています。',
                style: TextStyle(fontSize: 12, color: tokens.textMuted),
              ),
            ),
          ]),

          // 何をする項目かは名前で分かる。詳しい説明は実行するかを尋ねる
          // ダイアログ側に置いて、一覧は読まずに見渡せるようにする
          const SettingsSectionLabel('バックアップ'),
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

          // プロンプト調整の効果を測るための計測画面。開発ビルド、または
          // 旗を立てたリリースビルド(実データで測るため)でだけ出す
          if (kDebugMode || AppFeatures.analysisBench) ...[
            const SettingsSectionLabel('開発者'),
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

  Widget _sectionCard(List<Widget> tiles) =>
      SettingsSectionCard(children: tiles);

  /// 記録には要らないが、あると楽しい機能。既定はどれもオフ。
  ///
  /// [FunFeature] に足せばここに並ぶので、増えても手を入れなくてよい。
  Widget _buildFunSection(KokoTokens tokens) {
    final enabled = ref.watch(funFeaturesProvider);
    return _sectionCard([
      for (final feature in FunFeature.values) ...[
        SwitchListTile(
          secondary: const Icon(Icons.auto_awesome_motion_outlined),
          title: Text(feature.label),
          subtitle: Text(feature.description),
          value: enabled.contains(feature),
          onChanged: (on) => _setFunFeature(feature, on),
        ),
        if (enabled.contains(feature))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              feature.hint,
              style: TextStyle(fontSize: 12, color: tokens.textMuted),
            ),
          ),
      ],
    ]);
  }

  Future<void> _setFunFeature(FunFeature feature, bool enabled) async {
    await AppSettings.setFunFeature(feature, enabled);
    if (mounted) {
      ref.read(funFeaturesProvider.notifier).state = AppSettings.funFeatures;
    }
  }
}
