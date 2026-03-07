import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'timeline_tab.dart';
import 'map_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final _tabs = const [
    TimelineTab(),
    MapTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_currentIndex],
      floatingActionButton: FloatingActionButton.large(
        onPressed: () => context.push('/capture'),
        child: const Icon(Icons.camera_alt, size: 36),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.restaurant),
            label: '記録',
          ),
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'マップ',
          ),
        ],
      ),
    );
  }
}
