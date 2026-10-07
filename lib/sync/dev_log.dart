// dev_log.dart — the persistent, timestamped on-device log.
//
// Why it exists: the evidence for a failed alarm used to live in logcat, which
// is cleared on APK install, and in `openstrap_sync.log`, which had no times,
// interleaved lines from several isolates and could hold invalid UTF-8. This is
// the one log writer now ([DevLog.write]); the old FileLog is gone, and a
// leftover `openstrap_sync.log(.1)` from an older install is only ever read
// (exported) or cleared, never written.
//
// Where: `<external files dir>/dev_log/` on Android (survives an APK upgrade,
// `adb pull` needs no run-as), the app documents dir elsewhere. One file per
// LOCAL day, `dev-YYYY-MM-DD.log`; the last [kDevLogKeepDays] days are kept and
// [kDevLogMaxBytes] in total is the backstop.
//
// What: every line is `<local ISO time, ms, offset> [<source>] <text>`.
//   Alarm, wake and sync lines ([isAlwaysOnLogLine]) are ALWAYS written, since
//   they are the evidence for "why did my alarm not fire". Everything else is
//   written only while developer mode is on.
//
// Single writer semantics across isolates. Dart's FileMode.append is NOT
// O_APPEND: it opens the file and seeks to its end, so two isolates appending
// at once can pick the same offset and overwrite each other (measured: most of
// the lines of three concurrent writers were lost or torn). So an append is a
// short critical section behind a lock file (`dev_log/.append.lock`, created
// with the atomic exclusive-create, deleted after): inside it the record is ONE
// complete UTF-8 line written in ONE call. A lock older than [lockWait] belongs
// to a writer that died and is taken over. Inside one isolate the writes are
// also chained, so they land in call order. Text is sanitized first (control
// characters escaped, lone surrogates replaced) so a line is always valid UTF-8
// and exactly one line, and cut at [_maxLineRunes] so it stays a small write.
// No per-line fsync: the page cache survives a process crash, and only a power
// loss can drop the last few lines of a diagnostics log.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import '../state/prefs.dart';

/// Days of history kept: today and the six before it.
const int kDevLogKeepDays = 7;

/// Total bytes of day files kept on disk (a backstop; a week is far less).
const int kDevLogMaxBytes = 10 * 1024 * 1024;

/// The most characters one record keeps; the rest is dropped and counted.
const int _maxLineRunes = 2000;

String _two(int v) => v.toString().padLeft(2, '0');

/// `+HH:MM` / `-HH:MM`, so a line says which clock it was read on.
String devLogOffset(Duration d) {
  final m = d.inMinutes.abs();
  return '${d.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// Local ISO time to the millisecond with the UTC offset (a UTC instant is
/// converted to local first): `2026-10-06T07:05:09.004+02:00`.
String devLogTimestamp(DateTime at) {
  final t = at.toLocal();
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}${devLogOffset(t.timeZoneOffset)}';
}

/// One finished record, without the trailing newline. [text] must already be
/// [sanitizeDevLogText]ed.
String devLogLine(DateTime at, String source, String text) =>
    '${devLogTimestamp(at)} [$source] $text';

/// Make [s] exactly one line of valid UTF-8: newlines and control characters
/// become visible escapes, a lone surrogate (which would encode to invalid
/// UTF-8) becomes U+FFFD, and anything past [_maxLineRunes] is cut and counted.
String sanitizeDevLogText(String s) {
  final b = StringBuffer();
  var kept = 0, dropped = 0;
  for (final r in s.runes) {
    if (kept >= _maxLineRunes) {
      dropped++;
      continue;
    }
    kept++;
    if (r == 0x0A) {
      b.write(r'\n');
    } else if (r == 0x0D) {
      b.write(r'\r');
    } else if (r == 0x09) {
      b.write(' ');
    } else if (r < 0x20 || (r >= 0x7F && r <= 0x9F)) {
      b.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else if (r == 0x2028 || r == 0x2029) {
      b.write('\\u${r.toRadixString(16)}');
    } else if (r >= 0xD800 && r <= 0xDFFF) {
      b.write('�');
    } else {
      b.writeCharCode(r);
    }
  }
  if (dropped > 0) b.write('…[+$dropped]');
  return b.toString();
}

/// The leading `[tag]`s whose lines are the alarm / wake / sync evidence.
const Set<String> _alwaysOnTags = {
  'alarm',
  'wake',
  'smart-wake',
  'bgsync',
  'sync',
  'keepalive',
};

final RegExp _leadingTag = RegExp(r'^\s*\[([^\]]+)\]');

/// True for a line that is persisted even with developer mode off: a leading
/// alarm/wake/sync tag (any case: the engine logs `[SYNC]`), or any line that
/// mentions the alarm (the engine's `SET_ALARM_TIME` / arm accepted-rejected
/// lines carry no tag).
bool isAlwaysOnLogLine(String line) {
  final m = _leadingTag.firstMatch(line);
  if (m != null && _alwaysOnTags.contains(m.group(1)!.toLowerCase())) {
    return true;
  }
  return line.toLowerCase().contains('alarm');
}

/// `dev-2026-10-06.log`, named by the LOCAL day of [at] (never a UTC slice).
String devLogFileName(DateTime at) => 'dev-${dayLabelOf(at)}.log';

final RegExp _dayFile = RegExp(r'^dev-(\d{4}-\d{2}-\d{2})\.log$');

/// The day label a dev log file name carries, or null for any other name.
String? devLogDayOf(String fileName) => _dayFile.firstMatch(fileName)?.group(1);

/// The oldest day label still kept at [now]. Calendar arithmetic on the local
/// date, never `now - 6 * 24 h`: that lands a day early or late across a DST
/// change. Labels are ISO dates, so they compare as strings.
String devLogOldestKeptDay(DateTime now, {int keepDays = kDevLogKeepDays}) {
  final l = now.toLocal();
  return dayLabelOf(DateTime(l.year, l.month, l.day - (keepDays - 1)));
}

class DevLog {
  DevLog({
    required this.baseDir,
    DateTime Function()? now,
    Future<bool> Function()? devMode,
    this.source = 'ui',
    this.maxBytes = kDevLogMaxBytes,
    this.sizeCheckEvery = 64,
    this.lockWait = const Duration(seconds: 2),
  })  : _now = now ?? DateTime.now,
        _devMode = devMode ?? _prefsDevMode;

  /// The process-wide writer: external files dir (Android) or app documents.
  /// Replaced in tests.
  static DevLog instance = DevLog(baseDir: _platformBase);

  /// Persist [line]. Fire and forget; never throws. [source] defaults to the
  /// writer's own (`ui`; a headless run passes `headless`). [always] overrides
  /// [isAlwaysOnLogLine] for a caller that knows better.
  static Future<void> write(String line, {String? source, bool? always}) =>
      instance.add(line, source: source, always: always);

  /// The folder holding `dev_log/` and the legacy `openstrap_sync.log`.
  final Future<Directory> Function() baseDir;
  final String source;
  final int maxBytes;

  /// Writes between size checks (retention also runs when the day changes).
  final int sizeCheckEvery;

  /// How long an append waits on another writer's lock before presuming that
  /// writer died mid-write and taking the lock over.
  final Duration lockWait;
  final DateTime Function() _now;
  final Future<bool> Function() _devMode;

  Future<void> _chain = Future.value();
  Future<Directory?>? _dir;
  String? _day; // the day this writer last opened a file for
  int _sinceCheck = 0;
  bool _full = false, _fullNoted = false;

  static Future<Directory> _platformBase() async =>
      await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();

  static DateTime? _prefsReadAt;
  static bool _prefsDev = false;

  /// UI isolate: the already-loaded [Prefs] cache. Any other isolate (Prefs is
  /// never loaded there): SharedPreferences re-read at most every 30 s, so a
  /// toggle made in the UI reaches a long-lived background isolate.
  static Future<bool> _prefsDevMode() async {
    if (Prefs.loaded) return Prefs.getBool(Prefs.devMode, false);
    final at = DateTime.now();
    final last = _prefsReadAt;
    if (last == null || at.difference(last) > const Duration(seconds: 30)) {
      _prefsReadAt = at;
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.reload();
        _prefsDev = sp.getBool(Prefs.devMode) ?? false;
      } catch (_) {}
    }
    return _prefsDev;
  }

  /// Queue one record. The time is taken now, the decision to write and the
  /// write itself happen in order behind earlier records.
  Future<void> add(String line, {String? source, bool? always}) {
    final at = _now();
    final src = sanitizeDevLogText(source ?? this.source).replaceAll(' ', '_');
    final on = always ?? isAlwaysOnLogLine(line);
    final text = sanitizeDevLogText(line);
    return _chain = _chain.then((_) => _write(at, src, text, on));
  }

  /// Completes when every record added so far has been handled.
  Future<void> flush() => _chain;

  /// `<base>/dev_log`, created on first use; null when it cannot be (a failed
  /// resolve is retried on the next write).
  Future<Directory?> dir() => _dir ??= () async {
        try {
          final d = Directory('${(await baseDir()).path}/dev_log');
          await d.create(recursive: true);
          return d;
        } catch (_) {
          _dir = null;
          return null;
        }
      }();

  /// The day files, oldest first.
  Future<List<File>> dayFiles() async {
    final d = await dir();
    if (d == null) return const [];
    final out = <File>[];
    try {
      await for (final e in d.list()) {
        if (e is File && devLogDayOf(e.uri.pathSegments.last) != null) {
          out.add(e);
        }
      }
    } catch (_) {}
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// `openstrap_sync.log` and `.1` from the old FileLog, when still present.
  Future<List<File>> legacyFiles() async {
    final base = (await baseDir()).path;
    return [
      for (final n in const ['openstrap_sync.log', 'openstrap_sync.log.1'])
        if (File('$base/$n').existsSync()) File('$base/$n'),
    ];
  }

  /// Delete every day file and the legacy sync log, after the records already
  /// queued have landed. Throws when a file cannot be deleted. The next record
  /// opens a fresh file with its own header.
  Future<void> clear() {
    final r = _chain.then((_) async {
      for (final f in [...await dayFiles(), ...await legacyFiles()]) {
        try {
          await f.delete();
        } on PathNotFoundException {
          // another isolate got there first
        }
      }
      _day = null;
      _full = _fullNoted = false;
    });
    _chain = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<void> _write(DateTime at, String src, String text, bool on) async {
    try {
      if (!on && !await _devMode()) return;
      final d = await dir();
      if (d == null) return;
      final day = dayLabelOf(at);
      final opening = day != _day;
      if (opening || ++_sinceCheck >= sizeCheckEvery) {
        _sinceCheck = 0;
        await _prune(d, at, day);
      }
      final file = File('${d.path}/dev-$day.log');
      if (_full && !on) {
        // ponytail: a single day over the cap (a runaway logger) drops new
        // developer-mode lines until the day rolls over or Clear; evicting the
        // front of today's file would need a rewrite that races the other
        // isolates' appends. Alarm, wake and sync lines are few and are the
        // reason this log exists, so they are still written past the cap.
        if (_fullNoted) return;
        _fullNoted = true;
        text = '[devlog] size cap ($maxBytes bytes) reached; dropping '
            'developer-mode lines';
        src = 'devlog';
      } else if (!_full) {
        _fullNoted = false;
      }
      final record = devLogLine(at, src, text);
      final header = opening
          ? '${devLogLine(at, source, '[devlog] opened source=$source pid=$pid')}\n'
          : '';
      // One buffer, one write call, under the lock: see the header comment.
      await _appendLocked(
          d, file, utf8.encode('$header$record\n'));
      _day = day;
    } catch (_) {
      _dir = null; // the folder may be gone; resolve it again next time
      _day = null;
    }
  }

  Future<void> _appendLocked(Directory d, File file, List<int> bytes) async {
    final lock = File('${d.path}/.append.lock');
    final waited = Stopwatch()..start();
    while (true) {
      try {
        await lock.create(exclusive: true);
        break;
      } on PathNotFoundException {
        rethrow; // the folder is gone, not a busy lock
      } on FileSystemException {
        if (waited.elapsed < lockWait) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          continue;
        }
        // Held for too long: its writer died. Take it over.
        try {
          await lock.delete();
        } catch (_) {}
        waited.reset();
      }
    }
    try {
      await file.writeAsBytes(bytes, mode: FileMode.append);
    } finally {
      try {
        await lock.delete();
      } catch (_) {}
    }
  }

  /// Retention and the size backstop: delete day files older than the kept
  /// window, then the oldest others while the total is at the cap. What is left
  /// of [day] alone being over the cap sets [_full].
  Future<void> _prune(Directory d, DateTime at, String day) async {
    final oldest = devLogOldestKeptDay(at);
    final kept = <(String, File, int)>[];
    for (final f in await dayFiles()) {
      final fileDay = devLogDayOf(f.uri.pathSegments.last)!;
      try {
        if (fileDay.compareTo(oldest) < 0) {
          await f.delete();
        } else {
          kept.add((fileDay, f, await f.length()));
        }
      } catch (_) {}
    }
    var total = kept.fold<int>(0, (n, e) => n + e.$3);
    for (final (fileDay, f, len) in kept) {
      if (total < maxBytes) break;
      if (fileDay == day) continue;
      try {
        await f.delete();
      } catch (_) {}
      total -= len;
    }
    _full = total >= maxBytes;
  }
}
