import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/engine_tasks.dart';
import 'package:mp4fix/src/app/models.dart';

/// 桌面端目录列举与路径规范化的回归（Windows 上最常用到的两处）。
void main() {
  test('目录列举：只挑视频、跳过隐藏目录、相对路径正确', () {
    final root = Directory.systemTemp.createTempSync('mp4fix-scan');
    try {
      File('${root.path}/a.mp4').writeAsBytesSync([1, 2, 3]);
      File('${root.path}/b.txt').writeAsStringSync('x');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/c.M4V').writeAsBytesSync([1]);
      Directory('${root.path}/.hidden').createSync();
      File('${root.path}/.hidden/d.mp4').writeAsBytesSync([1]);

      final listing = listVideosSync(root.path);
      final names = listing.files
          .map((f) => f.rel.split(Platform.pathSeparator).last)
          .toList()
        ..sort();
      expect(names, ['a.mp4', 'c.M4V']);
      expect(listing.skipped, 0);
      expect(listing.files.firstWhere((f) => f.rel.endsWith('a.mp4')).size, 3);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('目录不存在：不抛异常，返回空结果', () {
    final listing = listVideosSync('/definitely/not/here/${DateTime.now().microsecondsSinceEpoch}');
    expect(listing.files, isEmpty);
  });

  test('路径规范化：去引号 / 去空白 / 去 file:// 前缀', () {
    expect(normalizePickedPath('  /tmp/mp4fix  '), '/tmp/mp4fix');
    expect(normalizePickedPath('"/tmp/mp4fix"'), '/tmp/mp4fix');
    expect(normalizePickedPath('file:///tmp/mp4fix'), isNot(contains('file:')));
    expect(normalizePickedPath('/tmp/正常路径'), '/tmp/正常路径');
  });
}
