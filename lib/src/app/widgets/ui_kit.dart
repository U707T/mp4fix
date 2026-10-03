import 'package:flutter/material.dart';

import '../models.dart';

/// 统一的界面度量（间距 / 圆角 / 图标尺寸）。
///
/// 四个页面此前各写各的 padding、字号、卡片样式 —— 这是"看着不协调"的根源。
abstract final class Insets {
  static const double page = 16;
  static const double card = 12;
  static const double gap = 8;
  static const double gapLarge = 12;
  static const double radius = 14;
  static const double iconSmall = 16;
  static const double icon = 20;
}

/// 页面里的分区卡片：统一的标题 + 内容 + 内边距。
///
/// [collapsible] 为真时标题行可点按展开/收起；收起状态只显示一行 [summary] ——
/// 表单类内容默认收起，避免整页被"摊开"得又长又要滚。
class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    this.title,
    this.icon,
    this.trailing,
    required this.children,
    this.padding,
    this.collapsible = false,
    this.summary,
    this.initiallyExpanded = true,
  });

  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final bool collapsible;
  final String? summary;
  final bool initiallyExpanded;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  late bool _expanded = widget.initiallyExpanded || !widget.collapsible;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final showBody = _expanded || !widget.collapsible;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(
        horizontal: Insets.page,
        vertical: Insets.gap / 2,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radius),
      ),
      child: Padding(
        padding: widget.padding ??
            const EdgeInsets.fromLTRB(
              Insets.page,
              Insets.card,
              Insets.page,
              Insets.card,
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.title != null)
              InkWell(
                onTap: widget.collapsible
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                borderRadius: BorderRadius.circular(Insets.gap),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: Insets.icon, color: scheme.primary),
                        const SizedBox(width: Insets.gapLarge),
                      ],
                      Expanded(
                        child: Text(
                          widget.title!,
                          style: text.titleSmall?.copyWith(color: scheme.primary),
                        ),
                      ),
                      ?widget.trailing,
                      if (widget.collapsible)
                        Icon(
                          showBody
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: Insets.icon,
                          color: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ),
            if (showBody) ...[
              if (widget.title != null) const SizedBox(height: Insets.gapLarge),
              ...widget.children,
            ] else if (widget.summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.summary!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一行"当前状态 / 位置"信息（可点按触发动作）。
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.icon,
    required this.text,
    this.trailing,
    this.onTap,
    this.tone = StatusTone.neutral,
  });

  final IconData icon;
  final String text;
  final Widget? trailing;
  final VoidCallback? onTap;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      StatusTone.neutral => scheme.onSurfaceVariant,
      StatusTone.good => scheme.primary,
      StatusTone.warn => scheme.tertiary,
      StatusTone.bad => scheme.error,
    };
    final row = Row(
      children: [
        Icon(icon, size: Insets.iconSmall, color: color),
        const SizedBox(width: Insets.gap),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        ?trailing,
      ],
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Insets.gap),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      ),
    );
  }
}

enum StatusTone { neutral, good, warn, bad }

/// 统一的按钮行：主操作在前，停止 / 清空等次级操作在后；窄屏自动换行。
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.page, Insets.gap, Insets.page, 0),
    child: Wrap(
      spacing: Insets.gap,
      runSpacing: Insets.gap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    ),
  );
}

/// 任务汇总（按状态计数）+ 总进度 + 一键修复按钮。
class JobSummaryBar extends StatelessWidget {
  const JobSummaryBar({
    super.key,
    required this.jobs,
    this.active,
    this.total,
    this.onFixAll,
    this.onProcessAll,
  });

  final List<FixJob> jobs;

  /// 批量任务进行中：已处理 / 总数（用于总进度条）。
  final int? active;
  final int? total;

  /// 一键修复"已有检测结果里可修复的那些"（**不重新扫描**）。
  final VoidCallback? onFixAll;

  /// 一键处理"包括正常在内的全部视频"（重排所有还没处理过的文件）。
  final VoidCallback? onProcessAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (jobs.isEmpty) return const SizedBox.shrink();

    int count(JobStatus s) => jobs.where((j) => j.status == s).length;
    final running = jobs.where((j) => j.status.busy).length;
    final pending = jobs.where((j) => j.status == JobStatus.pending).length;
    final fixableCount = jobs.where((j) => j.status.fixable).length;
    final doneCount = jobs.where((j) => j.status.finished).length;
    final problemCount = jobs.where((j) => j.status.problematic).length;

    final parts = <String>[
      '共 ${jobs.length}',
      if (running > 0) '进行中 $running',
      if (pending > 0) '待处理 $pending',
      if (count(JobStatus.ok) > 0) '正常 ${count(JobStatus.ok)}',
      if (count(JobStatus.needsFix) > 0) '需重排 ${count(JobStatus.needsFix)}',
      if (count(JobStatus.optimizable) > 0) '可优化 ${count(JobStatus.optimizable)}',
      if (doneCount > 0) '已完成 $doneCount',
      if (problemCount > 0) '问题 $problemCount',
    ];

    final showProgress = active != null && total != null && total! > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.page, Insets.gap, Insets.page, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showProgress) ...[
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (active! / total!).clamp(0.0, 1.0),
                      minHeight: 4,
                    ),
                  ),
                ),
                const SizedBox(width: Insets.gap),
                Text('$active/$total',
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  parts.join(' · '),
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (onProcessAll != null) ...[
                const SizedBox(width: Insets.gap),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onProcessAll,
                  icon: const Icon(Icons.layers_rounded, size: 18),
                  label: const Text('全部处理'),
                ),
              ],
              if (onFixAll != null && fixableCount > 0) ...[
                const SizedBox(width: Insets.gap),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onFixAll,
                  icon: const Icon(Icons.build_rounded, size: 18),
                  label: Text('修复 $fixableCount 项'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 任务筛选（"额外的按钮列表"）：按状态查看列表里到底有哪些视频待处理 / 待优化。
///
/// 每个筛选项带上数量；点一下只显示该组任务，再点「全部」回到完整列表。
class JobFilterBar extends StatelessWidget {
  const JobFilterBar({
    super.key,
    required this.jobs,
    required this.value,
    required this.onChanged,
  });

  final List<FixJob> jobs;
  final JobFilter value;
  final ValueChanged<JobFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final counts = <JobFilter, int>{
      for (final filter in JobFilter.values)
        filter: jobs.where((j) => filter.matches(j.status)).length,
    };
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Insets.page),
        children: [
          for (final filter in JobFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: Insets.gap / 2),
              child: FilterChip(
                label: Text(
                  '${filter.label} ${counts[filter]}',
                  style: const TextStyle(fontSize: 12),
                ),
                visualDensity: VisualDensity.compact,
                selected: value == filter,
                showCheckmark: false,
                side: BorderSide(
                  color: value == filter ? Colors.transparent : scheme.outlineVariant,
                ),
                onSelected: (_) => onChanged(filter),
              ),
            ),
        ],
      ),
    );
  }
}


/// 空状态（统一图标 / 文案 / 间距）。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.page * 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.outline),
            const SizedBox(height: Insets.gapLarge),
            Text(title, style: text.titleSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
