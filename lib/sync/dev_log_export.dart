// dev_log_export.dart — the dev log leaves the phone as one ZIP through the
// platform share sheet (never the clipboard), the way the other lab exports do.
//
// Contents: every dev log day file under `dev_log/`, the legacy
// `openstrap_sync.log(.1)` when an older install left them, and
// `wake_trace.json`, the recent rows of the wake decision trace (SQLite, so not
// otherwise in a file anybody can pull).

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../util/log_file.dart';
import '../wake/wake_orchestrator.dart';
import '../wake/wake_stores.dart';
import 'dev_log.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';

/// Write the export ZIP into [outDir] and return it. [wakeTrace] defaults to
/// the newest rows of the real trace store; a trace that cannot be read is
/// said so inside `wake_trace.json` instead of failing the logs' export.
Future<File> exportDevLogZip(
  DevLog log, {
  required Directory outDir,
  DateTime? now,
  Future<List<WakeTraceEntry>> Function()? wakeTrace,
}) async {
  await log.flush();
  final at = now ?? DateTime.now();
  final entries = <List<String>>[
    for (final f in await log.dayFiles())
      ['dev_log/${f.uri.pathSegments.last}', f.path],
    for (final f in await log.legacyFiles())
      [f.uri.pathSegments.last, f.path],
  ];
  String traceJson;
  try {
    final rows = await (wakeTrace ?? const DbWakeTraceStore().recent)();
    traceJson = const JsonEncoder.withIndent('  ').convert([
      for (final e in rows)
        {
          'wake_epoch': e.wakeEpochSec,
          'at_ms': e.atMs,
          'at': devLogTimestamp(DateTime.fromMillisecondsSinceEpoch(e.atMs)),
          'kind': e.kind,
          'data': e.data,
        },
    ]);
  } catch (e) {
    traceJson = jsonEncode({'error': 'wake trace unreadable: $e'});
  }
  // The share sheet only ever needs the latest export; earlier ones in the
  // cache dir are stale weight.
  try {
    await for (final f in outDir.list()) {
      final n = f.uri.pathSegments.last;
      if (f is File && n.startsWith('openstrap-dev-log-') && n.endsWith('.zip')) {
        await f.delete();
      }
    }
  } catch (_) {}
  final out = File('${outDir.path}/${logFileName('dev', at, ext: 'zip')}');
  await _zipOffIsolate(out.path, entries, traceJson);
  return out;
}

/// Export and hand the ZIP to the share flow. True when the share ran; false,
/// never a throw, when the export or the share failed. The ZIP is written into
/// [tempDir] (default the temporary directory), which is also where
/// [shareFileCopy] looks, so it shares that file as is and never copies it
/// onto itself.
Future<bool> shareDevLog(
  DevLog log, {
  Rect? origin,
  Directory? tempDir,
  DateTime? now,
  Future<List<WakeTraceEntry>> Function()? wakeTrace,
  Future<void> Function(String path)? share,
}) async {
  try {
    final d = tempDir ?? await getTemporaryDirectory();
    final zip = await exportDevLogZip(log,
        outDir: d, now: now, wakeTrace: wakeTrace);
    return await shareFileCopy(zip.path,
        mimeType: 'application/zip',
        subject: 'OpenStrap dev log',
        origin: origin,
        tempDir: d,
        share: share);
  } catch (_) {
    return false;
  }
}

// Reading and deflating up to the size cap is real work: off the UI isolate.
// Its own function so the closure captures only plain values.
Future<void> _zipOffIsolate(
        String outPath, List<List<String>> entries, String traceJson) =>
    Isolate.run(() => _writeZipHeavy(outPath, entries, traceJson));

@heavy
void _writeZipHeavy(String outPath, List<List<String>> entries, String traceJson) {
  WorkerAudit.entered('_writeZipHeavy');
  final a = Archive();
  for (final e in entries) {
    try {
      final bytes = File(e[1]).readAsBytesSync();
      a.addFile(ArchiveFile(e[0], bytes.length, bytes));
    } on FileSystemException {
      // deleted by a prune or a Clear between the listing and now
    }
  }
  final trace = utf8.encode(traceJson);
  a.addFile(ArchiveFile('wake_trace.json', trace.length, trace));
  File(outPath).writeAsBytesSync(ZipEncoder().encode(a), flush: true);
}
