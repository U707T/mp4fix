import 'package:flutter/material.dart';

import '../app_scope.dart';

/// 设置：判定阈值 / 可优化 / 输出位置 / 外观 / 维护。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 与 pubspec.yaml 的 version 保持一致。
  static const String appVersion = '2.0.0';

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final settings = controller.settings;
    final scheme = Theme.of(context).colorScheme;
    final canEdit = !controller.running;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _SectionTitle('判定'),
          ListTile(
            title: const Text('判定阈值'),
            subtitle: const Text('最大交错距离超过该值即视为「需重排」'),
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1M')),
                ButtonSegment(value: 2, label: Text('2M')),
                ButtonSegment(value: 4, label: Text('4M')),
                ButtonSegment(value: 8, label: Text('8M')),
              ],
              selected: {settings.thresholdMb},
              onSelectionChanged: canEdit
                  ? (v) => controller.updateSettings((s) => s.thresholdMb = v.first)
                  : null,
            ),
          ),
          SwitchListTile(
            title: const Text('同时处理「可优化」'),
            subtitle: const Text('只缺 moov 前置的文件也一起修复'),
            value: settings.includeOptimizable,
            onChanged: canEdit
                ? (v) => controller
                    .updateSettings((s) => s.includeOptimizable = v)
                : null,
          ),
          const Divider(),
          _SectionTitle('输出'),
          ListTile(
            title: const Text('输出文件夹'),
            subtitle: Text(controller.outputDescription),
            trailing: TextButton(
              onPressed: canEdit ? () => controller.pickOutputFolder() : null,
              child: const Text('选择'),
            ),
          ),
          const Divider(),
          _SectionTitle('外观'),
          ListTile(
            title: const Text('主题'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) =>
                  controller.updateSettings((s) => s.themeMode = v.first),
            ),
          ),
          const Divider(),
          _SectionTitle('维护'),
          ListTile(
            title: const Text('清理临时文件'),
            subtitle: const Text('删除导入缓存与修复中间产物（不影响已保存的结果）'),
            trailing: const Icon(Icons.cleaning_services_rounded),
            onTap: () async {
              await controller.cleanCache();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已清理临时文件')),
              );
            },
          ),
          ListTile(
            title: const Text('关于'),
            subtitle: const Text('MP4 修复器 · Flutter 版 v$appVersion'),
            trailing: const Icon(Icons.info_outline_rounded),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('MP4 修复器'),
                content: const Text(
                  '针对「部分播放器播放卡顿 / 忽快忽慢」的 MP4 的无损修复工具。\n\n'
                  '音视频交错被打乱时，同一播放时刻的音频与视频数据在文件里相距几十'
                  '甚至几百 MB（正常应 < 1MB），弱读取设备 / 流式播放就会卡顿。\n\n'
                  '修复方式：解析采样表 → 按时间重新切块并全局合并 → moov 前置 → '
                  '流式改写 mdat（样本字节原样拷贝，画质无损、不重新编码）。\n\n'
                  '引擎为纯 Dart 实现，与 Kotlin 旧版逐字节一致。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('好'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '提示：修复不会改变原文件；「上传副本」模式会在服务器生成 '
              '原名_fixed.mp4，「保存到本地」模式服务器全程只读。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}
