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
/// never a throw, when the write or the share failed.
Future<bool> saveLogFile(
  String fileName,
  String text, {
  Rect? origin,
  Directory? dir,
  Future<void> Function(String path)? share,
}) async {
  try {
    final d = dir ?? await getTemporaryDirectory();
    final file = File('${d.path}/$fileName');
    await file.writeAsString(text, flush: true);
    await (share ??
        (p) => Share.shareXFiles(
              [XFile(p, mimeType: 'text/plain')],
              subject: 'OpenStrap log',
              sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
            ))(file.path);
    return true;
  } catch (_) {
    return false;
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
