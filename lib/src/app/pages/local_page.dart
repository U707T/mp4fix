import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// 本地文件修复：多选视频 → 自动检测 → 一键修复 → 保存到输出位置。
class LocalPage extends StatelessWidget {
  const LocalPage({super.key});

  Future<void> _confirmClear(
    BuildContext context,
    void Function() clear,
  ) async {
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
    final jobs = controller.jobsOf(JobSource.local);
    final busy = controller.runningSource == JobSource.local;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地文件'),
        actions: [
          IconButton(
            tooltip: '选择输出文件夹',
            icon: const Icon(Icons.drive_folder_upload_rounded),
            onPressed:
                canRun ? () => guardUi(context, controller.pickOutputFolder) : null,
          ),
        ],
      ),
      body: Column(
        children: [
          SectionCard(
            children: [
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
                  child: const Text('更改'),
                ),
                onTap: canRun
                    ? () => guardUi(context, controller.pickOutputFolder)
                    : null,
              ),
              StatusStrip(
                icon: Icons.tune_rounded,
                text: '${controller.thresholdDescription}（在「设置」里可调）',
              ),
            ],
          ),
          ActionBar(
            actions: [
              FilledButton.tonalIcon(
                onPressed:
                    canRun ? () => guardUi(context, controller.pickLocalFiles) : null,
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加视频'),
              ),
              FilledButton.icon(
                onPressed: (canRun && controller.hasFixable(JobSource.local))
                    ? () => guardUi(
                        context, () => controller.fixJobs(JobSource.local))
                    : null,
                icon: const Icon(Icons.build_rounded),
                label: const Text('开始修复'),
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
                      context, () => controller.clearJobs(JobSource.local)),
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
          Expanded(
            child: jobs.isEmpty
                ? const EmptyHint(
                    icon: Icons.video_file_rounded,
                    title: '还没有添加视频',
                    subtitle: '点「添加视频」选择一个或多个 MP4 / M4V / MOV。\n'
                        '添加后会立刻体检（只读文件头与 moov，不改动原文件）。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    itemCount: jobs.length,
                    itemBuilder: (context, i) => JobTile(job: jobs[i]),
                  ),
          ),
        ],
      ),
    );
  }
}
