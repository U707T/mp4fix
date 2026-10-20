import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';
import 'package:mp4fix/src/app/output_target.dart';
import 'package:mp4fix/src/app/repair_ledger.dart';

/// 「递归扫描文件夹时要保留子目录结构」的回归。
///
/// 事故：产物只按文件名落位。`sub1/a.mp4` 与 `sub2/a.mp4` 都会被写到输出根目录
/// 的 `a.mp4` —— **后一个直接覆盖前一个**；就地覆盖模式下还会在根目录多出一份、
/// 原文件却没被替换。目录层级必须跟着输入走。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mp4fix-subdir');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('relativeDirOf', () {
    test('取出相对目录（/ 与 \\ 都认）', () {
      expect(relativeDirOf('a.mp4'), '');
      expect(relativeDirOf('sub/a.mp4'), 'sub');
      expect(relativeDirOf('sub/dir/a.mp4'), 'sub/dir');
      expect(relativeDirOf(r'sub\dir\a.mp4'), 'sub/dir');
      expect(relativeDirOf('/sub/a.mp4'), 'sub');
    });

    test('过滤 . / ..（WebDAV 外部路径不能越界）', () {
      expect(relativeDirOf('../a.mp4'), '');
      expect(relativeDirOf('sub/../../a.mp4'), 'sub');
      expect(relativeDirOf('sub/./a.mp4'), 'sub');
    });
  });

  group('DirectoryOutputTarget 带子目录', () {
    test('自动建多级目录，返回完整路径', () async {
      final out = Directory('${tmp.path}/out');
      final src = File('${tmp.path}/src')..writeAsStringSync('x');

      final saved = await DirectoryOutputTarget(out)
          .save(src, 'a.mp4', subDir: 'sub/dir');

      expect(saved, '${out.path}/sub/dir/a.mp4');
      expect(File(saved).readAsStringSync(), 'x');
    });

    test('不同子目录里的同名文件不会互相覆盖', () async {
      final out = Directory('${tmp.path}/out');
      final target = DirectoryOutputTarget(out);

      final s1 = File('${tmp.path}/s1')..writeAsStringSync('one');
      final s2 = File('${tmp.path}/s2')..writeAsStringSync('two');

      await target.save(s1, 'a.mp4', subDir: 'sub1');
      await target.save(s2, 'a.mp4', subDir: 'sub2');

      expect(File('${out.path}/sub1/a.mp4').readAsStringSync(), 'one');
      expect(File('${out.path}/sub2/a.mp4').readAsStringSync(), 'two');
      expect(
        File('${out.path}/a.mp4').existsSync(),
        isFalse,
        reason: '不能把子目录里的文件平铺到根目录',
      );
    });
  });

  test('修复记录里的产物路径带子目录 → 复用能查到', () {
    final out = Directory('${tmp.path}/out');
    Directory('${out.path}/sub').createSync(recursive: true);
    File('${out.path}/sub/a.mp4').writeAsStringSync('x');

    final rec = RepairRecord(
      key: ledgerKeyFile(name: 'a.mp4', size: 1, modifiedMs: 2, path: '/in/sub/a.mp4'),
      name: 'a.mp4',
      size: 1,
      modifiedMs: 2,
      out: 'sub/a.mp4',
      kind: 'dir',
      ref: out.path,
      mode: '文件夹批量',
      rule: 'original||_fixed',
      at: 1,
    );
    final product = File('${rec.ref}${Platform.pathSeparator}${rec.out}');
    expect(
      product.existsSync(),
      isTrue,
      reason: '记录里的 out 不带子目录时，复用永远找不到产物 → 每次都要重修',
    );
  });

  test('命名规则把不同源文件清洗成同名 → 自动加序号；重做也不覆盖另一个', () async {
    final root = Directory('${tmp.path}/collide-in')..createSync();
    final out = Directory('${tmp.path}/collide-out')..createSync();
    // Linux 上 `?` / `*` 是合法文件名字符；命名规则会把它清洗成同一个目标名。
    // 用两个不同的坏夹具，产物字节不同 —— 这样「重做时覆盖了另一个」能被测出来。
    File('test/fixtures/bad_interleave.mp4').copySync('${root.path}/a?.mp4');
    File('test/fixtures/bad_interleave_v1mdhd.mp4')
        .copySync('${root.path}/a*.mp4');

    final c = AppController();
    c.settings.scanInputDirPath = root.path;
    c.settings.outputDirPath = out.path;
    c.settings.nameMode = OutputNameMode.prefix;
    c.settings.namePrefix = 'p_';
    // 夹具的错位只有几十 KB；默认 4MB 阈值会判成「正常」，
    // 这样 redo 重新检测后不会进入修复步骤，测不到分配器。
    c.settings.thresholdMb = 0;
    c.settings.thresholdSeconds = 0;

    await c.scanFolder(fixAfterScan: false);
    expect(c.jobsOf(JobSource.folder), hasLength(2));

    await c.fixJobs(JobSource.folder, processAll: true);

    final jobs = c.jobsOf(JobSource.folder);
    final names = out
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(
      names,
      {'p_a.mp4', 'p_a_2.mp4'},
      reason: '两个源文件清洗后同名，后一个必须加序号而不是覆盖：$names',
    );
    expect(c.lastNotice, contains('修复完成 2 个'));

    // 单独重做拿到 `_2` 的那条：它必须继续用 `_2`，不能回头覆盖另一个。
    final second = jobs.firstWhere(
      (j) => j.outputPath?.endsWith('p_a_2.mp4') ?? false,
    );
    final firstPath = jobs
        .firstWhere((j) => !identical(j, second))
        .outputPath!;
    final secondPath = second.outputPath!;
    final firstBytes = File(firstPath).readAsBytesSync();

    await c.redoJob(second);

    expect(
      File(firstPath).readAsBytesSync(),
      firstBytes,
      reason: '重做 B 覆盖了 A 的产物 —— 分配器没有参考修复记录',
    );
    expect(second.outputPath, secondPath);
    expect(File(secondPath).existsSync(), isTrue);
  });

  test('端到端：扫描带子目录的文件夹 → 产物落在对应子目录', () async {
    final root = Directory('${tmp.path}/in')..createSync();
    Directory('${root.path}/sub1').createSync();
    Directory('${root.path}/sub2').createSync();
    for (final d in ['sub1', 'sub2']) {
      File('test/fixtures/bad_interleave.mp4')
          .copySync('${root.path}/$d/a.mp4');
    }
    final out = Directory('${tmp.path}/out')..createSync();

    final c = AppController();
    c.settings.scanInputDirPath = root.path;
    c.settings.outputDirPath = out.path;

    await c.scanFolder(fixAfterScan: false);
    expect(c.jobsOf(JobSource.folder), hasLength(2));
    expect(
      c.jobsOf(JobSource.folder).map((j) => j.relDir).toSet(),
      {'sub1', 'sub2'},
      reason: '扫描时就要记下每个文件的相对目录',
    );

    // 「全部处理」（连判定正常的也重排），确保两个文件都真的落位
    await c.fixJobs(JobSource.folder, processAll: true);

    expect(File('${out.path}/sub1/a.mp4').existsSync(), isTrue);
    expect(File('${out.path}/sub2/a.mp4').existsSync(), isTrue);
    expect(
      File('${out.path}/a.mp4').existsSync(),
      isFalse,
      reason: '根目录不该多出一份（那份会掩盖「覆盖了子目录同名文件」的问题）',
    );
    expect(c.lastNotice, contains('修复完成 2 个'));
  });
}
