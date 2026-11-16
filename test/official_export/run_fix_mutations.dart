// Disposable-sandbox probes for fix round 1. Always restore the source.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final checks = <Map<String, Object>>[];
  Future<void> mutate(
    String label,
    String path,
    String Function(String) change,
    String test,
    String name,
  ) async {
    final file = File(path);
    final original = await file.readAsString();
    final changed = change(original);
    if (changed == original) {
      throw StateError('Mutation does not match: $label');
    }
    try {
      await file.writeAsString(changed);
      final run = await Process.run('flutter', [
        'test',
        '--concurrency=1',
        '--reporter',
        'expanded',
        test,
        '--plain-name',
        name,
      ]);
      final output = '${run.stdout}\n${run.stderr}';
      await File('build/fix-mutation-$label.log').writeAsString(output);
      final killed =
          run.exitCode != 0 &&
          output.contains('Expected:') &&
          !output.contains('Compilation failed');
      checks.add({'mutation': label, 'killed': killed, 'exit': run.exitCode});
      if (!killed) {
        throw StateError('Mutation survived or did not compile: $label');
      }
    } finally {
      await file.writeAsString(original);
    }
  }

  await mutate(
    'unlisted-columns',
    'lib/data/official_export/mapper.dart',
    (s) {
      final start = s.indexOf('      if (omitted.isNotEmpty) {');
      final end = s.indexOf('      final unknown =', start);
      if (start < 0 || end < 0) {
        throw StateError('Missing column omission block');
      }
      return s.replaceRange(start, end, '');
    },
    'test/official_export/roundtrip_test.dart',
    'production exporter accounts for every imported table and produces official-parser fixtures',
  );
  await mutate(
    'unlisted-row',
    'lib/data/official_export/mapper.dart',
    (s) => s.replaceFirst(
      "skip('Unsupported activity kind or undecided proposal');",
      '',
    ),
    'test/official_export/roundtrip_test.dart',
    'production exporter accounts for every imported table and produces official-parser fixtures',
  );
  await mutate(
    'raw-skipped-list',
    'lib/ui2/profile/official_export_skips.dart',
    (s) => s.replaceFirst(
      '  final groups =',
      r'''  if (skipped.isNotEmpty) return [for (final s in skipped)
      '${s.table}: ${s.rows} rows ${s.identity}. ${s.reason}'];
  final groups =''',
    ),
    'test/official_export/screen_test.dart',
    'saved skipped items group a real rich export report',
  );
  await mutate(
    'empty-scores-cleared',
    'lib/data/official_export/mapper.dart',
    (s) => s.replaceFirst('if (cleared.isNotEmpty)', 'if (true)'),
    'test/official_export/export_test.dart',
    'workout without scores produces no scores-cleared omission',
  );
  await File(
    'build/fix-mutation-results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
  stdout.writeln(jsonEncode(checks));
}
