import 'dart:async';
import 'dart:collection';

/// 并行处理的两个小底座（本地检测 / 本地修复 / WebDAV 扫描与修复共用）。
///
/// 这些流水线原来都是「一个文件接一个文件」的 for 循环。真正耗时的部分
/// （读磁盘、等 SAF provider、HTTP 往返）大部分时间在**等**，串行执行等于
/// 让 CPU、磁盘和网络互相排队。这里只做「最多 N 个同时进行」，业务语义
/// （状态机、进度、取消、修复记录）仍留在原来的调用方。

/// 有界并发执行 [items] 中的任务。
///
/// - 按列表顺序**启动**（与 for 循环一致，便于进度 / 取消语义不变）；
/// - 单个任务抛异常不会中断其它任务，全部结束后抛出第一个异常 ——
///   批量处理里一个坏文件不该让整批停下；
/// - [isCancelled] 为真时不再启动新任务（已在跑的由任务自己检查取消标记）。
Future<void> forEachBounded<T>(
  Iterable<T> items,
  int concurrency,
  Future<void> Function(T item, int index) action, {
  bool Function()? isCancelled,
}) async {
  final list = items is List<T> ? items : items.toList(growable: false);
  if (list.isEmpty) return;
  final workers = concurrency < 1
      ? 1
      : (concurrency > list.length ? list.length : concurrency);
  var next = 0;
  Object? firstError;
  StackTrace? firstStack;

  Future<void> worker() async {
    while (true) {
      if (isCancelled?.call() ?? false) return;
      final index = next++;
      if (index >= list.length) return;
      try {
        await action(list[index], index);
      } catch (error, stack) {
        // 先记下第一个错误，继续把其它任务跑完
        firstError ??= error;
        firstStack ??= stack;
      }
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
}

/// 滑动窗口：任务是一个一个被发现的（扫描目录时），但同时在跑的不能超过
/// [limit] 个。
///
/// 用法：
/// ```dart
/// final window = ParallelWindow(4);
/// for (final file in discovered) {
///   await window.submit(() => inspect(file)); // 窗口满时等一个完成
/// }
/// await window.drain();
/// ```
///
/// 任务**必须自己处理异常**（扫描器的单个文件检测本来就是「失败也返回
/// ScanItem」）；这里不做吞异常，否则真正的 bug 会被藏起来。
class ParallelWindow {
  ParallelWindow(int limit) : limit = limit < 1 ? 1 : limit;

  /// 最多同时在跑的任务数。
  final int limit;

  final List<Future<void>> _active = [];

  /// 当前在跑的任务数（调试 / 测试用）。
  int get activeCount => _active.length;

  /// 投递一个任务；窗口已满时先等其中一个结束。
  Future<void> submit(Future<void> Function() task) async {
    while (_active.length >= limit) {
      await Future.any(_active);
    }
    late final Future<void> tracked;
    // whenComplete 里把自己移出窗口：已完成（成功 / 失败）的 Future 不能
    // 留在列表里，否则下一次 Future.any 会立刻返回同一个已完成项，窗口永远
    // 等不到真正的「新的」完成事件。
    tracked = task().whenComplete(() => _active.remove(tracked));
    _active.add(tracked);
  }

  /// 等所有已投递任务结束。
  Future<void> drain() async {
    while (_active.isNotEmpty) {
      await Future.wait(_active.toList(growable: false));
    }
  }
}

/// 动态任务池：任务可以继续投递子任务（例如目录遍历：列出一个目录后把
/// 子目录再投进来），**投递永不阻塞**。
///
/// 为什么不能用 [ParallelWindow] 做这件事：滑动窗口的「满」包含当前任务
/// 自己。N 个目录任务同时想投递子目录时，每个都在等「包括自己在内」的窗口
/// 腾位 —— 直接死锁。这里改用「队列 + 固定数量的消费者」，投递只是入队。
class TaskPool {
  TaskPool(int concurrency)
      : concurrency = concurrency < 1 ? 1 : concurrency;

  /// 最多同时在跑的任务数。
  final int concurrency;

  final Queue<Future<void> Function()> _pending = Queue();
  int _active = 0;
  Completer<void>? _idle;
  Object? _firstError;
  StackTrace? _firstStack;

  /// 当前是否已经没有任何任务（含待启动）。
  bool get isIdle => _pending.isEmpty && _active == 0;

  /// 投递一个任务；队列满 / 空都会立即返回。
  void add(Future<void> Function() task) {
    _pending.add(task);
    _pump();
  }

  void _pump() {
    while (_active < concurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      _active++;
      Future<void>.sync(task).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          // 不让一个坏任务中断其它任务；等全部结束再把第一个错误抛给调用方
          _firstError ??= error;
          _firstStack ??= stack;
        },
      ).whenComplete(() {
        _active--;
        _pump();
        if (isIdle) _completeIdle();
      });
    }
    if (isIdle) _completeIdle();
  }

  void _completeIdle() {
    final waiter = _idle;
    if (waiter == null) return;
    _idle = null;
    if (_firstError != null) {
      waiter.completeError(_firstError!, _firstStack);
    } else {
      waiter.complete();
    }
  }

  /// 等队列清空且所有任务结束；有任务失败时抛出第一个错误。
  Future<void> idle() {
    if (isIdle) {
      if (_firstError != null) {
        return Future<void>.error(_firstError!, _firstStack);
      }
      return Future<void>.value();
    }
    return (_idle ??= Completer<void>()).future;
  }
}
