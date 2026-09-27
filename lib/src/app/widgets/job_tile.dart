import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../app_scope.dart';
import '../models.dart';

/// 任务列表项：文件名 / 状态 / 说明 / 进度。
class JobTile extends StatelessWidget {
  const JobTile({super.key, required this.job});

  final FixJob job;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = job.status;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
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
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(status: status),
                if (!job.busy)
                  IconButton(
                    tooltip: '移除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => controller.removeJob(job),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (job.displayPath.isNotEmpty) job.displayPath,
                formatBytes(job.size),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (job.message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(job.message, style: const TextStyle(fontSize: 12)),
            ],
            if (status.busy) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: job.progress > 0 ? job.progress : null,
                  minHeight: 6,
                ),
              ),
            ],
            if (job.status.fixable && !controller.running) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => controller.fixJobs(job.source, [job]),
                  icon: const Icon(Icons.build_rounded, size: 18),
                  label: const Text('修复这条'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      JobStatus.ok || JobStatus.saved || JobStatus.uploaded =>
        (scheme.primaryContainer, scheme.onPrimaryContainer),
      JobStatus.needsFix || JobStatus.optimizable || JobStatus.fixing ||
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
        style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// 空列表提示。
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
