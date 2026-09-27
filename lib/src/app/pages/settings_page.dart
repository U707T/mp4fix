import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../ui.dart';

/// 设置：判定阈值 / 可优化 / 输出位置 / 外观 / 维护。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 与 pubspec.yaml 的 version 保持一致。
  static const String appVersion = '2.1.1';

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
          const _SectionTitle('判定'),
          _SettingBlock(
            icon: Icons.tune_rounded,
            title: '判定阈值',
            subtitle: '最大交错距离超过该值即视为「需重排」',
            child: SegmentedButton<int>(
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
                ? (v) => controller.updateSettings((s) => s.includeOptimizable = v)
                : null,
          ),
          const Divider(),
          const _SectionTitle('输出'),
          ListTile(
            title: const Text('输出文件夹'),
            subtitle: Text(controller.outputDescription),
            trailing: TextButton(
              onPressed:
                  canEdit ? () => guardUi(context, controller.pickOutputFolder) : null,
              child: const Text('选择'),
            ),
          ),
          const Divider(),
          const _SectionTitle('外观'),
          _SettingBlock(
            icon: Icons.palette_rounded,
            title: '主题',
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) =>
                  controller.updateSettings((s) => s.themeMode = v.first),
            ),
          ),
          const Divider(),
          const _SectionTitle('维护'),
          ListTile(
            title: const Text('清理临时文件'),
            subtitle: const Text('删除导入缓存与修复中间产物（不影响已保存的结果）'),
            trailing: const Icon(Icons.cleaning_services_rounded),
            onTap: () => guardUi(context, () async {
              await controller.cleanCache();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已清理临时文件')),
              );
            }),
          ),
          ListTile(
            title: const Text('复制诊断信息'),
            subtitle: const Text('平台 / 路径 / 是否存在等，反馈问题时附上它'),
            trailing: const Icon(Icons.bug_report_rounded),
            onTap: () => guardUi(context, () async {
              final text = await controller.collectDiagnostics();
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('诊断信息已复制到剪贴板')),
              );
            }),
          ),
          ListTile(
            title: const Text('关于'),
            subtitle: const Text('MP4 修复器 · Flutter 版 v$appVersion'),
            trailing: const Icon(Icons.info_outline_rounded),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('MP4 修复器'),
                content: const SingleChildScrollView(
                  child: Text(
                    '针对「部分播放器播放卡顿 / 忽快忽慢」的 MP4 的无损修复工具。\n\n'
                    '音视频交错被打乱时，同一播放时刻的音频与视频数据在文件里相距几十'
                    '甚至几百 MB（正常应 < 1MB），弱读取设备 / 流式播放就会卡顿。\n\n'
                    '修复方式：解析采样表 → 按时间重新切块并全局合并 → moov 前置 → '
                    '流式改写 mdat（样本字节原样拷贝，画质无损、不重新编码）。\n\n'
                    '引擎为纯 Dart 实现，与 Kotlin 旧版逐字节一致。',
                  ),
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

/// 图标 + 标题（+ 副标题）在上、控件在下的设置块
/// （避免把宽控件塞进 ListTile.trailing 导致标题被挤成竖排）。
class _SettingBlock extends StatelessWidget {
  const _SettingBlock({
    required this.icon,
    required this.title,
    this.subtitle,
    this.child,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(title)),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: Text(
                subtitle!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (child != null) ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: child),
          ],
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
