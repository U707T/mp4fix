import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/engine_tasks.dart';
import 'package:mp4fix/src/engine/engine.dart';
import 'package:mp4fix/src/platform/android_platform.dart';
import 'package:mp4fix/src/webdav/prefetch.dart';

/// Android「只读预取」的平台通道协议测试：
/// 模拟 Kotlin 侧返回（盒头 + moov + 各 moof 的区间），验证 Dart 侧解析后
/// 可以直接完成检测；`not_seekable` 会转成 [SafNotSeekableException]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mp4fix/platform');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('prefetchForInspect：解析区间并完成检测（与本地检测一致）', () async {
    final bytes = File('test/fixtures/fragmented.mp4').readAsBytesSync();
    final ranges = _simulatePrefetch(bytes);
    mock((call) async {
      expect(call.method, 'prefetchForInspect');
      expect((call.arguments as Map)['uri'], 'content://test/frag.mp4');
      return {
        'size': bytes.length,
        'ranges': [
          for (final r in ranges) {'start': r.start, 'bytes': r.bytes},
        ],
      };
    });

    final pre =
        await AndroidPlatform.prefetchForInspect('content://test/frag.mp4');
    expect(pre.size, bytes.length);
    expect(pre.ranges, isNotEmpty);

    final input = PrefetchedSeekableInput(
      size: pre.size,
      ranges: [for (final r in pre.ranges) PrefetchRange(r.start, r.bytes)],
    );
    late final InspectReport report;
    try {
      report = Mp4Inspect.inspect(input, interleaveThresholdBytes: 20000);
    } finally {
      input.close();
    }
    expect(report.health, Mp4Health.needsReinterleave, reason: report.detail);
    expect(report.videoSamples, 120);
    expect(report.audioSamples, 189);
  });

  test('inspectPrefetchedInIsolate：在后台 Isolate 中检测预取数据', () async {
    final bytes = File('test/fixtures/fragmented.mp4').readAsBytesSync();
    final ranges = _simulatePrefetch(bytes);
    final report = await inspectPrefetchedInIsolate(
      bytes.length,
      ranges,
      thresholdBytes: 20000,
    );
    expect(report.health, Mp4Health.needsReinterleave, reason: report.detail);
    expect(report.videoSamples, 120);
    expect(report.audioSamples, 189);
  });

  test('readLastCrash：解析平台返回的崩溃记录', () async {
    mock((call) async {
      expect(call.method, 'readLastCrash');
      return {
        'text': 'android.app.RemoteServiceException: boom\n\tat a.b(c.java:1)',
        'time': 123456789,
      };
    });
    final crash = await AndroidPlatform.readLastCrash();
    expect(crash?.text, contains('boom'));
    expect(crash?.time, 123456789);
  });

  test('readLastCrash：没有记录返回 null（不打扰用户）', () async {
    mock((call) async => null);
    expect(await AndroidPlatform.readLastCrash(), isNull);
  });

  test('prefetchForInspect：not_seekable → SafNotSeekableException', () async {
    mock((call) async {
      throw PlatformException(code: 'not_seekable', message: 'pipe');
    });
    await expectLater(
      AndroidPlatform.prefetchForInspect('content://pipe'),
      throwsA(isA<SafNotSeekableException>()),
    );
  });

  test('prefetchForInspect：其他平台错误原样抛出', () async {
    mock((call) async {
      throw PlatformException(code: 'platform_error', message: '打开失败');
    });
    await expectLater(
      AndroidPlatform.prefetchForInspect('content://x'),
      throwsA(isA<PlatformException>()),
    );
  });
}

/// 与 Kotlin 侧相同思路的迷你实现（仅测试用）：盒头 + 整个 moov + 每个 moof。
List<({int start, Uint8List bytes})> _simulatePrefetch(Uint8List data) {
  final ranges = <({int start, Uint8List bytes})>[];
  var pos = 0;
  while (pos + 8 <= data.length) {
    var size = _u32(data, pos);
    var header = 8;
    final type = String.fromCharCodes(data, pos + 4, pos + 8);
    if (size == 1) {
      if (pos + 16 > data.length) break;
      size = _u64(data, pos + 8);
      header = 16;
    } else if (size == 0) {
      size = data.length - pos;
    }
    if (size < header || pos + size > data.length) break;
    ranges.add((
      start: pos,
      bytes: Uint8List.sublistView(
        data,
        pos,
        pos + (header < size ? header : size),
      ),
    ));
    if (type == 'moov' || type == 'moof') {
      if (size > header) {
        ranges.add((
          start: pos + header,
          bytes: Uint8List.sublistView(data, pos + header, pos + size),
        ));
      }
    }
    pos += size;
  }
  return ranges;
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _u64(Uint8List b, int o) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[o + i];
  }
  return v;
}
