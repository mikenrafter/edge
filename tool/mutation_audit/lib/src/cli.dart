import 'process_runner.dart';

/// Runs the whole tool: parse arguments, export the pinned commit, check the
/// dependency config, generate / select mutants, baseline, run, write the
/// results outside the export, dispose of the export. Returns the exit code:
/// 0 ran (whatever the mutants did), 64 usage error (usage on [err]), 65 the
/// baseline failed or a path override was refused, 70 internal / export error,
/// 130 interrupted.
Future<int> runCli(
  List<String> args, {
  ProcessRunner? runner,
  StringSink? out,
  StringSink? err,
  DateTime Function()? now,
}) =>
    throw UnimplementedError('runCli');
