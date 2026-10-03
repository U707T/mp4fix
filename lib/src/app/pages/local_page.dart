import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// 本地文件修复：多选视频 / 拖入 → 自动检测 → 一键修复 → 保存到输出位置。
class LocalPage extends StatefulWidget {
  const LocalPage({super.key});

  @override
  State<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<LocalPage> {
  JobFilter _filter = JobFilter.all;

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
    final all = controller.jobsOf(JobSource.local);
    final jobs =
        all.where((j) => _filter.matches(j.status)).toList(growable: false);
    final busy = controller.runningSource == JobSource.local;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地文件'),
        actions: [
          if (controller.canOpenOutputLocation)
            IconButton(
              tooltip: '打开输出文件夹',
              icon: const Icon(Icons.folder_open_rounded),
              onPressed:
                  canRun ? () => guardUi(context, controller.openOutputLocation) : null,
            ),
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
                text: '${controller.thresholdDescription}'
                    '${controller.settings.nameRuleHint.isEmpty ? '' : ' · ${controller.settings.nameRuleHint}'}'
                    '（在「设置」里可调）',
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
              if (!busy && all.isNotEmpty)
                TextButton(
                  onPressed: () => _clearWithUndo(context, controller),
                  child: const Text('清空'),
                ),
            ],
          ),
          JobFilterBar(
            jobs: all,
            value: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),
          JobSummaryBar(
            jobs: all,
            active: busy ? controller.batchDone : null,
            total: busy ? controller.batchTotal : null,
            onFixAll: canRun && controller.hasFixable(JobSource.local)
                ? () => guardUi(
                    context, () => controller.fixJobs(JobSource.local))
                : null,
            onProcessAll:
                canRun && controller.processAllCount(JobSource.local) > 0
                    ? () => runProcessAll(context, controller, JobSource.local)
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
                ? EmptyHint(
                    icon: Icons.video_file_rounded,
                    title: all.isEmpty ? '还没有添加视频' : '这个筛选下没有任务',
                    subtitle: all.isEmpty
                        ? '点「添加视频」选择一个或多个 MP4 / M4V / MOV；\n'
                            'Windows 上也可以直接把视频或文件夹拖进窗口。\n'
                            '添加后会立刻体检（只读文件头与 moov，不改动原文件）。'
                        : '点上方「全部」查看完整列表。',
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
