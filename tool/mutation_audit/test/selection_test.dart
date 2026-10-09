import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

List<Mutant> make(int n) => [
      for (var i = 0; i < n; i++)
        Mutant(
          id: 'lib/a.dart:$i:relational:00000000',
          file: 'lib/a.dart',
          line: i + 1,
          column: 1,
          byteOffset: i,
          byteLength: 1,
          operator: MutationOperator.relational,
          original: '<',
          mutated: '<=',
        ),
    ];

List<String> ids(List<Mutant> ms) => [for (final m in ms) m.id];

void main() {
  final all = make(40);

  test('no options keeps everything, in order', () {
    expect(ids(selectMutants(all)), ids(all));
  });

  test('maxMutants keeps the first ones', () {
    expect(ids(selectMutants(all, maxMutants: 5)), ids(all.take(5).toList()));
    expect(selectMutants(all, maxMutants: 500), hasLength(40));
    expect(selectMutants(all, maxMutants: 0), isEmpty);
  });

  test('a sample is a subset of the right size, in the original order', () {
    final s = selectMutants(all, sample: 10, seed: 7);
    expect(s, hasLength(10));
    expect({for (final m in s) m.id}, hasLength(10));
    final positions = [for (final m in s) all.indexWhere((x) => x.id == m.id)];
    expect(positions, everyElement(greaterThanOrEqualTo(0)));
    expect(positions, orderedEquals([...positions]..sort()));
  });

  test('the same seed gives the same sample, other seeds give other samples', () {
    expect(ids(selectMutants(all, sample: 10, seed: 7)), ids(selectMutants(all, sample: 10, seed: 7)));
    final distinct = {
      for (var seed = 1; seed <= 6; seed++) ids(selectMutants(all, sample: 10, seed: seed)).join(',')
    };
    expect(distinct.length, greaterThan(1));
  });

  test('every mutant can be drawn (the sample is not stuck on a corner)', () {
    final seen = <String>{};
    for (var seed = 0; seed < 60; seed++) {
      seen.addAll(ids(selectMutants(all, sample: 5, seed: seed)));
    }
    expect(seen.length, greaterThan(30));
  });

  test('asking for more than exist returns all of them', () {
    expect(ids(selectMutants(all, sample: 400, seed: 1)), ids(all));
  });

  test('a sample is capped by maxMutants afterwards, the first of the sample', () {
    final sample = selectMutants(all, sample: 12, seed: 3);
    expect(ids(selectMutants(all, sample: 12, seed: 3, maxMutants: 4)), ids(sample.take(4).toList()));
  });

  test('a sample needs a seed; negative numbers are refused', () {
    expect(() => selectMutants(all, sample: 5), throwsArgumentError);
    expect(() => selectMutants(all, sample: -1, seed: 1), throwsArgumentError);
    expect(() => selectMutants(all, maxMutants: -1), throwsArgumentError);
  });

  test('the input list is not changed', () {
    final before = ids(all);
    selectMutants(all, sample: 10, seed: 2, maxMutants: 3);
    expect(ids(all), before);
  });
}
