// PRV screen log export (design 04 "PRV diagnostics", item h): the verdict AND
// the evidence behind it for one day, as a log file through logFileName +
// saveLogFileResult (invariant 16), never the clipboard. Mirrors lib/ecg/
// ecg_export.dart: `key: value` lines, a value the stored day does not hold
// prints `not recorded`, never a guess.
//
// See test/prv_diagnostics/prv_export_test.dart for the line contract.

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

const String _kNotRecorded = 'not recorded';

String _opt(Object? v) => v == null ? _kNotRecorded : '$v';

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// The verdict as the screens word it: a screen that did not run is "not
/// screened", never "not flagged".
String _flagWord(Object? flag) => flag == true
    ? 'flagged'
    : flag == false
        ? 'not flagged'
        : 'not screened';

/// The header block (one `key: value` per line) and the day.
String _header(PrvExportHeader h, String day) => 'OpenStrap PRV log\n'
    'app_version: ${h.appVersion}\n'
    'analytics_pin: ${h.analyticsPin}\n'
    'protocol_pin: ${h.protocolPin}\n'
    'algo_version: ${h.algoVersion}\n'
    'exported_at: ${h.exportedAt.toUtc().toIso8601String().replaceFirst('.000Z', 'Z')}\n'
    'day: $day\n';

/// One screen's block. [figures] are the verdict and figures as stored (the
/// sleep screen keeps them flat, the 24 h screen inside `value`); [diag] is the
/// stored `diagnostics`. A figure the screen never produced, or a day stored
/// before diagnostics existed, prints `not recorded`, never a 0.
String _block(
  String name, {
  required Object? flag,
  required Object? note,
  required Object? confidence,
  required Object? sd1,
  required Object? sd2,
  required Object? sd1sd2,
  required Object? pnn,
  required Object? nBeats,
  required Map<String, dynamic>? diag,
}) {
  final ran = flag != null;
  final beats = _map(diag?['beats']);
  final windows = _map(diag?['windows']);
  final th = _map(diag?['thresholds']);
  final b = StringBuffer()
    ..writeln('screen: $name')
    ..writeln('flag: ${_flagWord(flag)}')
    ..writeln('abstain: ${diag == null ? _kNotRecorded : _opt(diag['abstain'] ?? 'none')}')
    ..writeln('note: ${_opt(note)}')
    ..writeln('sd1_ms: ${_opt(sd1)}')
    ..writeln('sd2_ms: ${_opt(sd2)}')
    ..writeln('sd1_sd2: ${_opt(sd1sd2)}')
    ..writeln('pnn_pct: ${_opt(pnn)}')
    ..writeln('n_beats: ${_opt(nBeats)}')
    // The confidence of a screen that abstained is the Metric's forced 0, not a
    // measurement.
    ..writeln('confidence: ${ran ? _opt(confidence) : _kNotRecorded}')
    ..writeln('rr_raw: ${_opt(beats?['rr_raw'])}')
    ..writeln('nn_in: ${_opt(beats?['nn_in'])}')
    ..writeln('nn_kept: ${_opt(beats?['nn_kept'])}')
    ..writeln('corrected: ${_opt(beats?['corrected'])}')
    ..writeln('dropped: ${_opt(beats?['dropped'])}')
    ..writeln('artifact_fraction: ${_opt(beats?['artifact_fraction'])}')
    ..writeln('windows_total: ${_opt(windows?['total'])}')
    ..writeln('windows_valid: ${_opt(windows?['valid'])}')
    ..writeln('windows_flagged: ${_opt(windows?['flagged'])}')
    ..writeln('sustained_observed: ${_opt(windows?['sustained_observed'])}')
    ..writeln('sustained_required: ${_opt(th?['sustained_fraction'])}')
    ..writeln('open_window: ${_opt(windows?['open'])}')
    ..writeln('open_window_beats: ${_opt(windows?['open_beats'])}')
    ..writeln('min_beats: ${_opt(th?['min_beats'])}')
    ..writeln('max_artifact: ${_opt(th?['max_artifact'])}')
    ..writeln('sd1sd2_flag: ${_opt(th?['sd1sd2_flag'])}')
    ..writeln('pnn_threshold_ms: ${_opt(th?['pnn_threshold_ms'])}')
    ..writeln('pnn_flag_pct: ${_opt(th?['pnn_flag_pct'])}')
    ..writeln('window_minutes: ${_opt(th?['window_minutes'])}')
    ..writeln('min_window_beats: ${_opt(th?['min_window_beats'])}');
  return b.toString();
}

/// The log text for [day]. [sleep] is the stored `clinical.irregular` block (a
/// plain map), [screen24h] the stored `clinical.irregular_24h` envelope; either
/// may be null (the day holds none). One `screen: sleep` block and one
/// `screen: 24h` block, always both. Pure: the time is the header's.
String formatPrvLog({
  required PrvExportHeader header,
  required String day,
  required Map<String, dynamic>? sleep,
  required Map<String, dynamic>? screen24h,
}) {
  final value = _map(screen24h?['value']);
  final out = StringBuffer(_header(header, day))
    ..writeln()
    ..write(_block(
      'sleep',
      flag: sleep?['flag'],
      note: sleep?['note'],
      confidence: sleep?['confidence'],
      sd1: sleep?['sd1'],
      sd2: sleep?['sd2'],
      sd1sd2: sleep?['sd1_sd2'],
      pnn: sleep?['pnn_pct'],
      nBeats: sleep?['n_beats'],
      diag: _map(sleep?['diagnostics']),
    ))
    ..writeln()
    ..write(_block(
      '24h',
      flag: value?['flag'],
      note: screen24h?['note'],
      confidence: screen24h?['confidence'],
      sd1: value?['sd1_ms'],
      sd2: value?['sd2_ms'],
      sd1sd2: value?['sd1_sd2'],
      pnn: value?['pnn_pct'],
      nBeats: value?['n_beats'],
      diag: _map(screen24h?['diagnostics']),
    ));
  return out.toString();
}

/// Formats and saves the log: file name `logFileName('prv', env.now())`, text
/// [formatPrvLog]. Never throws: a failure, in the app-version lookup, the
/// formatter or the saver, comes back as [LogSaveFailed] carrying its text.
Future<LogSaveResult> exportPrvLog({
  required PrvExportEnv env,
  required String analyticsPin,
  required String protocolPin,
  required int algoVersion,
  required String day,
  required Map<String, dynamic>? sleep,
  required Map<String, dynamic>? screen24h,
}) async {
  try {
    final at = env.now();
    final text = formatPrvLog(
      header: PrvExportHeader(
        appVersion: await env.appVersion(),
        analyticsPin: analyticsPin,
        protocolPin: protocolPin,
        algoVersion: algoVersion,
        exportedAt: at,
      ),
      day: day,
      sleep: sleep,
      screen24h: screen24h,
    );
    final save = env.save ?? ((name, t) => saveLogFileResult(name, t));
    return await save(logFileName('prv', at), text);
  } catch (e) {
    return LogSaveFailed('$e');
  }
}
