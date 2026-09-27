import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'models.dart';
import 'pages/folder_page.dart';
import 'pages/local_page.dart';
import 'pages/settings_page.dart';
import 'pages/webdav_page.dart';
import 'widgets/ui_kit.dart';

/// 主界面：四个入口（本地文件 / 文件夹 / WebDAV / 设置）+ 全局运行状态条。
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
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // 当前正在跑的那个来源（用于在对应标签上打点提示）
    final runningSource = controller.runningSource;

    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 全局状态条：切到别的标签也能看到"任务还在跑"
          if (runningSource != null)
            Material(
              color: scheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.page,
                  Insets.gap,
                  Insets.page,
                  Insets.gap,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: controller.batchTotal > 0
                            ? (controller.batchDone / controller.batchTotal)
                                .clamp(0.0, 1.0)
                            : null,
                      ),
                    ),
                    const SizedBox(width: Insets.gapLarge),
                    Expanded(
                      child: Text(
                        '正在处理${_sourceName(runningSource)}'
                        '${controller.batchTotal > 0 ? '（${controller.batchDone}/${controller.batchTotal}）' : '…'}',
                        style: text.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _index = _indexOf(runningSource)),
                      child: const Text('查看'),
                    ),
                    TextButton(
                      onPressed: controller.requestCancel,
                      child: const Text('停止'),
                    ),
                  ],
                ),
              ),
            ),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              _destination(Icons.video_file_rounded, '本地文件', 0, runningSource),
              _destination(Icons.folder_copy_rounded, '文件夹', 1, runningSource),
              _destination(Icons.cloud_rounded, 'WebDAV', 2, runningSource),
              const NavigationDestination(
                icon: Icon(Icons.settings_rounded),
                label: '设置',
              ),
            ],
          ),
        ],
      ),
    );
  }

  NavigationDestination _destination(
    IconData icon,
    String label,
    int index,
    JobSource? runningSource,
  ) {
    final busy = runningSource != null && _indexOf(runningSource) == index;
    return NavigationDestination(
      icon: Icon(icon),
      selectedIcon: busy
          ? Badge(
              label: const SizedBox(
                width: 8,
                height: 8,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              child: Icon(icon),
            )
          : Icon(icon),
      label: label,
    );
  }

  static int _indexOf(JobSource source) => switch (source) {
        JobSource.local => 0,
        JobSource.folder => 1,
        JobSource.webdav => 2,
      };

  static String _sourceName(JobSource source) => switch (source) {
        JobSource.local => '本地文件',
        JobSource.folder => '文件夹任务',
        JobSource.webdav => 'WebDAV 任务',
      };
}
