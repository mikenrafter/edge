// Phase 4 red: integration guard for contract 6. Labelled as a SOURCE GUARD,
// not runtime proof: it checks that the new read seams stay free of analytics
// entry points and reuse the existing winner logic. Runtime behavior is
// covered by resolved_data_test.dart.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/sources_support.dart';

const _required = [
  'lib/sources/source_catalog.dart',
  'lib/sources/resolved_data.dart',
  'lib/ui2/sources/source_catalog_view.dart',
  'lib/ui2/sources/resolved_data_view.dart',
  'lib/ui2/sources/source_priority_view.dart',
];

final _import = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

Iterable<File> _dartIn(String dir) => Directory(dir).existsSync()
    ? Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))
    : const [];

void main() {
  test('source guard: every Phase 4 read-seam file exists', () {
    final missing = [for (final f in _required) if (!File(f).existsSync()) f];
    expect(missing, isEmpty,
        reason: 'Missing production files named in $kContractDoc');
  });

  test('source guard: read seams import no analytics or compute entry points',
      () {
    final files = [..._dartIn('lib/sources'), ..._dartIn('lib/ui2/sources')];
    expect(files, isNotEmpty,
        reason: 'lib/sources and lib/ui2/sources must exist ($kContractDoc)');
    final offenders = <String>[];
    for (final f in files) {
      for (final m in _import.allMatches(f.readAsStringSync())) {
        final target = m.group(1)!;
        if (target.contains('compute/') ||
            target.contains('openstrap_analytics') ||
            target.contains('derivation_engine') ||
            target.contains('onehz_pipeline') ||
            target.contains('crossday_pipeline') ||
            target.contains('substrate.dart')) {
          offenders.add('${f.path} -> $target');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'read paths must not reach analytics computation');
  });

  test('source guard: the catalog reuses signalWinners and HealthSource', () {
    final f = File('lib/sources/source_catalog.dart');
    expect(f.existsSync(), isTrue,
        reason: 'lib/sources/source_catalog.dart is named in $kContractDoc');
    final source = f.readAsStringSync();
    expect(source, contains('signalWinners('),
        reason: 'current-use reasons extend the existing winner resolution');
    expect(source, isNot(contains('class HealthSource')),
        reason: 'one source type, not a parallel one');
    for (final file in _dartIn('lib/sources')) {
      expect(file.readAsStringSync(), isNot(contains('class HealthSource')));
    }
  });
}
