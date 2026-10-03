import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// 文件夹批量检测 / 修复（Android 走 SAF；桌面走普通目录）。
class FolderPage extends StatefulWidget {
  const FolderPage({super.key});

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  JobFilter _filter = JobFilter.all;

  /// 清空 → 直接执行 + 撤销入口（不再弹确认框）。
  void _clearWithUndo(BuildContext context, AppController controller) {
    final messenger = ScaffoldMessenger.of(context);
    final removed = controller.jobsOf(JobSource.folder).length;
    if (removed == 0) return;
    controller.clearJobs(JobSource.folder);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已清空 $removed 项'),
        action: SnackBarAction(label: '撤销', onPressed: controller.undoClear),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final all = controller.jobsOf(JobSource.folder);
    final jobs =
        all.where((j) => _filter.matches(j.status)).toList(growable: false);
    final busy = controller.runningSource == JobSource.folder;
    final canRun = !controller.running;

    // 头部（位置 / 规则 / 操作 / 汇总）+ 任务列表；列表用 builder 惰性构建，
    // 几千个视频的文件夹也不会一次性建出所有行。
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件夹批量'),
        actions: [
          if (controller.canOpenOutputLocation)
            IconButton(
              tooltip: '打开输出文件夹',
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: canRun
                  ? () => guardUi(context, controller.openOutputLocation)
                  : null,
            ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        itemCount: jobs.isEmpty ? 1 : jobs.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) return JobTile(job: jobs[index - 1]);
          return _buildHeader(context, controller, all, busy, canRun);
        },
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppController controller,
    List<FixJob> all,
    bool busy,
    bool canRun,
  ) {
    final jobs =
        all.where((j) => _filter.matches(j.status)).toList(growable: false);
    return Column(
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
              text: controller.folderOutputDescription,
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
          collapsible: true,
          initiallyExpanded: false,
          summary: '阈值 ${controller.settings.thresholdMb} MB'
              ' · ${controller.settings.includeOptimizable ? '含可优化' : '不含可优化'}',
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
              subtitle: const Text(
                  '只缺 moov 前置、或分片（fragmented）MP4 也一起处理（转换为标准 MP4，兼容性更好）'),
              value: controller.settings.includeOptimizable,
              onChanged: canRun
                  ? (v) =>
                      controller.updateSettings((s) => s.includeOptimizable = v)
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
          fixableCount: controller.fixableCount(JobSource.folder),
          onFixAll: canRun && controller.hasFixable(JobSource.folder)
              ? () =>
                  guardUi(context, () => controller.fixJobs(JobSource.folder))
              : null,
          onProcessAll:
              canRun && controller.processAllCount(JobSource.folder) > 0
                  ? () => runProcessAll(context, controller, JobSource.folder)
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
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyHint(
              icon: Icons.folder_copy_rounded,
              title: '递归检测整个文件夹',
              subtitle: '「仅扫描」只做体检；\n'
                  '「扫描并修复」会把需重排的文件无损重排后写入输出位置。',
            ),
          )
        else if (jobs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyHint(
              icon: Icons.filter_alt_off_rounded,
              title: '这个筛选下没有任务',
              subtitle: '点上方「全部」查看完整列表。',
            ),
          ),
      ],
    );
  }
}
