// P2.3 startup warm (design 02 step 2, section 4.5, "Startup warm").
//
// Not part of `main()` before `runApp`; scheduled after the first frame
// (`addPostFrameCallback`, then a short delay); fire-and-forget with a 3 s
// timeout; low priority; at most 6 payloads and 1 MB of source; skipped in
// headless and background processes. An already-resolved future does not render
// the first frame, so the tests do not claim first-frame behaviour.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/state/publish_gate.dart';

import '../support/dart_source.dart';
import 'support/p23_support.dart';

HomeWarmSet _set(int n) => HomeWarmSet(
  bundles: [for (var i = 0; i < n; i++) BundleSource.day(p23Day(i))],
  wakeDay: null,
  windowDays: const [],
);

class _WarmSteps implements StartupWarmSteps {
  _WarmSteps({required this.onWarm, required this.onResolve});

  final Future<WarmResult> Function(List<BundleSource>, int) onWarm;
  final Future<HomeWarmSet> Function() onResolve;

  @override
  Future<WarmResult> warm(List<BundleSource> sources, int maxSourceBytes) =>
      onWarm(sources, maxSourceBytes);

  @override
  Future<HomeWarmSet> resolve() => onResolve();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  group('StartupWarm (fake warm target)', () {
    late List<List<BundleSource>> warmed;
    late List<int> budgets;
    late int resolved;

    StartupWarm make({
      bool headless = false,
      int sources = 10,
      Future<WarmResult> Function(List<BundleSource>, int)? warm,
      Future<HomeWarmSet> Function()? resolve,
    }) => StartupWarm(
      headless: headless,
      steps: _WarmSteps(
        onResolve: resolve ?? () async {
          resolved++;
          return _set(sources);
        },
        onWarm: warm ?? (s, b) async {
          warmed.add(s);
          budgets.add(b);
          return WarmDone(s.length);
        },
      ),
    );

    setUp(() {
      warmed = [];
      budgets = [];
      resolved = 0;
    });

    test('a headless or background process does nothing: no resolve, no warm',
        () {
      fakeAsync((async) {
        WarmResult? out = const WarmDone(-1);
        make(headless: true).run().then((r) => out = r);
        async.flushMicrotasks();

        expect(out, isNull);
        expect(resolved, 0);
        expect(warmed, isEmpty);
      });
    });

    test('at most 6 payloads, in the order given, with a 1 MB source budget',
        () {
      fakeAsync((async) {
        WarmResult? out;
        make(sources: 10).run().then((r) => out = r);
        async.flushMicrotasks();

        expect(warmed, hasLength(1), reason: 'one request');
        expect(warmed.single.map((s) => s.k1), [for (var i = 0; i < 6; i++) p23Day(i)]);
        expect(budgets.single, 1024 * 1024);
        expect(out, isA<WarmDone>());
      });
    });

    test('fewer than 6 candidates are all warmed; nothing to warm is a skip '
        'without a warm call', () {
      fakeAsync((async) {
        make(sources: 2).run();
        async.flushMicrotasks();
        expect(warmed.single, hasLength(2));

        warmed.clear();
        WarmResult? out = const WarmDone(-1);
        make(sources: 0).run().then((r) => out = r);
        async.flushMicrotasks();
        expect(out, isNull);
        expect(warmed, isEmpty);
      });
    });

    test('a warm that does not finish is cut at 3 s: run() answers null then, '
        'not before', () {
      fakeAsync((async) {
        final never = Completer<WarmResult>();
        var done = false;
        WarmResult? out = const WarmDone(-1);
        make(warm: (s, b) => never.future).run().then((r) {
          out = r;
          done = true;
        });
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 2999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 2));
        expect(done, isTrue);
        expect(out, isNull);
      });
    });

    test('a warm or a resolve that throws never throws out of run()', () {
      fakeAsync((async) {
        Object? error;
        WarmResult? out = const WarmDone(-1);
        make(warm: (s, b) async => throw StateError('lane down'))
            .run()
            .then((r) => out = r, onError: (Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isNull);
        expect(out, isNull);

        out = const WarmDone(-1);
        make(resolve: () async => throw StateError('db down'))
            .run()
            .then((r) => out = r, onError: (Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isNull);
        expect(out, isNull);
      });
    });

    test('a refused warm (lane busy) comes back as it is, not as a failure',
        () {
      fakeAsync((async) {
        WarmResult? out;
        make(warm: (s, b) async => const WarmRefusedBusy()).run().then((r) => out = r);
        async.flushMicrotasks();

        expect(out, isA<WarmRefusedBusy>());
      });
    });
  });

  group('BundleStore.warm honours a source-byte cap', () {
    const name = 'p23_startup_warm.db';
    late Database db;
    late P22Lane lane;
    late BundleStore store;
    setUp(() async {
      db = await p21Fresh(name);
      lane = P22Lane();
      store = p22Store(lane);
    });
    tearDown(() => p21Drop(name));

    String padded(String tag, int bytes) => '{"tag":"$tag","pad":"${'x' * bytes}"}';

    test('sources are warmed in order while their text fits; the rest are '
        'skipped, not refused', () async {
      for (var i = 0; i < 4; i++) {
        await p21RawDay(db, p23Day(i), version: p21Version, payload: padded('p$i', 400 * 1024));
      }

      final r = await store.warm(
        [for (var i = 0; i < 4; i++) BundleSource.day(p23Day(i))],
        maxSourceBytes: 1024 * 1024,
      );

      expect(r, isA<WarmDone>());
      expect((r as WarmDone).decoded, 2, reason: '2 x 400 KB fits in 1 MB, a third does not');
      expect(lane.payloads, 2);
      expect(store.debugCachedKeys.map((k) => k.k1), [p23Day(0), p23Day(1)]);
    });

    test('without a cap nothing changes: all four are warmed', () async {
      for (var i = 0; i < 4; i++) {
        await p21RawDay(db, p23Day(i), version: p21Version, payload: padded('p$i', 400 * 1024));
      }

      final r = await store.warm([for (var i = 0; i < 4; i++) BundleSource.day(p23Day(i))]);

      expect((r as WarmDone).decoded, 4);
    });
  });

  group('where it is scheduled', () {
    test('main() does not warm before runApp', () {
      final code = stripCommentsAndStrings(File('lib/main.dart').readAsStringSync());
      final runApp = code.indexOf('runApp(');
      expect(runApp, greaterThan(0));

      expect(code.substring(0, runApp), isNot(contains('StartupWarm')));
      expect(code.substring(0, runApp), isNot(contains('HomeWarmSet')));
    });

    test('the warm is scheduled from a post-frame callback', () {
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final code = stripCommentsAndStrings(f.readAsStringSync());
        if (code.contains('StartupWarm(')) hits.add(f.path);
      }
      final scheduling = hits.where((p) => !p.endsWith('publish_gate.dart')).toList();

      expect(scheduling, isNotEmpty, reason: 'nothing starts the startup warm');
      for (final p in scheduling) {
        final code = stripCommentsAndStrings(File(p).readAsStringSync());
        expect(code, contains('addPostFrameCallback'), reason: p);
      }
    });

    test('headless and background entry points never start it', () {
      for (final dir in const ['lib/sync', 'lib/background', 'lib/widget']) {
        if (!Directory(dir).existsSync()) continue;
        for (final f in Directory(dir).listSync(recursive: true)) {
          if (f is! File || !f.path.endsWith('.dart')) continue;
          expect(stripCommentsAndStrings(f.readAsStringSync()), isNot(contains('StartupWarm')),
              reason: f.path);
        }
      }
    });
  });
}
