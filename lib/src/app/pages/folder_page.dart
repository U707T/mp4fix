import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../widgets/job_tile.dart';

/// 文件夹批量检测 / 修复（Android 走 SAF；桌面走普通目录）。
class FolderPage extends StatelessWidget {
  const FolderPage({super.key});

  Future<void> _guard(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final jobs = controller.jobsOf(JobSource.folder);
    final busy = controller.runningSource == JobSource.folder;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件夹批量'),
        actions: [
          IconButton(
            tooltip: '选择输出文件夹',
            icon: const Icon(Icons.create_new_folder_rounded),
            onPressed: canRun ? () => controller.pickOutputFolder() : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Column(
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
                        ? () => controller.pickScanInputFolder()
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
                        ? () => controller.pickOutputFolder()
                        : null,
                    child: const Text('选择'),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('判定阈值（最大交错距离）'),
                  subtitle: const Text('几十~几百 MB 才是卡顿元凶；几百 KB 的不用管'),
                  trailing: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1M')),
                      ButtonSegment(value: 2, label: Text('2M')),
                      ButtonSegment(value: 4, label: Text('4M')),
                      ButtonSegment(value: 8, label: Text('8M')),
                    ],
                    selected: {controller.settings.thresholdMb},
                    onSelectionChanged: canRun
                        ? (values) => controller.updateSettings(
                            (s) => s.thresholdMb = values.first)
                        : null,
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('同时处理「可优化」'),
                  subtitle: const Text('只缺 moov 前置的文件也一起处理（串流更顺）'),
                  value: controller.settings.includeOptimizable,
                  onChanged: canRun
                      ? (v) => controller.updateSettings(
                          (s) => s.includeOptimizable = v)
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
                      ? () => _guard(context,
                          () => controller.scanFolder(fixAfterScan: false))
                      : null,
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: const Text('仅扫描'),
                ),
                FilledButton.icon(
                  onPressed: canRun
                      ? () => _guard(context,
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
                    subtitle: '选择输入文件夹后点「仅扫描」只做体检；\n「扫描并修复」会把需重排的文件无损重排后写入输出文件夹',
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
