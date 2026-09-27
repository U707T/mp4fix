import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// 本地文件修复：多选视频 → 自动检测 → 一键修复 → 保存到输出位置。
class LocalPage extends StatelessWidget {
  const LocalPage({super.key});

  /// 清空 → 直接执行 + 撤销入口（不再弹确认框，少一步且可回退）。
  void _clearWithUndo(BuildContext context, AppController controller) {
    final messenger = ScaffoldMessenger.of(context);
    final removed = controller.jobsOf(JobSource.local).length;
    if (removed == 0) return;
    controller.clearJobs(JobSource.local);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已清空 $removed 项'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: controller.undoClear,
        ),
      ),
    );
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
                onPressed: canRun
                    ? () => guardUi(context, controller.pickLocalFiles)
                    : null,
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加视频'),
              ),
              // 一次点击走完全流程：选文件 → 自动检测 → 自动修复可修项
              FilledButton.icon(
                onPressed: canRun
                    ? () => guardUi(
                        context,
                        () => controller.pickLocalFiles(fixAfterPick: true))
                    : null,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: const Text('添加并修复'),
              ),
              if (!busy && jobs.isNotEmpty)
                TextButton(
                  onPressed: () => _clearWithUndo(context, controller),
                  child: const Text('清空'),
                ),
            ],
          ),
          JobSummaryBar(
            jobs: jobs,
            active: busy ? controller.batchDone : null,
            total: busy ? controller.batchTotal : null,
            onFixAll: canRun && controller.hasFixable(JobSource.local)
                ? () => guardUi(
                    context, () => controller.fixJobs(JobSource.local))
                : null,
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
