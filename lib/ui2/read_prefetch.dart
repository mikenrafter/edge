// Owner: ReadPrefetch serializes optional cache warming. Each step is one
// stored read, never derive. Navigation or a visible read cancels the remaining
// steps. An already-issued SQLite read finishes; no following read is issued.
import 'dart:async';
import '../data/effect_work.dart';
export '../data/effect_work.dart';
import 'package:flutter/material.dart';
import 'skeleton/load_memory.dart';

class ReadPrefetch {
  ReadPrefetch({AsyncWork<void>? idle}) : _idle = idle ?? const _FrameIdle();
  static final shared = ReadPrefetch();
  static final routes = _PrefetchRoutes();
  static Future<void> schedulerIdle() {
    final idle = Completer<void>();
    final binding = WidgetsBinding.instance;
    void afterFrame(Duration _) {
      // A perpetual loading pulse must not create a zero-delay task loop.
      // Wait for visible animations to settle; issue at most one read after
      // each frame, with the visible/derive/navigation guards checked again.
      if (binding.transientCallbackCount > 0) {
        binding.addPostFrameCallback(afterFrame);
      } else {
        idle.complete();
      }
    }

    binding.addPostFrameCallback(afterFrame);
    binding.ensureVisualUpdate();
    return idle.future;
  }

  final AsyncWork<void> _idle;
  int _generation = 0, _visible = 0;
  void cancel() {
    _generation++;
  }

  void Function() visibleRead([String key = 'screen']) {
    cancel();
    _visible++;
    final elapsed = Stopwatch()..start();
    var released = false;
    return () {
      if (!released) {
        released = true;
        _visible--;
        elapsed.stop();
        LoadMemory.local.record(
          '$key:milliseconds',
          elapsed.elapsedMilliseconds.toDouble(),
        );
      }
    };
  }

  Future<void> warm(
    String key,
    List<AsyncWork<Object?>> reads, {
    required bool Function() busy,
  }) async {
    final generation = ++_generation;
    // Timing is a measured estimate used to order likely details, never a
    // progress percentage. Slow reads benefit first from warming their cache.
    final timer = Stopwatch()..start();
    for (final read in reads) {
      await _idle.run();
      if (generation != _generation || _visible > 0 || busy()) return;
      try {
        await read.run();
      } catch (_) {
        /* Optional warming cannot fail a screen. */
      }
    }
    timer.stop();
    LoadMemory.local.record(
      'prefetch:$key:milliseconds',
      timer.elapsedMilliseconds.toDouble(),
    );
  }
}

class _PrefetchRoutes extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      ReadPrefetch.shared.cancel();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      ReadPrefetch.shared.cancel();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      ReadPrefetch.shared.cancel();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      ReadPrefetch.shared.cancel();
}

final class _FrameIdle implements AsyncWork<void> {
  const _FrameIdle();
  @override
  Future<void> run() => ReadPrefetch.schedulerIdle();
}
