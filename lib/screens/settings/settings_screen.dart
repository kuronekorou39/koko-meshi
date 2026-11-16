import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/features.dart';
import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../providers/app_settings_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_log.dart';
import '../../services/app_settings_service.dart';
import '../../services/backup_service.dart';
import '../../services/device_capability.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../services/storage_stats.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import 'analysis_bench_screen.dart';
import 'font_settings_screen.dart';
import 'settings_widgets.dart';

/// 設定。弁当箱のように升を詰めた1画面で、縦でも横でも送らずに全部が見える。
///
/// 升の大きさが大事さを表す(いちばん大きい升がAI)。見出しや説明は置かず、
/// 項目の名前で分かることは書かない。説明が要るのは実行する直前
/// (バックアップの中身、ダウンロードの大きさ)なので、そこで伝える。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// 広い画面でも升が間延びしない幅(縦向き / 横向き)
  static const double _maxPortraitWidth = 560;
  static const double _maxLandscapeWidth = 960;

  /// 升の中身を崩さずに組める最小の大きさ。これより小さい升は中身を縮める
  static const _aiTileMinSize = Size(210, 320);
  static const _statsTileMinSize = Size(132, 112);
  static const _smallTileMinSize = Size(108, 112);
  static const _backupTileMinSize = Size(220, 116);

  List<SavedPlace> _savedPlaces = [];
  StorageStats? _stats;

  String _appVersion = '';

  /// 出ている新しいバージョン(無ければ null)
  AppUpdate? _update;
  bool _checkingUpdate = false;

  /// AIで自動解析するか(= 端末内Gemmaを使うか)
  bool _aiEnabled = true;

  /// カメラロールに保存する写真へ位置情報を埋め込むか
  bool _exportExifGps = true;

  @override
  void initState() {
    super.initState();
    _aiEnabled = AppSettings.aiMode == AiAnalysisMode.onDevice;
    _exportExifGps = AppSettings.exportExifGps;
    _loadSavedPlaces();
    _loadStats();
    _loadVersion();
    _checkUpdate();
    GemmaDownloadManager.instance.refreshInstalled(GemmaModelKind.e2b);
  }

  Future<void> _loadStats() async {
    try {
      final stats = await StorageStats.load();
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      // 数えられなくても設定は使える。欄を「—」のままにしておく
      debugPrint('[Settings] storage stats failed: $e');
    }
  }

  Future<void> _setAiEnabled(bool enabled) async {
    await AppSettings.setAiMode(
        enabled ? AiAnalysisMode.onDevice : AiAnalysisMode.off);
    if (mounted) setState(() => _aiEnabled = enabled);
  }

  Future<void> _setExportExifGps(bool enabled) async {
    await AppSettings.setExportExifGps(enabled);
    if (mounted) setState(() => _exportExifGps = enabled);
  }

  Future<void> _setFunFeature(FunFeature feature, bool enabled) async {
    await AppSettings.setFunFeature(feature, enabled);
    if (mounted) {
      ref.read(funFeaturesProvider.notifier).state = AppSettings.funFeatures;
    }
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

  /// AIの経過ログ(DL・ロード・解析)を見せる。
  /// iOS実機ではPCからログを読めないので、ここからコピーして貼れることが
  /// 唯一の切り分け手段になる
  void _showAiLog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AIの記録'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              AiLog.instance.text,
              style: const TextStyle(fontSize: 11, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              AiLog.instance.clear();
              Navigator.pop(context);
            },
            child: const Text('消す'),
          ),
          TextButton(
            onPressed: () async {
              // ダイアログを閉じるとこの context は無効になるので、
              // スナックバー用の messenger は await の前に掴んでおく
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);
              await Clipboard.setData(
                ClipboardData(text: AiLog.instance.text),
              );
              navigator.pop();
              messenger.showSnackBar(
                const SnackBar(content: Text('記録をコピーしました')),
              );
            },
            child: const Text('コピー'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
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

  /// テスト版(全員に配る前の版)も更新として受け取るかを切り替える。
  ///
  /// 配る側が自分の端末で確かめるための設定で、ふつうの利用には要らない。
  /// 升を1つ使うほどのものではないので、バージョンの長押しに置く。
  /// テスト版の経路があるのは自前配布の Android だけ
  Future<void> _toggleBetaUpdates() async {
    if (!Platform.isAndroid) return;
    final enabled = !AppSettings.includeBetaUpdates;
    await AppSettings.setIncludeBetaUpdates(enabled);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? 'テスト版も受け取ります' : 'テスト版の受け取りをやめました'),
      ),
    );
    // 切り替えた結果をすぐ反映する(オフにしたらテスト版の知らせを消す)
    await _checkUpdate(force: true);
  }

  Future<void> _openUpdatePage() async {
    final update = _update;
    if (update == null) return;
    await launchUrl(Uri.parse(update.url), mode: LaunchMode.externalApplication);
  }

  Future<void> _loadSavedPlaces() async {
    try {
      final places = await LocalDatabase.getSavedPlaces();
      if (mounted) setState(() => _savedPlaces = places);
    } catch (e) {
      // 読めなくても設定は使える。場所の升を0件のままにしておく
      debugPrint('[Settings] saved places failed: $e');
    }
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
      await _loadSavedPlaces();
    }
  }

  /// 保存した場所の一覧。登録はマップでするので、ここでは見ることと消すことだけ
  Future<void> _showSavedPlaces() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final tokens = KokoTokens.of(context);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_savedPlaces.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'マップから登録できます',
                      style: TextStyle(color: tokens.textMuted),
                    ),
                  ),
                for (final place in _savedPlaces)
                  ListTile(
                    leading: Icon(_iconForType(place.iconType)),
                    title: Text(place.name),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () async {
                        await _deleteSavedPlace(place);
                        if (context.mounted) setSheetState(() {});
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── バックアップと移行 ───

  Future<void> _exportBackup() async {
    // 何が書き出されるのか(写真も含む=ファイルが大きい)は、一覧に常時
    // 書いておくより、実行する直前に伝えたほうが読まれる
    final stats = _stats;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックアップを作成'),
        content: Text(
          'すべての記録・写真・設定を1つのzipファイルに書き出します。\n\n'
          '${stats == null ? '写真を含むので、記録が多いとファイルは大きくなります。' : '写真を含むので、ファイルはおよそ ${formatBytes(stats.photoBytes)} になります。'}'
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
      // 復元で場所や写真が増えうる
      _loadSavedPlaces();
      _loadStats();
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

  IconData _iconForType(String iconType) {
    return switch (iconType) {
      'home' => Icons.home_outlined,
      'favorite' => Icons.star_outline,
      _ => Icons.place_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 画面の高さにぴったり詰める。送らせない(升が小さくなったら
            // 升の側で中身を縮める)
            final landscape = constraints.maxWidth > constraints.maxHeight;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: landscape ? _maxLandscapeWidth : _maxPortraitWidth,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    children: [
                      Expanded(child: _buildBento(landscape: landscape)),
                      _buildFooter(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 弁当箱。縦向きは上にAIと記録・場所、下に小さい升とバックアップ。
  /// 横向きは同じ升を左から右へ並べ直す。
  Widget _buildBento({required bool landscape}) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);
    const gapW = SizedBox(width: BentoTile.gap);
    const gapH = SizedBox(height: BentoTile.gap);

    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildStatsTile()),
        gapH,
        Expanded(child: _buildPlacesTile()),
      ],
    );

    final smallTiles = _buildSmallTiles();
    final small = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < smallTiles.length; i++) ...[
          if (i > 0) gapW,
          Expanded(child: smallTiles[i]),
        ],
      ],
    );

    final Widget box;
    if (landscape) {
      box = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: _buildAiTile()),
          gapW,
          Expanded(flex: 2, child: side),
          gapW,
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: small),
                gapH,
                Expanded(child: _buildBackupTile()),
              ],
            ),
          ),
        ],
      );
    } else {
      box = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildAiTile()),
                gapW,
                Expanded(flex: 2, child: side),
              ],
            ),
          ),
          gapH,
          Expanded(flex: 2, child: small),
          gapH,
          Expanded(flex: 2, child: _buildBackupTile()),
        ],
      );
    }

    // 箱の縁
    return Container(
      padding: const EdgeInsets.all(BentoTile.gap),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: tokens.hairline, width: 1.2),
      ),
      child: box,
    );
  }

  /// 升の左上に置くアイコン
  Widget _tileIcon(IconData icon, {Color? color}) =>
      Icon(icon, size: 22, color: color);

  /// 升の名前
  Widget _tileLabel(String text, {Color? color}) => Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          height: 1.25,
          color: color,
        ),
      );

  // ─── AI(いちばん大きい升) ───

  Widget _buildAiTile() {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);
    final supported = DeviceCapability.onDeviceAi;
    final on = supported && _aiEnabled;
    final fg = on ? scheme.onPrimaryContainer : null;

    return BentoTile(
      minContentSize: _aiTileMinSize,
      color: on ? scheme.primaryContainer : null,
      onTap: supported ? () => _setAiEnabled(!_aiEnabled) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                supported ? Icons.auto_awesome : Icons.phonelink_off,
                size: 28,
                color: supported ? fg : tokens.textFaint,
              ),
              const Spacer(),
              if (supported)
                Switch(value: _aiEnabled, onChanged: _setAiEnabled),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'AIで自動解析',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: supported ? fg : tokens.textFaint,
            ),
          ),
          const SizedBox(height: 4),
          // 何ができるかは料理名が出れば分かる。ここで言う価値があるのは
          // 「スマホの外に出ない・お金がかからない」の一点だけなので、それだけ残す。
          // 動かない端末では、3GB落としてから気づかせないよう理由だけ書く
          Text(
            supported ? 'このスマホの中だけで動作・無料' : 'この端末では使えません（64bit端末のみ対応）',
            style: TextStyle(
              fontSize: 12,
              color: on ? fg : tokens.textMuted,
            ),
          ),
          // 状態は升の底に寄せる
          const Spacer(),
          if (on) _buildModelStatus(fg),
        ],
      ),
    );
  }

  /// モデルのDL状態に応じた案内。進捗はGemmaDownloadManagerが保持する
  /// ので、DL中に画面を離れて戻っても復元される。
  Widget _buildModelStatus(Color? fg) {
    final mgr = GemmaDownloadManager.instance;
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: fg);

    return ValueListenableBuilder<GemmaDownloadState>(
      valueListenable: mgr.stateOf(GemmaModelKind.e2b),
      builder: (context, dl, _) {
        if (dl.downloading) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
                    const TextSpan(text: 'ダウンロード中 '),
                    TextSpan(
                      text: '${dl.progress}%',
                      style: tokens.numeral.copyWith(fontSize: 12, color: fg),
                    ),
                  ],
                ),
                style: small,
              ),
            ],
          );
        }
        return ValueListenableBuilder<bool?>(
          valueListenable: mgr.installedOf(GemmaModelKind.e2b),
          builder: (context, installed, _) {
            const model = GemmaModelKind.e2b;
            if (installed == true) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildAiLogLink(fg),
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 15, color: fg),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          model.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 何を、どこから、どれだけ落とすのか。数GBを落とさせる
                // 前に、これだけは見せておく
                Text(
                  '${model.label}・${model.approxSize}\n'
                  '${Uri.parse(model.url).host} から取得',
                  style: small,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _downloadModel,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('ダウンロード'),
                  ),
                ),
                const SizedBox(height: 4),
                Text('Wi-Fi 推奨', style: small),
                // 失敗したことだけを升に出し、詳細(HTTPコード等)は押して
                // 全文を読めるようにする。升は送れないので長文を置けないが、
                // 実機で原因を読む手段は残す(パッケージ側のログは
                // リリースビルドでは消えている)
                if (dl.error != null)
                  TextButton.icon(
                    onPressed: () => _showDownloadError(dl.error!),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.error,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.error_outline, size: 16),
                    label: const Text('失敗しました（詳細）',
                        style: TextStyle(fontSize: 12)),
                  ),
                _buildAiLogLink(fg),
              ],
            );
          },
        );
      },
    );
  }

  /// ダウンロードの失敗の全文。コピーして貼れるようにしておく
  void _showDownloadError(String error) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ダウンロードに失敗しました'),
        content: SingleChildScrollView(
          child: SelectableText(
            error,
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  /// AIの経過ログへの入口。記録が無いうちは出さない
  Widget _buildAiLogLink(Color? fg) {
    return ValueListenableBuilder<int>(
      valueListenable: AiLog.instance.revision,
      builder: (context, _, child) {
        if (AiLog.instance.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextButton.icon(
            onPressed: _showAiLog,
            style: TextButton.styleFrom(
              foregroundColor: fg,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: const Text('AIの記録', style: TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }

  // ─── 記録の量 ───

  /// 溜まっている記録の量(件数・枚数・写真の容量)
  Widget _buildStatsTile() {
    final tokens = KokoTokens.of(context);
    final stats = _stats;
    final fmt = NumberFormat('#,###');
    const noValue = '—';

    Widget row(String label, String value) => Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: tokens.textMuted),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.numeral.copyWith(fontSize: 17),
              ),
            ),
          ],
        );

    return BentoTile(
      minContentSize: _statsTileMinSize,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          row('記録', stats == null ? noValue : fmt.format(stats.mealCount)),
          row('写真', stats == null ? noValue : fmt.format(stats.photoCount)),
          row('容量', stats == null ? noValue : formatBytes(stats.photoBytes)),
        ],
      ),
    );
  }

  // ─── 保存した場所 ───

  Widget _buildPlacesTile() {
    final tokens = KokoTokens.of(context);
    return BentoTile(
      minContentSize: _smallTileMinSize,
      onTap: _showSavedPlaces,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _tileIcon(Icons.bookmark_outline),
              const Spacer(),
              Text(
                '${_savedPlaces.length}',
                style: tokens.numeral.copyWith(fontSize: 20),
              ),
            ],
          ),
          const Spacer(),
          _tileLabel('保存した場所'),
        ],
      ),
    );
  }

  // ─── 小さい升(フォント・遊び要素・位置情報) ───

  List<Widget> _buildSmallTiles() {
    final tokens = KokoTokens.of(context);
    final funEnabled = ref.watch(funFeaturesProvider);

    return [
      BentoTile(
        minContentSize: _smallTileMinSize,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FontSettingsScreen()),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tileIcon(Icons.text_fields_outlined),
            const Spacer(),
            _tileLabel('フォント'),
            Text(
              ref.watch(appFontProvider).label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: tokens.textMuted),
            ),
          ],
        ),
      ),
      // 記録には要らないが、あると楽しい機能。[FunFeature] に足せばここに並ぶ
      for (final feature in FunFeature.values)
        _toggleTile(
          icon: Icons.auto_awesome_motion_outlined,
          label: feature.label,
          value: funEnabled.contains(feature),
          onChanged: (on) => _setFunFeature(feature, on),
        ),
      // 付けるかどうかは保存のたびに尋ねるので、ここでは説明しない
      _toggleTile(
        icon: Icons.add_location_alt_outlined,
        label: '写真に位置情報',
        value: _exportExifGps,
        onChanged: _setExportExifGps,
      ),
    ];
  }

  /// 押すたびに入り切りする升。入っているときは地の色を変えて見せる
  Widget _toggleTile({
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);
    final fg = value ? scheme.onSecondaryContainer : null;

    return Semantics(
      toggled: value,
      child: BentoTile(
        minContentSize: _smallTileMinSize,
        color: value ? scheme.secondaryContainer : null,
        onTap: () => onChanged(!value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _tileIcon(icon, color: fg),
                const Spacer(),
                Text(
                  value ? 'ON' : 'OFF',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: value ? fg : tokens.textFaint,
                  ),
                ),
              ],
            ),
            const Spacer(),
            _tileLabel(label, color: fg),
          ],
        ),
      ),
    );
  }

  // ─── バックアップ ───

  Widget _buildBackupTile() {
    return BentoTile(
      minContentSize: _backupTileMinSize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _tileIcon(Icons.inventory_2_outlined),
              const SizedBox(width: 8),
              Expanded(child: _tileLabel('バックアップ')),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _exportBackup,
                    icon: const Icon(Icons.save_alt_outlined, size: 18),
                    label: const Text('作成'),
                  ),
                ),
                const SizedBox(width: BentoTile.gap),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importBackup,
                    icon: const Icon(Icons.restore_outlined, size: 18),
                    label: const Text('復元'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── 箱の外(バージョンと更新) ───

  Widget _buildFooter() {
    final tokens = KokoTokens.of(context);
    final linkStyle = TextButton.styleFrom(
      textStyle: const TextStyle(fontSize: 12),
      visualDensity: VisualDensity.compact,
    );

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: _toggleBetaUpdates,
          child: Text(
            AppSettings.includeBetaUpdates
                ? 'ココメシ v$_appVersion（テスト版も受け取る）'
                : 'ココメシ v$_appVersion',
            style: TextStyle(fontSize: 12, color: tokens.textFaint),
          ),
        ),
        const SizedBox(width: 4),
        // ストア配布ではないので、更新は自分から知らせるしかない
        if (_update != null)
          TextButton.icon(
            style: linkStyle,
            onPressed: _openUpdatePage,
            icon: const Icon(Icons.system_update_alt, size: 16),
            label: Text('v${_update!.version} が出ています'),
          )
        else
          TextButton(
            style: linkStyle,
            onPressed:
                _checkingUpdate ? null : () => _checkUpdate(force: true),
            child: Text(_checkingUpdate ? '確認中…' : '更新を確認'),
          ),
        // プロンプト調整の効果を測るための計測画面。開発ビルド、または
        // 旗を立てたリリースビルド(実データで測るため)でだけ出す
        if (kDebugMode || AppFeatures.analysisBench)
          TextButton(
            style: linkStyle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AnalysisBenchScreen()),
            ),
            child: const Text('解析ベンチ'),
          ),
      ],
      ),
    );
  }
}
