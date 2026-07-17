import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../providers/auth_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/auth_service.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../poc/gemma_poc_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];
  bool _syncing = false;
  String _appVersion = '';

  // AI解析モード
  AiAnalysisMode _aiMode = AiAnalysisMode.onDevice;

  @override
  void initState() {
    super.initState();
    _aiMode = AppSettings.aiMode;
    _loadSavedPlaces();
    _loadVersion();
    // DL状態・インストール済みフラグはGemmaDownloadManagerが画面をまたいで
    // 保持しているので、ここでは最新化だけ依頼する
    GemmaDownloadManager.instance.refreshInstalled(GemmaModelKind.e2b);
  }

  Future<void> _setAiMode(AiAnalysisMode mode) async {
    await AppSettings.setAiMode(mode);
    if (mounted) setState(() => _aiMode = mode);
  }

  Future<void> _downloadModel() async {
    try {
      await GemmaDownloadManager.instance.download(GemmaModelKind.e2b);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('モデルのDLに失敗: $e')),
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

  Future<void> _handleSync() async {
    setState(() => _syncing = true);
    try {
      final result = await SyncService.syncAll();
      await SyncService.syncSavedPlaces();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.hasErrors
                  ? '${result.synced}件同期、${result.failed}件失敗'
                  : '${result.synced}件を同期しました',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同期エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('ログアウト'),
          content: const Text('ログアウトしますか？\nローカルのデータはそのまま残ります。'),
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
              child: const Text('ログアウト'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await AuthService.signOut();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ログアウトしました')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = ref.watch(isLoggedInProvider);
    final profileAsync = ref.watch(userProfileProvider);
    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _sectionLabel('アカウント'),
          if (isLoggedIn)
            _buildLoggedInSection(profileAsync)
          else
            _buildLoggedOutSection(),

          _sectionLabel('AI解析'),
          ..._buildAiSection(),

          _sectionLabel('写真・ストレージ'),
          _sectionCard([
            SwitchListTile(
              secondary: const Icon(Icons.photo_library_outlined),
              title: const Text('カメラロールにも保存'),
              subtitle: const Text('撮影した写真を端末のギャラリーにも保存'),
              value: AppSettings.saveToCameraRoll,
              onChanged: (value) async {
                await AppSettings.setSaveToCameraRoll(value);
                setState(() {});
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.cloud_done_outlined),
              title: const Text('クラウド保存後にオリジナルを削除'),
              subtitle: const Text('アップロード後にローカルの原寸写真を削除（サムネは残す）'),
              value: AppSettings.deleteAfterUpload,
              onChanged: isLoggedIn
                  ? (value) async {
                      await AppSettings.setDeleteAfterUpload(value);
                      setState(() {});
                    }
                  : null,
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
                            future: _reverseGeocode(place.latitude, place.longitude),
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

          _sectionLabel('開発者'),
          _sectionCard([
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('オンデバイスAI PoC (Gemma)'),
              subtitle: const Text('端末内Gemmaで写真解析・推論速度を実測'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const GemmaPocScreen()),
              ),
            ),
          ]),

          // バージョン表示
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

  /// セクションの小見出し
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(text, style: KokoTokens.of(context).sectionLabel),
    );
  }

  /// ListTile群をヘアラインで区切ってカードにまとめる
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

  List<Widget> _buildAiSection() {
    final tokens = KokoTokens.of(context);
    return [
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<AiAnalysisMode>(
          segments: const [
            ButtonSegment(value: AiAnalysisMode.onDevice, label: Text('端末内')),
            ButtonSegment(value: AiAnalysisMode.off, label: Text('オフ')),
          ],
          selected: {_aiMode},
          onSelectionChanged: (s) => _setAiMode(s.first),
        ),
      ),
      ValueListenableBuilder<bool?>(
        valueListenable:
            GemmaDownloadManager.instance.installedOf(GemmaModelKind.e2b),
        builder: (context, installed, _) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            _aiModeDescription(installed ?? false),
            style:
                TextStyle(fontSize: 12, height: 1.4, color: tokens.textMuted),
          ),
        ),
      ),
      if (_aiMode == AiAnalysisMode.onDevice) ...[
        const SizedBox(height: 12),
        _buildOnDeviceModelTile(),
      ],
    ];
  }

  String _aiModeDescription(bool e2bInstalled) {
    switch (_aiMode) {
      case AiAnalysisMode.onDevice:
        return e2bInstalled
            ? '端末内のGemma 4 E2Bで解析（オフライン・無料・写真は外部送信なし）。'
            : 'オフラインで解析します。まずモデル（約2.4GB）のダウンロードが必要です。';
      case AiAnalysisMode.off:
        return 'AI解析を使わず、料理名・価格・カロリーは手動入力します。';
    }
  }

  /// E2BモデルのDL状態タイル。進捗はGemmaDownloadManagerが保持しているので、
  /// DL中に画面を離れて戻っても進捗バーが復元される。
  Widget _buildOnDeviceModelTile() {
    final mgr = GemmaDownloadManager.instance;
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<GemmaDownloadState>(
      valueListenable: mgr.stateOf(GemmaModelKind.e2b),
      builder: (context, dl, _) {
        if (dl.downloading) {
          return Column(
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
                    const TextSpan(text: 'モデルをダウンロード中 '),
                    TextSpan(
                      text: '${dl.progress}%',
                      style: tokens.numeral.copyWith(fontSize: 12),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: 12, color: tokens.textMuted),
              ),
            ],
          );
        }
        return ValueListenableBuilder<bool?>(
          valueListenable: mgr.installedOf(GemmaModelKind.e2b),
          builder: (context, installed, _) {
            if (installed != true) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _downloadModel,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(
                        'モデルをダウンロード（${GemmaModelKind.e2b.approxSize}・Wi-Fi推奨）',
                      ),
                    ),
                  ),
                  // 別画面でDLが失敗していた場合もここに理由を表示する
                  if (dl.error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(
                        dl.error!,
                        style: TextStyle(fontSize: 12, color: scheme.error),
                      ),
                    ),
                ],
              );
            }
            return _sectionCard([
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: const Text('この端末で動作テスト'),
                subtitle: const Text('E2Bがこの端末で快適に動くか確認'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const GemmaPocScreen()),
                ),
              ),
            ]);
          },
        );
      },
    );
  }

  Widget _buildLoggedOutSection() {
    return _sectionCard([
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: const Text('ログイン / アカウント作成'),
        subtitle: const Text('クラウドにバックアップ・デバイス間同期'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/login'),
      ),
    ]);
  }

  Widget _buildLoggedInSection(AsyncValue<Map<String, dynamic>?> profileAsync) {
    final scheme = Theme.of(context).colorScheme;
    final user = AuthService.currentUser;
    final email = user?.email ?? '';

    return _sectionCard([
      ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.person_outline, color: scheme.onPrimaryContainer),
        ),
        title: profileAsync.when(
          data: (profile) => Text(
            profile?['display_name'] ?? email.split('@').first,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          loading: () => const Text('...'),
          error: (_, _) => Text(email.split('@').first),
        ),
        subtitle: Text(email),
      ),
      ListTile(
        leading: Icon(_syncing ? Icons.cloud_sync_outlined : Icons.cloud_done_outlined),
        title: Text(_syncing ? '同期中...' : 'クラウド同期'),
        subtitle: const Text('タップして今すぐ同期'),
        trailing: _syncing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync),
        onTap: _syncing ? null : _handleSync,
      ),
      ListTile(
        leading: Icon(Icons.logout, color: scheme.error),
        title: Text('ログアウト', style: TextStyle(color: scheme.error)),
        onTap: _handleLogout,
      ),
    ]);
  }
}
