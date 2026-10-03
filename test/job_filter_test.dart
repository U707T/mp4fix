import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/models.dart';

/// 任务状态 / 筛选分组的语义（列表上方「额外的按钮」靠它分组）。
void main() {
  test('状态标记：可修复 / 问题 / 完成 / 进行中', () {
    expect(JobStatus.needsFix.fixable, isTrue);
    expect(JobStatus.optimizable.fixable, isTrue);
    expect(JobStatus.ok.fixable, isFalse);
    expect(JobStatus.reused.fixable, isFalse);

    expect(JobStatus.corrupt.problematic, isTrue);
    expect(JobStatus.failed.problematic, isTrue);
    expect(JobStatus.cancelled.problematic, isFalse, reason: '取消不是损坏，可以重试');

    expect(JobStatus.saved.finished, isTrue);
    expect(JobStatus.uploaded.finished, isTrue);
    expect(JobStatus.reused.finished, isTrue);
    expect(JobStatus.ok.finished, isFalse);

    expect(JobStatus.inspecting.busy, isTrue);
    expect(JobStatus.fixing.busy, isTrue);
    expect(JobStatus.ok.busy, isFalse);
  });

  test('筛选分组：待处理 / 待优化 / 正常 / 问题 / 已完成', () {
    bool match(JobFilter filter, JobStatus status) => filter.matches(status);

    // 待处理：还没修的问题项（含正在跑的和被取消的）
    for (final s in [
      JobStatus.pending,
      JobStatus.inspecting,
      JobStatus.fixing,
      JobStatus.needsFix,
      JobStatus.cancelled,
    ]) {
      expect(match(JobFilter.todo, s), isTrue, reason: '$s 应属于待处理');
    }
    expect(match(JobFilter.todo, JobStatus.ok), isFalse);

    // 待优化 / 正常
    expect(match(JobFilter.optimize, JobStatus.optimizable), isTrue);
    expect(match(JobFilter.optimize, JobStatus.needsFix), isFalse);
    expect(match(JobFilter.ok, JobStatus.ok), isTrue);
    expect(match(JobFilter.ok, JobStatus.reused), isFalse);

    // 问题：损坏 / 不支持 / 读取失败 / 修复失败
    for (final s in [
      JobStatus.corrupt,
      JobStatus.unsupported,
      JobStatus.error,
      JobStatus.failed,
    ]) {
      expect(match(JobFilter.problem, s), isTrue, reason: '$s 应属于问题');
    }

    // 已完成：保存 / 上传 / 复用
    for (final s in [JobStatus.saved, JobStatus.uploaded, JobStatus.reused]) {
      expect(match(JobFilter.finished, s), isTrue, reason: '$s 应属于已完成');
    }

    // 全部：不挑不拣
    for (final s in JobStatus.values) {
      expect(match(JobFilter.all, s), isTrue);
    }
  });

  test('「已修复（复用）」有独立的文案，和"正常"区分开', () {
    expect(JobStatus.reused.label, '已修复');
    expect(JobStatus.ok.label, '正常');
    expect(JobStatus.needsFix.label, '需重排');
  });
}
