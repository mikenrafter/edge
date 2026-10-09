import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A request to stop: Ctrl-C / SIGTERM. Threaded from the signal handler
/// through the audit loop and the process runner, so that whoever started a
/// child process is the one that stops it (and waits for it to be gone).
class CancelToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called (never, otherwise).
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// What one command run produced.
class ProcessOutcome {
  const ProcessOutcome({
    required this.exitCode,
    this.stdoutLines = const [],
    this.stderr = '',
    this.timedOut = false,
    this.cancelled = false,
    this.outputComplete = true,
    this.elapsed = Duration.zero,
  });

  final int exitCode;
  final List<String> stdoutLines;
  final String stderr;

  /// The run was stopped because it exceeded its timeout. The timeout bounds
  /// the whole run: the process exiting AND both output streams closing.
  final bool timedOut;

  /// The run was stopped because the audit was cancelled (Ctrl-C).
  final bool cancelled;

  /// Both output streams were read to their end. False when the runner had to
  /// stop waiting for them (a surviving process still held them open), so
  /// [stdoutLines] may be cut short.
  final bool outputComplete;
  final Duration elapsed;
}

/// Runs a command to completion. The real one spawns a process; tests inject a
/// fake. The runner owns the timeout (the tool never reads the real clock).
abstract class ProcessRunner {
  /// Runs [argv] in [workingDirectory]. Stops it (and everything it started)
  /// when [timeout] passes -- counted until the process has exited AND its
  /// output has closed -- or when [cancel] is cancelled, and says which in
  /// the outcome. Returns only once the stopped processes are gone (or could
  /// not be killed: then [ProcessOutcome.outputComplete] is false).
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
  });
}

/// A timer the runner can drop: a pending real timer would keep the process
/// alive after the work is done.
abstract class Alarm {
  /// Completes when the time has passed (never, once cancelled).
  Future<void> get fired;
  void cancel();
}

/// A started child process.
abstract class ChildProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  /// Started in a session of its own, so that processes it leaves behind (a
  /// wrapper that exited) can be found by session id while it is alive.
  bool get ownsSession;
}

/// Who a process is, not just which number it has: the pid, its start time (an
/// opaque token, `/proc/<pid>/stat` field 22 on Linux) and its parent and
/// session when it was seen. A pid handed out again later has another start
/// time, so it is another process.
class ProcIdentity {
  const ProcIdentity(this.pid, this.start, this.ppid, this.sid);
  final int pid;
  final String start;
  final int ppid, sid;

  @override
  String toString() => 'pid $pid (start $start)';
}

/// Everything the runner needs from the operating system. Faked in tests.
abstract class ProcessHost {
  /// Throws [ProcessException] when the program cannot be started.
  Future<ChildProcess> start(
    List<String> argv, {
    required String workingDirectory,
    Map<String, String>? environment,
  });

  /// Every live process, by pid.
  Future<Map<int, ProcIdentity>> snapshot();

  /// The identity of [pid] now, or null when there is no such process.
  ProcIdentity? identityOf(int pid);

  /// Sends [signal] to [target] only if the process with that pid still has
  /// the start time that was captured; returns whether it was sent. Positive
  /// pids only: no process group, no name matching, never init.
  bool signal(ProcIdentity target, ProcessSignal signal);

  Alarm alarm(Duration after);
}

/// Spawns real processes (the only place the tool touches real time).
///
/// The child is started under `setsid` when that exists, so it leads a session
/// of its own. The runner keeps a captured set of process identities (pid and
/// start time): sampled every [sampleEvery] while the child runs, once more the
/// moment the child exits (its session is read then, while the kernel still
/// holds its number), and again at the start of cleanup. Cleanup never forgets a
/// captured process: each rescan is the captured set that is still alive (same
/// start time) plus the descendants of any such member. Every member gets
/// SIGTERM, those still alive after [termGrace] get SIGKILL, and every signal
/// is sent only after re-reading the process's start time, so a pid that was
/// handed out again in the meantime is never signalled. (Between that read and
/// the kill there is a window of microseconds that no portable API closes.)
/// Then the streams get at most [drainGrace] to close before the runner stops
/// waiting for them.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner({
    this.host = const SystemProcessHost(),
    this.termGrace = const Duration(seconds: 5),
    this.drainGrace = const Duration(seconds: 2),
    this.pollEvery = const Duration(milliseconds: 100),
    this.sampleEvery = const Duration(seconds: 1),
  });

  final ProcessHost host;

  /// How long SIGTERM gets before SIGKILL.
  final Duration termGrace;

  /// How long to wait for the output streams to close after the kill.
  final Duration drainGrace;

  final Duration pollEvery;

  /// How often the family is captured while the child runs.
  final Duration sampleEvery;

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
  }) async {
    final clock = Stopwatch()..start();
    if (cancel != null && cancel.isCancelled) {
      return ProcessOutcome(exitCode: -15, cancelled: true, elapsed: clock.elapsed);
    }
    final ChildProcess child;
    try {
      child = await host.start(argv, workingDirectory: workingDirectory, environment: environment);
    } on ProcessException catch (e) {
      return ProcessOutcome(exitCode: 127, stderr: e.toString(), elapsed: clock.elapsed);
    }

    final stdout = _Collector(child.stdout);
    final stderr = _Collector(child.stderr);
    final family = _Family(host, child.pid, host.identityOf(child.pid)?.start, child.ownsSession);
    final exit = child.exitCode.then((code) {
      family.rootExited = true;
      // Read the session now: its members hold the number, so it cannot have
      // been reused yet. Later scans work from what was captured here.
      if (child.ownsSession) family.refresh(atRootExit: true).ignore();
      return code;
    });
    final finished = Future.wait<Object?>([exit, stdout.closed, stderr.closed]);
    final deadline = timeout == null ? null : host.alarm(timeout);
    var sampling = true;
    Alarm? sampler;
    void sample() {
      if (!sampling) return;
      final alarm = sampler = host.alarm(sampleEvery);
      alarm.fired.then((_) {
        if (!sampling) return;
        family.refresh().then((_) => sample(), onError: (Object _) => sample());
      });
    }

    sample();

    // Whole-run bound: the process AND its streams.
    final winner = await Future.any<_Ended>([
      finished.then((_) => _Ended.finished),
      if (deadline != null) deadline.fired.then((_) => _Ended.timeout),
      if (cancel != null) cancel.whenCancelled.then((_) => _Ended.cancelled),
    ]);
    deadline?.cancel();
    sampling = false;
    sampler?.cancel();

    if (winner == _Ended.finished) {
      await family.idle();
      return ProcessOutcome(
        exitCode: await exit,
        stdoutLines: stdout.lines(),
        stderr: stderr.text(),
        elapsed: clock.elapsed,
      );
    }

    await _stop(family);
    // The root is gone (or unkillable); the streams get a bounded time to close.
    final code = await _withinDrain(exit) ?? -9;
    await _withinDrain(Future.wait<Object?>([stdout.closed, stderr.closed]));
    final complete = stdout.isClosed && stderr.isClosed;
    await stdout.stop();
    await stderr.stop();
    return ProcessOutcome(
      exitCode: code,
      stdoutLines: stdout.lines(),
      stderr: stderr.text(),
      timedOut: winner == _Ended.timeout,
      cancelled: winner == _Ended.cancelled,
      outputComplete: complete,
      elapsed: clock.elapsed,
    );
  }

  /// [work]'s value, or null when [drainGrace] passes first.
  Future<T?> _withinDrain<T>(Future<T> work) async {
    final alarm = host.alarm(drainGrace);
    try {
      return await Future.any<T?>([work, alarm.fired.then((_) => null)]);
    } finally {
      alarm.cancel();
    }
  }

  /// SIGTERM the captured family, give it [termGrace], SIGKILL what is left.
  Future<void> _stop(_Family family) async {
    await family.idle();
    final first = await family.refresh();
    for (final member in first.reversed) {
      host.signal(member, ProcessSignal.sigterm);
    }
    final grace = host.alarm(termGrace);
    var graceOver = false;
    unawaited(grace.fired.then((_) => graceOver = true));
    try {
      while (!graceOver) {
        if ((await family.refresh()).isEmpty) return;
        final tick = host.alarm(pollEvery);
        await Future.any<void>([tick.fired, grace.fired]);
        tick.cancel();
      }
    } finally {
      grace.cancel();
    }
    // Survivors ignored SIGTERM. The captured set is rescanned (plus whatever
    // the survivors forked meanwhile) before each round.
    for (var round = 0; round < 5; round++) {
      final left = await family.refresh();
      if (left.isEmpty) return;
      for (final member in left.reversed) {
        host.signal(member, ProcessSignal.sigkill);
      }
      final tick = host.alarm(pollEvery);
      await tick.fired;
    }
  }
}

/// The processes that belong to one child: captured by identity and never
/// forgotten while they live.
class _Family {
  _Family(this.host, this.rootPid, this.rootStart, this.ownsSession);

  final ProcessHost host;
  final int rootPid;

  /// The child's start time as read right after it was started (null if it
  /// could not be read).
  final String? rootStart;
  final bool ownsSession;

  /// Set when the child's exit was seen: from then on its pid is not trusted.
  bool rootExited = false;

  final Map<int, ProcIdentity> _captured = {};
  Future<void> _busy = Future<void>.value();

  /// Resolves when the scans started so far are done.
  Future<void> idle() => _busy;

  /// Captures what belongs to the child now and returns the members that are
  /// alive: captured ones with an unchanged start time, the child itself while
  /// it runs, its session while it runs (or [atRootExit]: the one scan right
  /// after the exit), and every descendant of a member. Scans are serialised.
  Future<List<ProcIdentity>> refresh({bool atRootExit = false}) {
    final scan = _busy.then((_) => _scan(atRootExit));
    _busy = scan.then<void>((_) {}, onError: (Object _) {});
    return scan;
  }

  Future<List<ProcIdentity>> _scan(bool atRootExit) async {
    final snap = await host.snapshot();
    // A /proc walk is not atomic: entries are read one after the other, so a
    // pid can appear as its old owner while a child of its new owner is also
    // in the table. Nothing in the table is trusted on its own: a member is
    // kept, and an anchor used, only when its start time is read again now
    // (after the whole walk) and is the one captured.
    bool still(int pid, String start) {
      final fresh = host.identityOf(pid);
      return fresh != null && fresh.start == start;
    }

    final members = <int, ProcIdentity>{};
    for (final e in _captured.entries) {
      final now = snap[e.key];
      if (now != null && now.start == e.value.start && still(e.key, e.value.start)) members[e.key] = now;
    }
    final rootNow = snap[rootPid];
    final rootAlive = !rootExited &&
        rootNow != null &&
        (rootStart == null || rootNow.start == rootStart) &&
        still(rootPid, rootNow.start);
    if (rootAlive) members[rootPid] = rootNow;

    // A candidate joins only when it is anchored to a member re-validated
    // above (or to the adopted ones, validated as they join) and did not start
    // before that anchor.
    void adopt(ProcIdentity candidate, ProcIdentity anchor) {
      if (members.containsKey(candidate.pid)) return;
      if (!_notBefore(candidate.start, anchor.start)) return;
      if (!still(candidate.pid, candidate.start)) return;
      members[candidate.pid] = candidate;
    }

    if (ownsSession) {
      // The session is the root's while the root's identity holds. Right after
      // its exit (the one scan that reads the session while its members still
      // hold the number) it is read only if nothing has taken the root's pid
      // since: a newcomer that called setsid would own a session of that number.
      final anchorStart = rootAlive ? rootNow.start : rootStart;
      final exitScan = atRootExit && !rootAlive && snap[rootPid] == null && host.identityOf(rootPid) == null;
      if (rootAlive || exitScan) {
        for (final p in snap.values) {
          if (p.sid != rootPid || p.pid == rootPid) continue;
          if (anchorStart == null) {
            if (still(p.pid, p.start)) members.putIfAbsent(p.pid, () => p);
          } else {
            adopt(p, ProcIdentity(rootPid, anchorStart, 0, 0));
          }
        }
      }
    }
    var grew = true;
    while (grew) {
      grew = false;
      for (final p in snap.values) {
        if (members.containsKey(p.pid)) continue;
        final parent = members[p.ppid];
        if (parent == null) continue;
        adopt(p, parent);
        if (members.containsKey(p.pid)) grew = true;
      }
    }
    for (final e in members.entries) {
      _captured.putIfAbsent(e.key, () => e.value);
    }
    // In capture order: parents before the processes they started.
    return [for (final pid in _captured.keys) if (members.containsKey(pid)) _captured[pid]!];
  }
}

/// [a] started no earlier than [b]: start times are clock ticks since boot on
/// Linux (numbers), `ps` dates elsewhere (compared as dates; a form that is
/// not understood is not held against the candidate).
bool _notBefore(String a, String b) {
  final x = int.tryParse(a), y = int.tryParse(b);
  if (x != null && y != null) return x >= y;
  final dx = _psDate(a), dy = _psDate(b);
  return dx == null || dy == null || !dx.isBefore(dy);
}

/// `Thu Oct  9 12:00:00 2026` (ps -o lstart).
DateTime? _psDate(String s) {
  final m = RegExp(r'^\w{3} (\w{3})\s+(\d+) (\d+):(\d+):(\d+) (\d{4})$').firstMatch(s.trim());
  if (m == null) return null;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final month = months.indexOf(m.group(1)!);
  if (month < 0) return null;
  return DateTime.utc(int.parse(m.group(6)!), month + 1, int.parse(m.group(2)!), int.parse(m.group(3)!),
      int.parse(m.group(4)!), int.parse(m.group(5)!));
}

enum _Ended { finished, timeout, cancelled }

/// Reads one stream into memory and can stop reading at any time.
class _Collector {
  _Collector(Stream<List<int>> source) {
    _subscription = source.listen(
      _bytes.add,
      onDone: _close,
      onError: (Object _) => _close(),
      cancelOnError: true,
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<void> get closed => _done.future;
  bool get isClosed => _done.isCompleted;

  void _close() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Stops listening (a surviving process may still hold the pipe).
  Future<void> stop() => _subscription.cancel();

  String text() => utf8.decode(_bytes.toBytes(), allowMalformed: true);
  List<String> lines() => const LineSplitter().convert(text());
}

/// The real thing: `Process.start`, `/proc` (or `ps`), `kill`.
///
/// On Linux the identity of a process is its start time from
/// `/proc/<pid>/stat` (field 22, clock ticks since boot), re-read before every
/// signal. Where there is no `/proc` (macOS) `ps -o lstart` is used: its
/// resolution is one second, so a pid reused by a process started in the same
/// second as the one captured is not told apart, and `ps` gives no session id
/// (and `setsid` does not exist there either).
class SystemProcessHost implements ProcessHost {
  const SystemProcessHost();

  static bool? _setsid;

  /// util-linux `setsid` exists (Linux; macOS has none: then only descendants
  /// of the child can be found, from the samples taken while it ran).
  static bool get hasSetsid => _setsid ??= () {
        try {
          return Process.runSync('setsid', ['--version']).exitCode == 0;
        } on ProcessException {
          return false;
        }
      }();

  static bool get _hasProc => Directory('/proc/self').existsSync();

  @override
  Future<ChildProcess> start(
    List<String> argv, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final session = hasSetsid;
    final process = await Process.start(
      session ? 'setsid' : argv.first,
      session ? ['-w', ...argv] : argv.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return _RealChild(process, session);
  }

  @override
  Alarm alarm(Duration after) => _TimerAlarm(after);

  @override
  bool signal(ProcIdentity target, ProcessSignal signal) {
    if (target.pid <= 1) return false;
    final now = identityOf(target.pid);
    if (now == null || now.start != target.start) return false;
    return Process.killPid(target.pid, signal);
  }

  @override
  ProcIdentity? identityOf(int pid) {
    if (_hasProc) {
      try {
        return _fromStat(pid, File('/proc/$pid/stat').readAsStringSync());
      } on FileSystemException {
        return null;
      }
    }
    try {
      final r = Process.runSync('ps', ['-p', '$pid', '-o', 'pid=,ppid=,stat=,lstart=']);
      for (final line in LineSplitter.split(r.stdout as String)) {
        final id = _fromPs(line);
        if (id != null && id.pid == pid) return id;
      }
    } on ProcessException {
      // no ps
    }
    return null;
  }

  @override
  Future<Map<int, ProcIdentity>> snapshot() async {
    final table = <int, ProcIdentity>{};
    if (_hasProc) {
      for (final entity in Directory('/proc').listSync(followLinks: false)) {
        final pid = int.tryParse(entity.path.substring(entity.path.lastIndexOf('/') + 1));
        if (pid == null) continue;
        try {
          final id = _fromStat(pid, File('${entity.path}/stat').readAsStringSync());
          if (id != null) table[pid] = id;
        } on FileSystemException {
          continue; // exited meanwhile
        }
      }
      return table;
    }
    try {
      final r = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,stat=,lstart=']);
      for (final line in LineSplitter.split(r.stdout as String)) {
        final id = _fromPs(line);
        if (id != null) table[id.pid] = id;
      }
    } on ProcessException {
      // no ps: nothing can be found
    }
    return table;
  }

  /// "pid (comm) S ppid pgrp session ... starttime(22) ..."; comm may hold
  /// spaces and parentheses. Zombies and dead processes are not processes.
  static ProcIdentity? _fromStat(int pid, String stat) {
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    if (rest.length < 20 || rest[0] == 'Z' || rest[0] == 'X') return null;
    return ProcIdentity(pid, rest[19], int.parse(rest[1]), int.parse(rest[3]));
  }

  static ProcIdentity? _fromPs(String line) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 5 || f[2].startsWith('Z')) return null;
    final pid = int.tryParse(f[0]), ppid = int.tryParse(f[1]);
    if (pid == null || ppid == null) return null;
    return ProcIdentity(pid, f.sublist(3).join(' '), ppid, -1);
  }
}

class _RealChild implements ChildProcess {
  _RealChild(this._process, this.ownsSession);
  final Process _process;

  @override
  final bool ownsSession;
  @override
  int get pid => _process.pid;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  Future<int> get exitCode => _process.exitCode;
}

class _TimerAlarm implements Alarm {
  _TimerAlarm(Duration after) {
    _timer = Timer(after, _completer.complete);
  }
  final Completer<void> _completer = Completer<void>();
  late final Timer _timer;

  @override
  Future<void> get fired => _completer.future;
  @override
  void cancel() => _timer.cancel();
}
