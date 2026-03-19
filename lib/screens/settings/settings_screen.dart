import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:go_router/go_router.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../providers/auth_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPlaces();
  }

  Future<void> _loadSavedPlaces() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (mounted) setState(() => _savedPlaces = places);
  }

  Future<void> _deleteSavedPlace(SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('場所を削除'),
        content: Text('「${place.name}」を削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除')),
        ],
      ),
    );

    if (confirmed == true) {
      await LocalDatabase.deleteSavedPlace(place.id);
      _loadSavedPlaces();
    }
  }

  IconData _iconForType(String iconType) {
    return switch (iconType) {
      'home' => Icons.home,
      'favorite' => Icons.star,
      _ => Icons.place,
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
      builder: (context) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('ログアウトしますか？\nローカルのデータはそのまま残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
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

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          // アカウント
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'アカウント',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
            ),
          ),
          if (isLoggedIn)
            _buildLoggedInSection(profileAsync)
          else
            _buildLoggedOutSection(),
          const Divider(),

          // 写真・ストレージ
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '写真・ストレージ',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.photo_library),
            title: const Text('カメラロールにも保存'),
            subtitle: const Text('撮影した写真を端末のギャラリーにも保存'),
            value: AppSettings.saveToCameraRoll,
            onChanged: (value) async {
              await AppSettings.setSaveToCameraRoll(value);
              setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_done),
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
          const Divider(),

          // 保存した場所
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '保存した場所',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
            ),
          ),
          if (_savedPlaces.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('保存した場所はありません'),
              subtitle: Text('マップ画面から登録できます'),
            )
          else
            ..._savedPlaces.map((place) => ListTile(
              leading: Icon(_iconForType(place.iconType)),
              title: Text(place.name),
              subtitle: FutureBuilder<String?>(
                future: _reverseGeocode(place.latitude, place.longitude),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Text(snapshot.data!, maxLines: 1, overflow: TextOverflow.ellipsis);
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
            )),
          const Divider(),

          // アプリ情報
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('アプリ情報'),
            subtitle: Text('ココメシ v0.1.0'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoggedOutSection() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('ログイン / アカウント作成'),
          subtitle: const Text('クラウドにバックアップ・デバイス間同期'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/login'),
        ),
      ],
    );
  }

  Widget _buildLoggedInSection(AsyncValue<Map<String, dynamic>?> profileAsync) {
    final user = AuthService.currentUser;
    final email = user?.email ?? '';

    return Column(
      children: [
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Icon(
              Icons.person,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          title: profileAsync.when(
            data: (profile) => Text(
              profile?['display_name'] ?? email.split('@').first,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            loading: () => const Text('...'),
            error: (_, _) => Text(email.split('@').first),
          ),
          subtitle: Text(email, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ),
        ListTile(
          leading: Icon(_syncing ? Icons.cloud_sync : Icons.cloud_done),
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
          leading: Icon(Icons.logout, color: Colors.red[400]),
          title: Text('ログアウト', style: TextStyle(color: Colors.red[400])),
          onTap: _handleLogout,
        ),
      ],
    );
  }
}
