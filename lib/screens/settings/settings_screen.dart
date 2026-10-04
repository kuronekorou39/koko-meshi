import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geocoding/geocoding.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../services/app_settings_service.dart';
import '../../services/device_capability.dart';
import '../../services/ai_log.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import 'other_settings_screen.dart';
import 'settings_widgets.dart';

/// 設定の最初の画面。AIと保存した場所だけを置き、残りは「その他」へ送る。
/// スクロールせずに見渡せる量に収めるため。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];

  /// 新しいバージョンが出ているか。「その他」の行で知らせる
  bool _hasUpdate = false;

  /// AIで自動解析するか(= 端末内Gemmaを使うか)
  bool _aiEnabled = true;

  @override
  void initState() {
    super.initState();
    _aiEnabled = AppSettings.aiMode == AiAnalysisMode.onDevice;
    _loadSavedPlaces();
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

  Future<void> _checkUpdate() async {
    final update = await UpdateService.check();
    if (mounted) setState(() => _hasUpdate = update != null);
  }

  /// 「その他」から戻ったら場所を読み直す。バックアップの復元で増えうるため
  Future<void> _openOtherSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OtherSettingsScreen()),
    );
    _loadSavedPlaces();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + context.systemBottomInset),
        children: [
          const SettingsSectionLabel('AI自動解析'),
          _buildAiSection(),

          const SettingsSectionLabel('保存した場所'),
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

          const SizedBox(height: 20),
          _sectionCard([
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('その他'),
              subtitle: Text(
                _hasUpdate ? '新しいバージョンが出ています' : '表示・バックアップ・アプリの情報',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openOtherSettings,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _sectionCard(List<Widget> tiles) =>
      SettingsSectionCard(children: tiles);

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
                      const TextSpan(text: 'AIモデルをダウンロード中 '),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 16, color: tokens.success),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'AIモデルの準備ができています（${GemmaModelKind.e2b.label}）',
                            style: TextStyle(
                                fontSize: 12, color: tokens.textMuted),
                          ),
                        ),
                      ],
                    ),
                    _buildAiLogLink(),
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
                    'AIを使うには、最初に一度だけAIモデルのダウンロードが必要です。',
                    style: TextStyle(fontSize: 12, color: tokens.textMuted),
                  ),
                  const SizedBox(height: 12),
                  _buildModelFacts(),
                  const SizedBox(height: 12),
                  // 長い文言を詰め込むと折り返して、押せるものに見えなくなる。
                  // ボタンは一言にして、何を落とすのかは上の表に任せる
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _downloadModel,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('ダウンロードする'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'サイズが大きいので、Wi-Fi での利用をおすすめします',
                      style: TextStyle(fontSize: 12, color: tokens.textMuted),
                    ),
                  ),
                  // 失敗の詳細(HTTPコード等)を含むので、省略せず全文を出す。
                  // 実機で原因を読む唯一の手段になる(パッケージ側のログは
                  // リリースビルドでは消えている)
                  if (dl.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(
                        dl.error!,
                        style: TextStyle(
                            fontSize: 12, height: 1.5, color: scheme.error),
                      ),
                    ),
                  _buildAiLogLink(),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 何を、どこから、どれだけ落とすのか。数GBを落とさせる前に見せておく
  Widget _buildModelFacts() {
    final tokens = KokoTokens.of(context);
    const model = GemmaModelKind.e2b;
    final facts = [
      ('モデル', '${model.label}（Google のAI）'),
      ('サイズ', model.approxSize),
      ('入手先', '${Uri.parse(model.url).host}（Hugging Face）'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.hairline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final (label, value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12, color: tokens.textMuted),
                    ),
                  ),
                  Expanded(
                    child: Text(value, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// AIの経過ログへの入口。記録が無いうちは出さない
  Widget _buildAiLogLink() {
    return ValueListenableBuilder<int>(
      valueListenable: AiLog.instance.revision,
      builder: (context, _, child) {
        if (AiLog.instance.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _showAiLog,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: const Text('AIの記録を見る',
                style: TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }
}
