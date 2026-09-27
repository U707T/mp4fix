import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// 文件夹批量检测 / 修复（Android 走 SAF；桌面走普通目录）。
class FolderPage extends StatelessWidget {
  const FolderPage({super.key});

  Future<void> _confirmClear(BuildContext context, void Function() clear) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空列表？'),
        content: const Text('会移除当前列表里的任务与检测结果（已保存的文件不受影响）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok ?? false) clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final jobs = controller.jobsOf(JobSource.folder);
    final busy = controller.runningSource == JobSource.folder;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(title: const Text('文件夹批量')),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        children: [
          SectionCard(
            title: '位置',
            icon: Icons.folder_copy_rounded,
            children: [
              StatusStrip(
                icon: Icons.folder_rounded,
                text: '输入：${controller.scanInputDescription}',
                tone: controller.scanInputDescription.startsWith('未选择')
                    ? StatusTone.warn
                    : StatusTone.good,
                trailing: TextButton(
                  onPressed: canRun
                      ? () => guardUi(context, controller.pickScanInputFolder)
                      : null,
                  child: const Text('选择'),
                ),
                onTap: canRun
                    ? () => guardUi(context, controller.pickScanInputFolder)
                    : null,
              ),
              StatusStrip(
                icon: Icons.save_alt_rounded,
                text: controller.outputDescription,
                tone: controller.hasCustomOutput
                    ? StatusTone.good
                    : StatusTone.neutral,
                trailing: TextButton(
                  onPressed: canRun
                      ? () => guardUi(context, controller.pickOutputFolder)
                      : null,
                  child: const Text('选择'),
                ),
                onTap: canRun
                    ? () => guardUi(context, controller.pickOutputFolder)
                    : null,
              ),
            ],
          ),
          SectionCard(
            title: '判定规则',
            icon: Icons.tune_rounded,
            children: [
              Text(
                '最大交错距离超过阈值即视为「需重排」；几十~几百 MB 才是卡顿元凶，几百 KB 的不用管。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
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
                    selected: {controller.settings.thresholdMb},
                    onSelectionChanged: canRun
                        ? (values) => controller
                            .updateSettings((s) => s.thresholdMb = values.first)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('同时处理「可优化」'),
                subtitle: const Text('只缺 moov 前置的文件也一起处理（串流更顺）'),
                value: controller.settings.includeOptimizable,
                onChanged: canRun
                    ? (v) => controller
                        .updateSettings((s) => s.includeOptimizable = v)
                    : null,
              ),
            ],
          ),
          ActionBar(
            actions: [
              FilledButton.tonalIcon(
                onPressed: canRun
                    ? () => guardUi(context,
                        () => controller.scanFolder(fixAfterScan: false))
                    : null,
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('仅扫描'),
              ),
              FilledButton.icon(
                onPressed: canRun
                    ? () => guardUi(context,
                        () => controller.scanFolder(fixAfterScan: true))
                    : null,
                icon: const Icon(Icons.build_rounded),
                label: const Text('扫描并修复'),
              ),
              if (busy)
                OutlinedButton.icon(
                  onPressed: controller.requestCancel,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('停止'),
                ),
              if (!busy && jobs.isNotEmpty)
                TextButton(
                  onPressed: () => _confirmClear(
                      context, () => controller.clearJobs(JobSource.folder)),
                  child: const Text('清空'),
                ),
            ],
          ),
          JobSummaryBar(
            jobs: jobs,
            active: busy ? controller.batchDone : null,
            total: busy ? controller.batchTotal : null,
          ),
          if (controller.lastNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.page, Insets.gap, Insets.page, 0),
              child: StatusStrip(
                icon: Icons.info_outline_rounded,
                text: controller.lastNotice!,
                tone: StatusTone.warn,
              ),
            ),
          if (jobs.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: EmptyHint(
                icon: Icons.folder_copy_rounded,
                title: '递归检测整个文件夹',
                subtitle: '「仅扫描」只做体检；\n'
                    '「扫描并修复」会把需重排的文件无损重排后写入输出位置。',
              ),
            )
          else
            for (final job in jobs) JobTile(job: job),
        ],
      ),
    );
  }
}
