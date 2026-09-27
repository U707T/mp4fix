import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/output_target.dart';

/// 产物落位的数据安全回归（对应 code review 里发现的"就地覆盖可能毁掉原文件"）。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp4fix-out'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('同名覆盖：旧文件被替换、无 .bak 残留、源文件消失', () async {
    File('${dir.path}/a.mp4').writeAsStringSync('old');
    final src = File('${dir.path}/tmp-src')..writeAsStringSync('new-content');

    final name = await DirectoryOutputTarget(dir).save(src, 'a.mp4');

    expect(name, 'a.mp4');
    expect(File('${dir.path}/a.mp4').readAsStringSync(), 'new-content');
    expect(File('${dir.path}/a.mp4.mp4fix-bak').existsSync(), isFalse);
    expect(src.existsSync(), isFalse, reason: '临时文件应被移走而不是留下副本');
  });

  test('落位失败：旧文件被还原（不丢数据）', () async {
    File('${dir.path}/b.mp4').writeAsStringSync('precious');
    // 用目录冒充"源文件"：rename/copy 都必然失败
    final badSource = Directory('${dir.path}/bad-src')..createSync();

    await expectLater(
      DirectoryOutputTarget(dir).save(File(badSource.path), 'b.mp4'),
      throwsA(isA<FileSystemException>()),
    );

    expect(
      File('${dir.path}/b.mp4').readAsStringSync(),
      'precious',
      reason: '失败后必须还原旧文件',
    );
    expect(File('${dir.path}/b.mp4.mp4fix-bak').existsSync(), isFalse);
  });

  test('目标目录不存在时自动创建（含多级）', () async {
    final nested = Directory('${dir.path}/a/b/c');
    final src = File('${dir.path}/s')..writeAsStringSync('x');

    await DirectoryOutputTarget(nested).save(src, 'x.mp4');

    expect(nested.existsSync(), isTrue);
    expect(File('${nested.path}/x.mp4').readAsStringSync(), 'x');
  });
}
