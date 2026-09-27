import 'package:flutter/material.dart';

import 'pages/folder_page.dart';
import 'pages/local_page.dart';
import 'pages/settings_page.dart';
import 'pages/webdav_page.dart';

/// 主界面：四个入口（本地文件 / 文件夹 / WebDAV / 设置）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<Widget> _pages = [
    LocalPage(),
    FolderPage(),
    WebDavPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_file_rounded),
            label: '本地文件',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_copy_rounded),
            label: '文件夹',
          ),
          NavigationDestination(icon: Icon(Icons.cloud_rounded), label: 'WebDAV'),
          NavigationDestination(
            icon: Icon(Icons.settings_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
