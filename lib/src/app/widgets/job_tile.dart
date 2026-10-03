import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../app_scope.dart';
import '../models.dart';
import 'ui_kit.dart';

/// 任务列表项：文件名 / 状态 / 说明 / 进度。
class JobTile extends StatelessWidget {
  const JobTile({super.key, required this.job});

  final FixJob job;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final status = job.status;
    final canRetry = (status.fixable ||
            status == JobStatus.failed ||
            status == JobStatus.cancelled) &&
        !controller.running;
    // 已修复（复用上次结果）→ 可以「重做」（清掉记录重新检测 + 修复）
    final canRedo = status == JobStatus.reused && !controller.running;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(
        horizontal: Insets.page,
        vertical: 4,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.page,
          Insets.card,
          Insets.gap / 2,
          Insets.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    job.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                ),
                const SizedBox(width: Insets.gap),
                StatusChip(status: status),
                IconButton(
                  tooltip: '从列表移除',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: job.busy ? null : () => controller.removeJob(job),
                ),
              ],
            ),
            Text(
              [
                if (job.displayPath.isNotEmpty) job.displayPath,
                formatBytes(job.size),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (job.message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                job.message,
                style: text.bodySmall?.copyWith(
                  color: status.problematic ? scheme.error : null,
                ),
              ),
            ],
            if (status.busy) ...[
              const SizedBox(height: Insets.gap),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: job.progress > 0 ? job.progress : null,
                  minHeight: 5,
                ),
              ),
            ],
            if (canRetry || canRedo)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => canRedo
                      ? controller.redoJob(job)
                      : (job.source == JobSource.webdav
                          ? controller.fixWebDavJobs(only: [job])
                          : controller.fixJobs(job.source, [job])),
                  icon: Icon(
                    canRedo ? Icons.refresh_rounded : Icons.build_rounded,
                    size: 18,
                  ),
                  label: Text(
                    canRedo
                        ? '重做'
                        : (status.fixable ? '修复这条' : '重试'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 状态色芯片（配色统一在这里维护）。
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      JobStatus.ok || JobStatus.saved || JobStatus.uploaded || JobStatus.reused =>
        (scheme.primaryContainer, scheme.onPrimaryContainer),
      JobStatus.needsFix ||
      JobStatus.optimizable ||
      JobStatus.fixing ||
      JobStatus.inspecting =>
        (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      JobStatus.corrupt ||
      JobStatus.unsupported ||
      JobStatus.error ||
      JobStatus.failed =>
        (scheme.errorContainer, scheme.onErrorContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          color: fg,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
