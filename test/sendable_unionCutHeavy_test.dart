// ignore_for_file: file_names
// The @SendableShape round trip for the union cut entry (design 02): a
// RetainedLoad crosses an isolate boundary with every field intact, and a
// worker answers what the same call on this isolate answers.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/substrate_retention.dart';
import 'package:openstrap_edge/compute/union_cut_heavy.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'guards/support/sendability.dart';

const int _t0 = 1791100000;

RetainedLoad _load(int from, int n) => RetainedLoad(
      from: from,
      to: from + n - 1,
      rrFrom: null,
      revs: {from ~/ 900: 3},
      ownership: const {},
      multiOwner: false,
      generation: (wipeEpoch: 1, openCount: 2),
      cut: from,
      sub: Substrate(
        tsSec: [for (var i = 0; i < n; i++) from + i],
        hr: [for (var i = 0; i < n; i++) 60 + i % 7],
        rrTsMs: const [],
        rrMs: const [],
        ax: List<double>.filled(n, 0),
        ay: List<double>.filled(n, 0),
        az: List<double>.filled(n, 0),
        spo2Red: List<int>.filled(n, 0),
        spo2Ir: List<int>.filled(n, 0),
        skinTemp: List<int>.filled(n, 0),
        skinContact: List<int>.filled(n, 0),
        stepCount: List<int>.filled(n, 0),
        hrValid: List<int>.filled(n, 1),
        bandSleepState: List<int>.filled(n, 0),
      ),
      rrStart: Int32List(n),
      rrTsRaw: Float64List(0),
      meta: [BucketMeta(from ~/ 900, const ['whoop'], const ['d'], null)],
    );

Object? _shape(RetainedLoad? l) => l == null
    ? null
    : [l.from, l.to, l.cut, l.revs, l.generation, l.sub.toJson(), l.meta.map((m) => m.toWire()).toList()];

UnionCutInput _window() => UnionCutInput(
      kind: UnionCutKind.window,
      loads: [_load(_t0, 600)],
      ownership: const {},
      multiOwner: false,
      a: _t0 + 100,
      b: _t0 + 299,
    );

void main() {
  tearDown(WorkerInit.resetForTest);

  test('the input crosses an isolate boundary with every field intact',
      () async {
    await expectIsolateRoundTrip<UnionCutInput>(_window(),
        project: (i) => [i.kind.name, i.a, i.b, i.loads.map(_shape).toList()]);
  });

  test('a worker answers what the same call on this isolate answers', () async {
    final inp = _window();
    final here = unionCutHeavy(unionCutWorkerInputs, inp).loads.single;
    WorkerInit.resetForTest();
    final there = (await Isolate.run(
            () => unionCutHeavy(unionCutWorkerInputs, inp)))
        .loads
        .single;
    expect(here, isNotNull);
    expect(here!.samples, 200);
    expect(_shape(there).toString(), _shape(here).toString());
  });

  test('join of two tiling parts in a worker is one load', () async {
    final parts = [_load(_t0, 300), _load(_t0 + 300, 300)];
    final r = await runUnionCut(UnionCutInput(
      kind: UnionCutKind.join,
      loads: parts,
      ownership: const {},
      multiOwner: false,
      revs: const {1: 1},
      generation: (wipeEpoch: 1, openCount: 2),
    ));
    expect(r.loads.single!.samples, 600);
    expect(r.loads.single!.from, _t0);
    expect(r.loads.single!.to, _t0 + 599);
  });
}
