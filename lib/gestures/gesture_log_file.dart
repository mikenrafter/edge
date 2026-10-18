// gesture_log_file.dart — "Save log file" for a failed gesture: the
// failure's session log as a .txt file, handed to the platform share sheet (the
// same way the app's other exports leave the phone). The log is the Device
// lab's own plain text, kept on the failure record at the time. Never the
// clipboard.

import 'dart:io';

import 'package:flutter/painting.dart' show Rect;

import '../util/log_file.dart';
import 'gesture_failures.dart';

/// How the Home card and the Settings list save a failure's log; injectable so
/// the widgets are tested with a fake.
typedef GestureLogSaver = Future<bool> Function(GestureFailure f);

String _two(int v) => v.toString().padLeft(2, '0');

/// `openstrap-gesture-failure-ecg-20261004-120731.txt`: the kind and the
/// failure's local time, no spaces, colons or separators.
String gestureLogFileName(GestureFailure f) {
  final t = f.at.toLocal();
  final kind = f.kind == GestureFailureKind.ecg ? 'ecg' : 'double-tap';
  return 'openstrap-gesture-failure-$kind-'
      '${t.year}${_two(t.month)}${_two(t.day)}-'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}.txt';
}

/// A short header saying what failed, then [GestureFailure.log] verbatim.
String gestureLogFileText(GestureFailure f) {
  final what = f.kind == GestureFailureKind.ecg
      ? 'An ECG gesture failed to activate'
      : 'A double-tap gesture failed to activate';
  return [
    'OpenStrap gesture failure',
    what,
    'Reason: ${f.reason}',
    'Gesture id: ${f.gestureId}',
    'Time: ${f.at.toLocal().toIso8601String()}',
    '',
    f.log,
  ].join('\n');
}

/// Write the failure's log to `<dir>/<file name>` (default the temporary
/// directory) and hand the path to [share] (default the platform share sheet,
/// anchored at [origin] for the iPad popover). True when both worked; false,
/// never a throw, when the write or the share failed.
Future<bool> saveGestureLog(
  GestureFailure f, {
  Directory? dir,
  Future<void> Function(String path)? share,
  Rect? origin,
}) =>
    saveLogFile(
      gestureLogFileName(f),
      gestureLogFileText(f),
      dir: dir,
      share: share,
      origin: origin,
    );
