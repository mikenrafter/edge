// M5 §0.2/§17: the baseline-dispersion-below-quantum guard in
// readiness_composite.dart is a genuine prerequisite for any cross-device
// masking of readiness's inputs, and it is ALREADY SHIPPED in the pinned
// analytics SHA (verified once, in the planning pass, via `git show`). This
// is the reachability proof that a future repin cannot silently drop it —
// the same defence derivation_engine.dart:916's comment already asks for by
// name, mirrored here as a runnable check rather than a one-off manual grep.
//
// Resolve the package actually used by this run, including local overrides.
// The pin guard must inspect that checkout, not silently skip a guessed path.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAnalyticsPin;

Directory analyticsCheckout() {
  final config = File('.dart_tool/package_config.json').absolute;
  final packages = (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final package = packages.cast<Map>().singleWhere(
      (p) => p['name'] == 'openstrap_analytics');
  return Directory.fromUri(config.uri.resolve(package['rootUri'] as String));
}

void main() {
  // why: an output bump citing both lines must actually pin both histories.
  // CLAIM(merged-analytics-pin): reviewed policies and fork HMM survive repins.
  test('analytics pin descends from reviewed main and retained fork', () async {
    for (final parent in const [
      'a438df40b38a4586a52a68ab7e1c100fca111ccd',
      'd876c427ce59eed95b5e54411e3b69253f294ae6',
      // Native bill cache supplies the compensated/canonical sums cited by 125.
      '6b2f68692aac27d3901be275bb8fab7e8fa4bd93',
    ]) {
      final result = await Process.run('git',
          ['merge-base', '--is-ancestor', parent, kAnalyticsPin],
          workingDirectory: analyticsCheckout().path);
      expect(result.exitCode, 0,
          reason: '$kAnalyticsPin must retain $parent: ${result.stderr}');
    }
  });
  test('kAnalyticsPin SHA contains the baseline-dispersion-below-quantum '
      'guard in readiness_composite.dart', () async {
    final analyticsRepo = analyticsCheckout();
    final result = await Process.run(
      'git',
      ['show', '$kAnalyticsPin:lib/src/onehz/wellness/readiness_composite.dart'],
      workingDirectory: analyticsRepo.path,
    );
    expect(result.exitCode, 0,
        reason: 'git show failed for $kAnalyticsPin — is the pin reachable '
            'in the sibling checkout? stderr: ${result.stderr}');
    expect(
      (result.stdout as String).contains('baseline_dispersion_below_quantum'),
      isTrue,
      reason: 'the pinned analytics SHA no longer contains the dispersion '
          'guard readiness_composite.dart needs before M5\'s masking can '
          'safely apply to readiness inputs — this is exactly the v43 '
          'mistake (a changelog citing a change the pin never had) '
          'happening in reverse: a repin silently DROPPING one',
    );
  });
}
