// Design 06 section 10: within a group max(cost) < 2 x min(cost), strict, and
// at most 3 members. Owner's examples.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';

void main() {
  test('[0.2, 0.39, 0.4] is invalid: 0.4 is not < 2 x 0.2', () {
    expect(costRuleProblems({'g': [0.2, 0.39, 0.4]}), isNotEmpty);
  });

  test('[0.2, 0.35, 0.38, 0.2, 0.1] is invalid (size and spread)', () {
    final p = costRuleProblems({
      'g': [0.2, 0.35, 0.38, 0.2, 0.1]
    });
    expect(p, isNotEmpty);
  });

  test('[0.2, 0.3, 0.35] is valid', () {
    expect(costRuleProblems({'g': [0.2, 0.3, 0.35]}), isEmpty);
  });

  test('a single member is valid', () {
    expect(costRuleProblems({'g': [3.0]}), isEmpty);
  });

  test('a group with no members is invalid', () {
    expect(costRuleProblems({'g': []}), isNotEmpty);
  });

  test('four members inside the spread are still invalid', () {
    expect(costRuleProblems({'g': [0.2, 0.2, 0.2, 0.2]}), isNotEmpty);
  });

  test('exactly 2x is invalid (strict)', () {
    expect(costRuleProblems({'g': [0.2, 0.4]}), isNotEmpty);
  });

  test('problems name the offending group; valid groups add none', () {
    final p = costRuleProblems({
      'good': [1.0, 1.5],
      'bad': [1.0, 2.5],
    });
    expect(p.length, 1);
    expect(p.single, contains('bad'));
  });
}
