import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/common/parallel.dart';

/// 并行底座的行为约束：并行度有上限、任务不丢、单个失败不拖垮整批。
///
/// 这三条是三条流水线（本地检测 / 本地修复 / WebDAV）共享的语义 ——
/// 任何一条破了，表现都是「扫描少文件 / 批量提前结束 / 界面卡住」。
void main() {
  test('forEachBounded：最多 N 个同时跑，且按顺序启动、一个不落', () async {
    var active = 0;
    var maxActive = 0;
    final started = <int>[];

    await forEachBounded(List<int>.generate(24, (i) => i), 4, (item, _) async {
      active++;
      if (active > maxActive) maxActive = active;
      started.add(item);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
    });

    expect(maxActive, 4, reason: '并行度必须被限制在 4');
    expect(started, List<int>.generate(24, (i) => i), reason: '启动顺序应与列表一致');
  });

  test('forEachBounded：并发数大于任务数时不报错', () async {
    final done = <int>[];
    await forEachBounded([1, 2], 8, (item, _) async => done.add(item));
    expect(done, [1, 2]);
  });

  test('forEachBounded：取消后不再启动新任务', () async {
    var started = 0;
    await forEachBounded(
      List<int>.generate(100, (i) => i),
      4,
      (item, _) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      },
      isCancelled: () => started >= 6,
    );

    expect(started, greaterThanOrEqualTo(6), reason: '取消前已启动的任务要跑完');
    expect(started, lessThan(20), reason: '取消后应尽快停下，不能把 100 个全跑一遍');
  });

  test('forEachBounded：单个任务失败不中断整批，最后抛出第一个错误', () async {
    var ran = 0;
    await expectLater(
      forEachBounded([1, 2, 3, 4], 2, (item, _) async {
        ran++;
        if (item == 2) throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(ran, 4, reason: '一个坏文件不该让整批停下');
  });

  test('ParallelWindow：边发现边投递时同样限制在 N 个', () async {
    final window = ParallelWindow(3);
    var active = 0;
    var maxActive = 0;

    for (var i = 0; i < 12; i++) {
      await window.submit(() async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 4));
        active--;
      });
    }
    await window.drain();

    expect(maxActive, 3, reason: '窗口不能超过 limit');
    expect(window.activeCount, 0, reason: 'drain 之后不应残留任务');
  });

  test('ParallelWindow：limit < 1 时按 1 处理（等价串行）', () async {
    final window = ParallelWindow(0);
    var active = 0;
    var maxActive = 0;
    for (var i = 0; i < 3; i++) {
      await window.submit(() async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
      });
    }
    await window.drain();
    expect(maxActive, 1);
  });

  test('TaskPool：任务可以继续投递子任务，idle 会等到全部结束', () async {
    final pool = TaskPool(3);
    var active = 0;
    var maxActive = 0;
    var ran = 0;

    void submitTree(int depth) {
      pool.add(() async {
        ran++;
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (depth > 0) {
          submitTree(depth - 1);
          submitTree(depth - 1);
        }
        active--;
      });
    }

    submitTree(3); // 1 + 2 + 4 + 8 = 15 个任务
    await pool.idle();

    expect(ran, 15, reason: 'idle 必须等动态投递的子任务也跑完');
    expect(maxActive, lessThanOrEqualTo(3));
    expect(pool.isIdle, isTrue);
  });

  test('TaskPool：子任务抛错不中断其它任务，结束后抛出第一个错误', () async {
    final pool = TaskPool(2);
    final done = <int>[];
    for (var i = 0; i < 5; i++) {
      pool.add(() async {
        if (i == 2) throw StateError('boom');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        done.add(i);
      });
    }
    await expectLater(pool.idle(), throwsStateError);
    expect(done, [0, 1, 3, 4]);
  });

  test('Semaphore：最多 N 个同时执行，且能拿到返回值', () async {
    final gate = Semaphore(2);
    var active = 0;
    var maxActive = 0;
    final results = await Future.wait([
      for (var i = 0; i < 6; i++)
        gate.run(() async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 3));
          active--;
          return i * 10;
        }),
    ]);

    expect(maxActive, 2);
    expect(results, [0, 10, 20, 30, 40, 50]);
    expect(gate.available, 2);
  });

  test('Semaphore：任务抛错也会释放许可（不会永久卡死）', () async {
    final gate = Semaphore(1);
    await expectLater(
      gate.run(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(gate.available, 1);
    expect(await gate.run(() async => 42), 42);
  });

  test('WeightedSemaphore：按权重占用容量，峰值不超过总容量', () async {
    final gate = WeightedSemaphore(4);
    var used = 0;
    var maxUsed = 0;

    Future<void> job(int weight) => gate.run(weight, () async {
          used += weight;
          if (used > maxUsed) maxUsed = used;
          await Future<void>.delayed(const Duration(milliseconds: 3));
          used -= weight;
        });

    await Future.wait([job(3), job(1), job(2), job(1)]);

    expect(maxUsed, 4, reason: '3+1 可同时跑；2+1 要等前两个释放');
    expect(gate.available, 4, reason: '全部结束后容量应归还');
  });

  test('WeightedSemaphore：单个任务权重超过容量时独占，异常也释放', () async {
    final gate = WeightedSemaphore(2);
    var active = 0;

    await expectLater(
      gate.run(99, () async {
        active++;
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(active, 1);
    expect(gate.available, 2, reason: '权重被夹到容量，结束后必须归还');
  });
}
