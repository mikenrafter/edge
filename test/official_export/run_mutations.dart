// Disposable-sandbox runner. Each mutation is restored even on failure.
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
    final file = File(path), original = await File(path).readAsString();
    final mutated = change(original);
    if (mutated == original) {
      throw StateError('Mutation no longer matches: $label');
    }
    try {
      await file.writeAsString(mutated);
      final run = await Process.run('flutter', [
        'test',
        '--concurrency=1',
        test,
        '--plain-name',
        name,
      ]);
      final output = '${run.stdout}\n${run.stderr}';
      await File('build/mutation-$label.log').writeAsString(output);
      final killed = run.exitCode != 0 && output.contains('Expected:');
      checks.add({'mutation': label, 'exit': run.exitCode, 'killed': killed});
      if (!killed) {
        throw StateError('Mutation survived or failed to compile: $label');
      }
    } finally {
      await file.writeAsString(original);
    }
  }

  await mutate(
    'copy-fork-results',
    'assets/official_export/v0.11.3.json',
    (s) => s.replaceFirst('"day_result": "empty"', '"day_result": "keep"'),
    'test/official_export/export_test.dart',
    'preserves journal and raw, skips unknowns with reasons, empties results',
  );
  await mutate(
    'restore-obsolete-beats',
    'lib/data/official_export/mapper.dart',
    (s) => s.replaceFirst(
      "if (liveSeconds.contains(measured['ts_ms'])) {",
      r'''if (liveSeconds.contains(measured['ts_ms'])) {
        for (final beat in bucket.beats[measured['ts_ms']] ?? const <Map<String, Object?>>[]) {
          await txn.insert('decoded_rr', beat, conflictAlgorithm: ConflictAlgorithm.replace);
        }''',
    ),
    'test/official_export/archive_test.dart',
    'exact archive expands; a live parent with no beats never regains old beats',
  );
  await mutate(
    'trust-private-file',
    'lib/data/official_export/coordinator.dart',
    (s) => s
        .replaceFirst(
          'final read = await destination.readBack(',
          'final read = await trustPrivateFile(',
        )
        .replaceFirst(
          'final published = await destination.readBack(',
          'final published = await trustPrivateFile(',
        )
        .replaceFirst(
          '      Future<String> save(',
          r'''      Future<File> trustPrivateFile(String handle,File dest) =>
          File('${session!.path}/sealed.osbk').copy(dest.path);
      Future<String> save(''',
        ),
    'test/official_export/coordinator_test.dart',
    'provider corruption fails and removes output and plaintext',
  );
  await File(
    'build/official-mutation-results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
  stdout.writeln(jsonEncode(checks));
}
