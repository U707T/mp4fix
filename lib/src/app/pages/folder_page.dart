import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';

/// 文件夹批量检测 / 修复（Android 走 SAF；桌面走普通目录）。
class FolderPage extends StatelessWidget {
  const FolderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final jobs = controller.jobsOf(JobSource.folder);
    final busy = controller.runningSource == JobSource.folder;
    final canRun = !controller.running;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('文件夹批量')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_rounded),
                  title: const Text('输入文件夹'),
                  subtitle: Text(
                    controller.scanInputDescription,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: canRun
                        ? () => guardUi(context, controller.pickScanInputFolder)
                        : null,
                    child: const Text('选择'),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.save_alt_rounded),
                  title: const Text('输出文件夹'),
                  subtitle: Text(
                    controller.outputDescription,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: canRun
                        ? () => guardUi(context, controller.pickOutputFolder)
                        : null,
                    child: const Text('选择'),
                  ),
                ),
                const Divider(height: 1),
                // 阈值：不要塞进 ListTile.trailing（宽度会被挤爆，标题竖排）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune_rounded, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('判定阈值（最大交错距离）')),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 32, top: 4),
                        child: Text(
                          '几十~几百 MB 的交错才是卡顿元凶；几百 KB 的不用管',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: SegmentedButton<int>(
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
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('同时处理「可优化」'),
                  subtitle: const Text('只缺 moov 前置的文件也一起处理（串流更顺）'),
                  value: controller.settings.includeOptimizable,
                  onChanged: canRun
                      ? (v) =>
                          controller.updateSettings((s) => s.includeOptimizable = v)
                      : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: canRun
                      ? () => guardUi(
                          context, () => controller.scanFolder(fixAfterScan: false))
                      : null,
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: const Text('仅扫描'),
                ),
                FilledButton.icon(
                  onPressed: canRun
                      ? () => guardUi(
                          context, () => controller.scanFolder(fixAfterScan: true))
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
                TextButton(
                  onPressed: canRun && jobs.isNotEmpty
                      ? () => controller.clearJobs(JobSource.folder)
                      : null,
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: jobs.isEmpty
                ? const EmptyHint(
                    icon: Icons.folder_copy_rounded,
                    title: '递归检测整个文件夹',
                    subtitle: '选择输入文件夹后点「仅扫描」只做体检；\n'
                        '「扫描并修复」会把需重排的文件无损重排后写入输出文件夹',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: jobs.length,
                    itemBuilder: (context, i) => JobTile(job: jobs[i]),
                  ),
          ),
        ],
      ),
    );
  }
}
