import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
      ),
      body: ListView(
        children: [
          // アカウント連携
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('アカウント連携'),
            subtitle: const Text('ログインしてクラウドにバックアップ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: ログイン画面
            },
          ),
          const Divider(),

          // 同期状況
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('同期状況'),
            subtitle: const Text('未ログイン'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: 同期状況の詳細
            },
          ),
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
}
