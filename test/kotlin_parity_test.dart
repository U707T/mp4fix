import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 与 Kotlin 旧引擎（mp4fix v1.1.5）**逐字节对齐**的金标准回归测试。
///
/// `test/fixtures/golden/*.fixed.mp4` 是 Kotlin CLI
/// （`cli/build/install/cli/bin/cli`）对 `test/fixtures/*.mp4` 的修复产物。
/// Dart 引擎的输出必须与之完全相同 —— 任何算法漂移都会被这个测试拦截。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  File tempOut(String name) => File(
      '${Directory.systemTemp.path}/mp4fix-parity-${DateTime.now().microsecondsSinceEpoch}-$name');

  final cases = [
    'good.mp4',
    'bad_interleave.mp4',
    'bad_interleave_v1mdhd.mp4',
  ];

  for (final name in cases) {
    test('repair($name) 与 Kotlin 引擎输出逐字节一致', () {
      final out = tempOut(name);
      try {
        final input = FileSeekableInput(fixture(name));
        final sink = FileSyncSink(out.openSync(mode: FileMode.write));
        try {
          Mp4Repair.repair(input, sink);
        } finally {
          sink.close();
          input.close();
        }

        final golden = File('test/fixtures/golden/$name.fixed.mp4').readAsBytesSync();
        final actual = out.readAsBytesSync();

        expect(actual.length, golden.length, reason: '$name: 输出长度不一致');
        expect(actual, orderedEquals(golden), reason: '$name: 输出与 Kotlin 引擎不一致');
      } finally {
        if (out.existsSync()) out.deleteSync();
      }
    });
  }
}
