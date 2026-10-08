// PRV screen log export (design 04 "PRV diagnostics", item h): the verdict AND
// the evidence behind it for one day, as a log file through logFileName +
// saveLogFileResult (invariant 16), never the clipboard. Mirrors lib/ecg/
// ecg_export.dart: `key: value` lines, a value the stored day does not hold
// prints `not recorded`, never a guess.
//
// RED STUB: the types exist so the tests compile; the formatter and the export
// throw UnimplementedError. See test/prv_diagnostics/prv_export_test.dart for
// the line contract.

import '../util/log_file.dart';

/// The header block of a PRV log.
class PrvExportHeader {
  const PrvExportHeader({
    required this.appVersion,
    required this.analyticsPin,
    required this.protocolPin,
    required this.algoVersion,
    required this.exportedAt,
  });
  final String appVersion;
  final String analyticsPin;
  final String protocolPin;
  final int algoVersion;

  /// From the INJECTED clock, never DateTime.now() in the formatter.
  final DateTime exportedAt;
}

/// How the log leaves: a file name and its text. Null in production means
/// [saveLogFileResult] (the platform share sheet); a test hands in a fake.
typedef PrvLogSaver = Future<LogSaveResult> Function(
    String fileName, String text);

/// What a screen needs to export: the clock, the app version, the saver.
class PrvExportEnv {
  const PrvExportEnv({required this.appVersion, required this.now, this.save});
  final Future<String> Function() appVersion;
  final DateTime Function() now;
  final PrvLogSaver? save;
}

/// The log text for [day]. [sleep] is the stored `clinical.irregular` block (a
/// plain map), [screen24h] the stored `clinical.irregular_24h` envelope; either
/// may be null (the day holds none). One `screen: sleep` block and one
/// `screen: 24h` block, always both.
String formatPrvLog({
  required PrvExportHeader header,
  required String day,
  required Map<String, dynamic>? sleep,
  required Map<String, dynamic>? screen24h,
}) =>
    throw UnimplementedError('PRV diagnostics: red stub');

/// Formats and saves the log: file name `logFileName('prv', env.now())`, text
/// [formatPrvLog]. Never throws on a save failure (returns it).
Future<LogSaveResult> exportPrvLog({
  required PrvExportEnv env,
  required String analyticsPin,
  required String protocolPin,
  required int algoVersion,
  required String day,
  required Map<String, dynamic>? sleep,
  required Map<String, dynamic>? screen24h,
}) =>
    throw UnimplementedError('PRV diagnostics: red stub');
