import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../ui.dart';
import '../widgets/ui_kit.dart';

/// 设置：判定规则 / 输出位置 / 外观 / 维护。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 与 pubspec.yaml 的 version 保持一致。
  static const String appVersion = '2.3.1';

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final settings = controller.settings;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final canEdit = !controller.running;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 96),
        children: [
          SectionCard(
            title: '判定规则',
            icon: Icons.tune_rounded,
            children: [
              const Text('最大交错距离超过阈值即视为「需重排」'),
              const SizedBox(height: Insets.gapLarge),
              Row(
                children: [
                  const Text('阈值'),
                  const Spacer(),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1M')),
                      ButtonSegment(value: 2, label: Text('2M')),
                      ButtonSegment(value: 4, label: Text('4M')),
                      ButtonSegment(value: 8, label: Text('8M')),
                    ],
                    selected: {settings.thresholdMb},
                    onSelectionChanged: canEdit
                        ? (v) => controller
                            .updateSettings((s) => s.thresholdMb = v.first)
                        : null,
                  ),
                ],
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('同时处理「可优化」'),
                subtitle: const Text('只缺 moov 前置的文件也一起修复'),
                value: settings.includeOptimizable,
                onChanged: canEdit
                    ? (v) => controller
                        .updateSettings((s) => s.includeOptimizable = v)
                    : null,
              ),
            ],
          ),
          SectionCard(
            title: '输出位置',
            icon: Icons.save_alt_rounded,
            children: [
              StatusStrip(
                icon: Icons.folder_rounded,
                text: controller.outputDescription,
                tone: controller.hasCustomOutput
                    ? StatusTone.good
                    : StatusTone.neutral,
              ),
              const SizedBox(height: Insets.gap),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: Insets.gap,
                  children: [
                    if (controller.hasCustomOutput)
                      TextButton(
                        onPressed: canEdit
                            ? () => controller.updateSettings((s) {
                                  s.outputTreeUri = null;
                                  s.outputDirPath = null;
                                })
                            : null,
                        child: const Text('恢复默认'),
                      ),
                    FilledButton.tonal(
                      onPressed: canEdit
                          ? () => guardUi(context, controller.pickOutputFolder)
                          : null,
                      child: const Text('选择文件夹'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SectionCard(
            title: '外观',
            icon: Icons.palette_rounded,
            children: [
              Row(
                children: [
                  const Text('主题'),
                  const Spacer(),
                  SegmentedButton<ThemeMode>(
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
                ],
              ),
            ],
          ),
          SectionCard(
            title: '维护',
            icon: Icons.cleaning_services_rounded,
            children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('清理临时文件'),
                subtitle: const Text('删除导入缓存与修复中间产物（不影响已保存的结果）'),
                trailing: const Icon(Icons.delete_outline_rounded),
                onTap: () => guardUi(context, () async {
                  await controller.cleanCache();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清理临时文件')),
                  );
                }),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('复制诊断信息'),
                subtitle: const Text('平台 / 路径 / 是否存在等，反馈问题时附上它'),
                trailing: const Icon(Icons.bug_report_outlined),
                onTap: () => guardUi(context, () async {
                  final info = await controller.collectDiagnostics();
                  await Clipboard.setData(ClipboardData(text: info));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('诊断信息已复制到剪贴板')),
                  );
                }),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
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
                        '引擎为纯 Dart 实现，与 Kotlin 旧版逐字节一致；'
                        '仓库：github.com/U707T/mp4fix',
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
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.page, Insets.gap, Insets.page, 0),
            child: Text(
              '提示：修复不会改变原文件；「上传副本」模式在服务器生成 原名_fixed.mp4，'
              '「保存到本地」模式服务器全程只读。',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
