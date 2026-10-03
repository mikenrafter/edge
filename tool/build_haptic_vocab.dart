// Builds the haptic vocabulary from every transcribed probe log under
// docs/hardware/logs, prints what differs from HapticDeviceProfile.whoopMg and
// the Dart table of the result. Adding a log changes the table by this diff,
// which is then reviewed and pasted into lib/haptics/haptic_profile.dart.
//
//   nix develop -c dart run tool/build_haptic_vocab.dart [logs-dir]
//
// The single effect 14 stays at f ("14 is F, while 47 is FF"), as in the table.

import 'dart:io';

import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/vocab_builder.dart';

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? 'docs/hardware/logs' : args.first);
  if (!dir.existsSync()) {
    stderr.writeln('No such directory: ${dir.path}');
    exitCode = 2;
    return;
  }
  final files = [
    for (final f in dir.listSync())
      if (f is File && f.path.endsWith('.txt')) f,
  ]..sort((a, b) => a.path.compareTo(b.path));
  stdout.writeln('Logs: ${files.length}');
  for (final f in files) {
    stdout.writeln('  ${f.path}');
  }
  final built = buildProfileFromLogs(
    [for (final f in files) f.readAsStringSync()],
    base: HapticDeviceProfile.whoopMg,
    dynamicOverrides: const {'buzz14': PatternDynamic.f},
  );
  stdout.writeln('\nDifference from HapticDeviceProfile.whoopMg:');
  stdout.writeln(describeProfileDiff(HapticDeviceProfile.whoopMg, built));
  stdout.writeln('\nTable:');
  stdout.writeln(describeProfileAsDart(built));
}
