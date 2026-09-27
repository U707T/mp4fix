import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';

/// 本地文件修复：多选视频 → 自动检测 → 一键修复 → 保存到输出文件夹。
class LocalPage extends StatelessWidget {
  const LocalPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final jobs = controller.jobsOf(JobSource.local);
    final busy = controller.runningSource == JobSource.local;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地文件'),
        actions: [
          IconButton(
            tooltip: '选择输出文件夹',
            icon: const Icon(Icons.drive_folder_upload_rounded),
            onPressed: controller.running
                ? null
                : () => guardUi(context, controller.pickOutputFolder),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.save_alt_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        controller.outputDescription,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      controller.thresholdDescription,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: controller.running
                          ? null
                          : () => guardUi(context, controller.pickLocalFiles),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加视频'),
                    ),
                    FilledButton.icon(
                      onPressed: (!controller.running &&
                              controller.hasFixable(JobSource.local))
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
                    TextButton(
                      onPressed: (!controller.running && jobs.isNotEmpty)
                          ? () => controller.clearJobs(JobSource.local)
                          : null,
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: jobs.isEmpty
                ? const EmptyHint(
                    icon: Icons.video_file_rounded,
                    title: '还没有添加视频',
                    subtitle: '点「添加视频」选择一个或多个 MP4 / M4V / MOV，\n添加后会自动检测交错情况（不改动原文件）',
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
