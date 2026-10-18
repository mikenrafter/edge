// log_file.dart — "Save log file" for every screen that used to copy a log.
// A big log pasted from the clipboard locked up a second device, so a
// log leaves the phone as a .txt handed to the platform share sheet, the way
// the app's other exports do. Never the clipboard.

import 'dart:io';

import 'package:flutter/painting.dart' show Rect;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// How a screen saves a log; injectable so widgets are tested with a fake.
typedef LogFileSaver = Future<bool> Function(String fileName, String text);

/// How a screen saves a log that arrives in pieces (an export too large to hold
/// as one string) and must say WHY a save failed (design 04 R7''); injectable
/// so widgets are tested with a fake.
typedef LogChunkSaver = Future<LogSaveResult> Function(
    String fileName, Stream<String> chunks);

/// The outcome of [saveLogFileResult]: written and shared, or failed with a
/// reason a person can read.
sealed class LogSaveResult {
  const LogSaveResult();
}

class LogSaveOk extends LogSaveResult {
  const LogSaveOk();
}

class LogSaveFailed extends LogSaveResult {
  const LogSaveFailed(this.reason);
  final String reason;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// `openstrap-device-lab-log-20261004-120731.txt`: the kind and [at] in local
/// time, no spaces, colons or separators. [ext] is the file extension (a ZIP
/// export is `zip`).
String logFileName(String kind, DateTime at, {String ext = 'txt'}) {
  final t = at.toLocal();
  return 'openstrap-$kind-log-'
      '${t.year}${_two(t.month)}${_two(t.day)}-'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}.$ext';
}

/// Write [text] verbatim to `<dir>/<fileName>` (default the temporary
/// directory) and hand the path to [share] (default the platform share sheet,
/// anchored at [origin] for the iPad popover). True when both worked; false,
/// never a throw, when the write or the share failed. A thin wrapper over
/// [saveLogFileResult], for the callers that do not show why.
Future<bool> saveLogFile(
  String fileName,
  String text, {
  Rect? origin,
  Directory? dir,
  Future<void> Function(String path)? share,
}) async {
  final r = await saveLogFileResult(
    fileName,
    text,
    origin: origin,
    dir: dir,
    share: share,
  );
  return r is LogSaveOk;
}

/// [saveLogFile] with a reason (design 04 R7''): [text] as the one chunk of
/// [saveLogChunksResult], which is the one write path. Never a throw.
Future<LogSaveResult> saveLogFileResult(
  String fileName,
  String text, {
  Rect? origin,
  Directory? dir,
  Future<void> Function(String path)? share,
}) =>
    saveLogChunksResult(
      fileName,
      Stream<String>.value(text),
      origin: origin,
      dir: dir,
      share: share,
    );

/// The one write path: UTF-8 [chunks] appended to `<dir>/<fileName>` as each
/// arrives (the next is not asked for until the last is on disk, so memory
/// stays one chunk), then the path handed to [share]. Never a throw: a failure,
/// in the stream, the write or the share, returns [LogSaveFailed] carrying the
/// error's text, and a half-written file is deleted rather than shared.
Future<LogSaveResult> saveLogChunksResult(
  String fileName,
  Stream<String> chunks, {
  Rect? origin,
  Directory? dir,
  Future<void> Function(String path)? share,
}) async {
  File? file;
  try {
    final d = dir ?? await getTemporaryDirectory();
    final f = file = File('${d.path}/$fileName');
    final out = await f.open(mode: FileMode.write);
    try {
      await for (final c in chunks) {
        await out.writeString(c);
      }
      await out.flush();
    } finally {
      await out.close();
    }
  } catch (e) {
    try {
      // A stream or a write that failed leaves a partial log; it is not offered.
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
    return LogSaveFailed('$e');
  }
  try {
    await (share ??
        (p) => Share.shareXFiles(
              [XFile(p, mimeType: 'text/plain')],
              subject: 'OpenStrap log',
              sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
            ))(file.path);
    return const LogSaveOk();
  } catch (e) {
    return LogSaveFailed('$e');
  }
}

/// The MIME type of a lab recording (JSON Lines), for the share sheet.
const String kJsonFileMime = 'application/json';

/// Hand a copy of the file at [path] to [share] (default the platform share
/// sheet, anchored at [origin] for the iPad popover). The copy goes to [tempDir]
/// (default the temporary directory), so the share sheet never holds the saved
/// file itself (a file already there is shared as is). True when the share ran; false, never a throw, when the copy or
/// the share failed. The file at [path] is the same either way: a failed share
/// is not a failed save.
Future<bool> shareFileCopy(
  String path, {
  String mimeType = kJsonFileMime,
  String subject = 'OpenStrap recording',
  Rect? origin,
  Directory? tempDir,
  Future<void> Function(String path)? share,
}) async {
  try {
    final d = tempDir ?? await getTemporaryDirectory();
    final name = path.split(Platform.pathSeparator).last;
    final target = '${d.path}/$name';
    // A file already in [tempDir] is shared as is: copying it onto itself
    // truncates it to 0 bytes.
    final copy = File(path).absolute.path == File(target).absolute.path
        ? File(path)
        : await File(path).copy(target);
    await (share ??
        (p) => Share.shareXFiles(
              [XFile(p, mimeType: mimeType)],
              subject: subject,
              sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
            ))(copy.path);
    return true;
  } catch (_) {
    return false;
  }
}
