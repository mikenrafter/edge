// Design 06 phase 1a: the registry contract and its validator.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/edge_groups.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/group_types.dart';

GroupDecl g(
  String id, {
  List<String> deps = const [],
  List<String>? members,
  List<String> api = const [],
  int counter = 1,
  GroupKind kind = GroupKind.algorithm,
}) =>
    GroupDecl(
        id: id,
        kind: kind,
        counter: counter,
        // One function belongs to one group, so the default member is unique.
        members: members ?? ['$id.fn'],
        api: api,
        deps: deps);

GroupRegistry reg(List<GroupDecl> gs) => GroupRegistry(1, gs);

// Stand-in for analytics' registry (arrives in 1b).
final analyticsDouble = <GroupDecl>[
  g('found.rr_correction', kind: GroupKind.foundation),
  g('found.calibration', kind: GroupKind.foundation), // day.checkpoint (an edge entry) reads it
  g('night.rhythm', deps: ['found.rr_correction']),
  g('readiness', deps: ['night.rhythm', 'found.rr_correction']),
  // edge.assembly depends on every group that writes into series / clinical /
  // scalars, so the double declares those ids too.
  g('sleep.stage', deps: ['found.rr_correction']),
  g('hrv.freq', deps: ['found.rr_correction']),
  g('day.blocks', deps: ['sleep.stage']),
  g('readiness.stress_illness', deps: ['night.rhythm', 'hrv.freq']),
  g('activity.load'),
  g('body.spo2_temp_coverage'),
];

void main() {
  test('a valid registry has no problems', () {
    expect(validateRegistry(reg(analyticsDouble)), isEmpty);
  });

  test('rejects a cycle', () {
    final p = validateRegistry(reg([
      g('a', deps: ['b']),
      g('b', deps: ['c']),
      g('c', deps: ['a']),
    ]));
    expect(p, isNotEmpty);
    expect(p.join('\n').toLowerCase(), contains('cycle'));
  });

  test('rejects a duplicate id', () {
    final p = validateRegistry(reg([g('a'), g('a')]));
    expect(p.join('\n').toLowerCase(), contains('duplicate'));
  });

  test('rejects a dangling dependency', () {
    final p = validateRegistry(reg([g('a', deps: ['nope'])]));
    expect(p.join('\n'), contains('nope'));
  });

  test('rejects more than 3 members', () {
    final p = validateRegistry(reg([g('a', members: ['1', '2', '3', '4'])]));
    expect(p.join('\n'), contains('a'));
    expect(p, isNotEmpty);
    expect(validateRegistry(reg([g('a', members: ['1', '2', '3'])])), isEmpty);
  });

  test('rejects a counter below 1', () {
    expect(validateRegistry(reg([g('a', counter: 0)])), isNotEmpty);
    expect(validateRegistry(reg([g('a', counter: -2)])), isNotEmpty);
  });

  test('transitiveDeps returns the closure, foundations included', () {
    final r = reg(analyticsDouble);
    expect(transitiveDeps(r, 'readiness'),
        {'night.rhythm', 'found.rr_correction'});
    expect(transitiveDeps(r, 'night.rhythm'), {'found.rr_correction'});
    expect(transitiveDeps(r, 'found.rr_correction'), isEmpty);
  });

  test('transitiveDeps follows a chain', () {
    final r = reg([
      g('a'),
      g('b', deps: ['a']),
      g('c', deps: ['b']),
      g('d', deps: ['c']),
    ]);
    expect(transitiveDeps(r, 'd'), {'a', 'b', 'c'});
  });

  test('analytics double merged with the edge entries validates', () {
    // The double stands in for analytics' registry, which since 1b replaces the
    // placeholders (they reuse its ids), so the placeholders are not merged.
    final merged = reg([
      ...analyticsDouble,
      ...kEdgeGroups,
    ]);
    expect(validateRegistry(merged), isEmpty);
  });

  test('an edge entry depending on an analytics id resolves when merged', () {
    final edge = g('edge.assembly',
        kind: GroupKind.edgeTransform, deps: ['readiness']);
    expect(validateRegistry(reg([...analyticsDouble, edge])), isEmpty);
    expect(validateRegistry(reg([edge])), isNotEmpty);
  });

  group('a function has exactly one owner', () {
    test('rejects one name as a member of two groups', () {
      final p = validateRegistry(
          reg([g('a', members: ['f']), g('b', members: ['f'])]));
      expect(p.join('\n'), allOf(contains('f'), contains('a'), contains('b')));
    });

    test('rejects a name that is one group\'s member and another\'s api', () {
      final p = validateRegistry(
          reg([g('a', members: ['f']), g('b', api: ['f'])]));
      expect(p, isNotEmpty);
    });

    test('rejects the same name in two groups\' api', () {
      final p = validateRegistry(reg([g('a', api: ['f']), g('b', api: ['f'])]));
      expect(p, isNotEmpty);
    });

    test('rejects a name in one group\'s members and api', () {
      final p = validateRegistry(reg([g('a', members: ['f'], api: ['f'])]));
      expect(p.join('\n'), contains('f'));
    });

    test('rejects a name listed twice in one list', () {
      expect(validateRegistry(reg([g('a', members: ['f', 'f'])])), isNotEmpty);
      expect(validateRegistry(reg([g('a', api: ['f', 'f'])])), isNotEmpty);
    });

    test('rejects an edge entry that re-claims an analytics function', () {
      final analytics = [g('night.rhythm', members: ['rsaRespRate'])];
      final edge = GroupDecl(
          id: 'edge.x',
          kind: GroupKind.edgeTransform,
          counter: 1,
          members: ['rsaRespRate']);
      final p = validateRegistry(reg([...analytics, edge]));
      expect(p.join('\n'), allOf(contains('rsaRespRate'), contains('edge.x')));
    });

    test('accepts distinct members and api across groups', () {
      expect(
          validateRegistry(reg([
            g('a', members: ['f'], api: ['f2']),
            g('b', members: ['h'], api: ['h2']),
          ])),
          isEmpty);
    });

    test('the real merged registry has no duplicate owners', () {
      expect(
          validateRegistry(kMergedRegistry)
              .where((e) => e.contains('owned by')),
          isEmpty);
    });
  });
}
