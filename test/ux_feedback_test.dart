import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';

/// 「干完活要告诉用户结果」的回归。
///
/// 事故：扫描 / 批量修复结束后只更新列表，没有任何汇总。用户扫完一个几百个
/// 文件的目录，界面既不显示扫到几个、也不显示有几个需要重排、失败的原因是什么 ——
/// 只能自己一行行数，或者干脆以为「点了没反应」。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mp4fix-ux');
    File('test/fixtures/good.mp4').copySync('${dir.path}/good.mp4');
    File('test/fixtures/bad_interleave.mp4')
        .copySync('${dir.path}/bad.mp4');
    File('test/fixtures/truncated.mp4').copySync('${dir.path}/truncated.mp4');
    File('${dir.path}/note.txt').writeAsStringSync('not a video');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('仅扫描结束：给出「扫到几个 / 几个需重排」的汇总', () async {
    final c = AppController();
    c.settings.scanInputDirPath = dir.path;

    await c.scanFolder(fixAfterScan: false);

    final notice = c.lastNotice;
    expect(notice, isNotNull, reason: '扫描结束必须有一句结果汇总');
    expect(notice, contains('扫描完成'));
    expect(notice, contains('3 个视频'), reason: '只数视频，不数 note.txt：$notice');
    // 阈值默认 4MB / 2s：113KB 的小夹具不会触发「需重排」，但 truncated 会被判损坏
    expect(notice, contains('读取失败 1 个'), reason: '$notice');
    expect(c.jobsOf(JobSource.folder), hasLength(3));
  });

  test('提示可以手动关闭（否则一直占着列表上方）', () async {
    final c = AppController();
    c.lastNotice = '随便一条提示';
    c.clearNotice();
    expect(c.lastNotice, isNull);
  });

  test('同一个文件重复拖入：不生成重复任务', () async {
    final c = AppController();
    final path = '${dir.path}/good.mp4';

    expect(await c.importPaths([path]), 1);
    expect(await c.importPaths([path]), 0, reason: '第二次拖入是重复的，不该再加一条');

    expect(c.jobsOf(JobSource.local), hasLength(1));
    expect(c.lastNotice, contains('已经在列表里'));
  });

  test('拖入整个文件夹：重复拖入同样不翻倍', () async {
    final c = AppController();

    final first = await c.importPaths([dir.path]);
    expect(first, 3, reason: 'good / bad / truncated');
    final jobsAfterFirst = c.jobsOf(JobSource.local).length;

    final second = await c.importPaths([dir.path]);
    expect(second, 0);
    expect(c.jobsOf(JobSource.local), hasLength(jobsAfterFirst));
  });
}
