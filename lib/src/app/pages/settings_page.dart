import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/ui_kit.dart';

/// 设置：判定规则 / 输出位置 / 文件命名 / 外观 / 维护。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 与 pubspec.yaml 的 version 保持一致。
  static const String appVersion = '2.5.0';

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
                subtitle: const Text(
                    '只缺 moov 前置、或分片（fragmented）MP4 也一起修复（无损转换为标准 MP4）'),
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
          const _NameRuleCard(),
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
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('跳过已修复的文件'),
                subtitle: const Text(
                    '记住每个文件的修复结果：重新扫描时直接标「已修复」并跳过，不重复干活'),
                value: settings.reuseRepairs,
                onChanged: canEdit
                    ? (v) => controller.updateSettings((s) => s.reuseRepairs = v)
                    : null,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('清空修复记录'),
                subtitle: Text('当前 ${controller.ledgerLength} 条；清空后所有文件都会重新检测 / 修复'),
                trailing: const Icon(Icons.playlist_remove_rounded),
                onTap: canEdit
                    ? () {
                        controller.clearLedger();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('修复记录已清空')),
                        );
                      }
                    : null,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('清理临时文件'),
                subtitle: const Text('删除导入缓存与修复中间产物（不影响已保存的结果）'),
                trailing: const Icon(Icons.delete_outline_rounded),
                onTap: canEdit
                    ? () => guardUi(context, () async {
                        await controller.cleanCache();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清理临时文件')),
                        );
                      })
                    : null,
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
                        '分片（fragmented）MP4 会先解析 moof 得到样本，'
                        '再按同样方式无损转换为标准 MP4。\n\n'
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
              '提示：修复不会改变原文件；「上传副本」模式在服务器生成按命名规则（默认 原名_fixed.mp4）的副本，'
              '「保存到本地」模式服务器全程只读。',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「文件命名」卡片：规则 + 前缀 / 后缀输入（自带输入控制器，避免每次重建丢光标）。
class _NameRuleCard extends StatefulWidget {
  const _NameRuleCard();

  @override
  State<_NameRuleCard> createState() => _NameRuleCardState();
}

class _NameRuleCardState extends State<_NameRuleCard> {
  TextEditingController? _prefix;
  TextEditingController? _suffix;

  @override
  void dispose() {
    _prefix?.dispose();
    _suffix?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final settings = controller.settings;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final canEdit = !controller.running;
    final prefix = _prefix ??= TextEditingController(text: settings.namePrefix);
    final suffix = _suffix ??= TextEditingController(text: settings.nameSuffix);
    final needsPrefix = settings.nameMode == OutputNameMode.prefix ||
        settings.nameMode == OutputNameMode.both;
    final needsSuffix = settings.nameMode == OutputNameMode.suffix ||
        settings.nameMode == OutputNameMode.both;
    final example = settings.applyOutputName('示例视频.mp4');

    return SectionCard(
      title: '文件命名',
      icon: Icons.drive_file_rename_outline_rounded,
      children: [
        Text(
          '修好后的文件叫什么：可以保持原名（同名覆盖），也可以加前缀 / 后缀'
          '（比如 `_fixed`、`修复_`），方便和原文件区分。',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Insets.gapLarge),
        SegmentedButton<OutputNameMode>(
          showSelectedIcon: false,
          segments: [
            for (final mode in OutputNameMode.values)
              ButtonSegment(value: mode, label: Text(mode.label)),
          ],
          selected: {settings.nameMode},
          onSelectionChanged: canEdit
              ? (v) => controller.updateSettings((s) => s.nameMode = v.first)
              : null,
        ),
        const SizedBox(height: Insets.gap),
        Row(
          children: [
            Expanded(
              child: TextField(
                enabled: canEdit && needsPrefix,
                controller: prefix,
                decoration: const InputDecoration(
                  labelText: '前缀',
                  hintText: '例如 修复_',
                  isDense: true,
                ),
                onChanged: (v) =>
                    controller.updateSettings((s) => s.namePrefix = v),
              ),
            ),
            const SizedBox(width: Insets.gap),
            Expanded(
              child: TextField(
                enabled: canEdit && needsSuffix,
                controller: suffix,
                decoration: const InputDecoration(
                  labelText: '后缀',
                  hintText: '例如 _fixed',
                  isDense: true,
                ),
                onChanged: (v) =>
                    controller.updateSettings((s) => s.nameSuffix = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.gap),
        StatusStrip(
          icon: Icons.visibility_outlined,
          text: '示例：示例视频.mp4 → $example',
          tone: example == '示例视频.mp4'
              ? StatusTone.neutral
              : StatusTone.good,
        ),
      ],
    );
  }
}
