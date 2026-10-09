import 'dart:async';
import 'dart:io';

import 'process_runner.dart';

/// The line the reporting wrapper (see [MemoryCap.wrap]) writes to stderr when
/// the run is over: `mutaudit-memory: peak=<bytes> oom_kill=<n> max=<bytes>`.
const memoryMarker = 'mutaudit-memory:';

/// `systemd-run --user` cannot give runs a memory-limited scope here.
class MemoryCapUnavailable implements Exception {
  MemoryCapUnavailable(this.message);
  final String message;
  @override
  String toString() => 'MemoryCapUnavailable: $message';
}

/// A size such as `4G`, `512M`, `64k` or `1048576` (powers of 1024, with an
/// optional `B` / `iB`, as systemd reads them) in bytes; null when [text] is
/// not one. Integers only.
int? parseByteSize(String text) {
  final m = RegExp(r'^(\d+)\s*([kmgt]?)(?:i?b)?$', caseSensitive: false).firstMatch(text.trim());
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null) return null;
  final shift = switch (m.group(2)!.toLowerCase()) { 'k' => 10, 'm' => 20, 'g' => 30, 't' => 40, _ => 0 };
  return n << shift;
}

/// `900B`, `2K`, `812M`, `4.0G`.
String formatBytes(int bytes) {
  const k = 1024, m = 1024 * 1024, g = 1024 * 1024 * 1024;
  if (bytes >= g) return '${(bytes / g).toStringAsFixed(1)}G';
  if (bytes >= m) return '${(bytes / m).round()}M';
  if (bytes >= k) return '${(bytes / k).round()}K';
  return '${bytes}B';
}

/// A hard memory limit for one run, from the kernel's cgroup memory controller
/// through a transient systemd user scope:
///
/// `systemd-run --user --scope --quiet -p MemoryMax=<bytes> -p MemorySwapMax=0
/// -p OOMPolicy=continue -- sh -c '<report>' mutaudit-cap <command>...`
///
/// The scope is the cgroup. Everything the command starts is charged to it:
/// heap, page cache and the pages of tmpfs mounts, the sandbox's export overlay
/// included (bubblewrap cannot size `--tmp-overlay`, so this limit is what
/// bounds it). With no swap, a run over the limit gets the cgroup's own OOM
/// killer, which kills a process of THIS scope; the host's OOM killer, which
/// could pick an unrelated process, is not reached.
///
/// Why the `sh` wrapper: a scope that exits normally is unloaded at once, and
/// its peak (`memory.peak`) and kill count (`memory.events`, `oom_kill`) are
/// gone; so the wrapper runs the command, then reads both from its own cgroup
/// while it still exists and prints them as one [memoryMarker] line on stderr.
/// `OOMPolicy=continue` is what lets it: with the default (`stop`) systemd
/// reacts to an OOM kill by stopping the whole scope, the wrapper included,
/// before it can report (checked by hand: Result=oom-kill, no marker).
class MemoryCap {
  const MemoryCap({required this.maxBytes, this.systemdRun = 'systemd-run'});

  final int maxBytes;
  final String systemdRun;

  static const _report = r'''"$@"; rc=$?
cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
peak=$(cat "$cg/memory.peak" 2>/dev/null); oom=$(sed -n 's/^oom_kill //p' "$cg/memory.events" 2>/dev/null); max=$(cat "$cg/memory.max" 2>/dev/null)
printf 'mutaudit-memory: peak=%s oom_kill=%s max=%s\n' "$peak" "$oom" "$max" >&2
exit $rc''';

  /// [argv] inside the limited scope.
  List<String> wrap(List<String> argv) => [
        systemdRun,
        '--user',
        '--scope',
        '--quiet',
        '-p', 'MemoryMax=$maxBytes',
        '-p', 'MemorySwapMax=0',
        '-p', 'OOMPolicy=continue',
        '--',
        'sh', '-c', _report, 'mutaudit-cap',
        ...argv,
      ];

  /// [outcome] with the peak and the OOM kill count the wrapper reported, and
  /// the marker line taken out of stderr. A run without a marker (timed out,
  /// cancelled, the wrapper itself killed) keeps both unknown (null): nothing
  /// is guessed.
  ProcessOutcome read(ProcessOutcome outcome) {
    final lines = outcome.stderr.split('\n');
    final at = lines.lastIndexWhere((l) => l.startsWith(memoryMarker));
    if (at < 0) return outcome;
    final fields = {
      for (final m in RegExp(r'(\w+)=(\S*)').allMatches(lines[at])) m.group(1)!: m.group(2)!,
    };
    return outcome.withMemory(
      stderr: (lines..removeAt(at)).join('\n'),
      peakBytes: int.tryParse(fields['peak'] ?? ''),
      oomKills: int.tryParse(fields['oom_kill'] ?? ''),
    );
  }

  /// Checks that a scope with this limit can be started and really carries it:
  /// the cgroup of a scope that ran `true` must say `memory.max` = [maxBytes]
  /// (a user session without the memory controller delegated accepts the
  /// property and enforces nothing). Throws [MemoryCapUnavailable] otherwise.
  /// [run] is a seam for tests (default: `Process.run`, 60 s).
  static Future<void> probe(MemoryCap cap, {Future<ProcessResult> Function(List<String> argv)? run}) async {
    const way = 'Pass --no-memory-cap to run without a memory limit (a runaway mutant can then take all memory, '
        'and with no swap the host\'s OOM killer may pick another process of yours), or give --memory-max 0 for the same';
    final argv = cap.wrap(const ['true']);
    final ProcessResult r;
    try {
      r = await (run ?? _run)(argv);
    } on ProcessException catch (e) {
      throw MemoryCapUnavailable('"${cap.systemdRun}" cannot be run: ${e.message}. The per-run memory limit needs '
          'systemd-run --user. $way');
    } on TimeoutException {
      throw MemoryCapUnavailable('"${cap.systemdRun} --user --scope" did not finish in 60 s. $way');
    }
    final stderr = '${r.stderr}';
    if (r.exitCode != 0) {
      throw MemoryCapUnavailable('"${cap.systemdRun} --user --scope" failed (exit ${r.exitCode}): ${_first(stderr)}. $way');
    }
    final probed = cap.read(ProcessOutcome(exitCode: 0, stderr: stderr));
    final line = stderr.split('\n').lastWhere((l) => l.startsWith(memoryMarker), orElse: () => '');
    if (line.isEmpty || probed.oomKills == null) {
      throw MemoryCapUnavailable('the probe scope reported nothing about its cgroup (no $memoryMarker line), so the '
          'limit cannot be checked. $way');
    }
    final max = RegExp(r'max=(\S*)').firstMatch(line)?.group(1);
    if (max != '${cap.maxBytes}') {
      throw MemoryCapUnavailable('the memory limit is not enforced: a scope asked for MemoryMax=${cap.maxBytes} has '
          'memory.max=${max == null || max.isEmpty ? 'unreadable' : max} (the memory controller is probably not '
          'delegated to your systemd user session). $way');
    }
  }

  static Future<ProcessResult> _run(List<String> argv) =>
      Process.run(argv.first, argv.sublist(1)).timeout(const Duration(seconds: 60));

  static String _first(String text) {
    final t = text.trim();
    return t.isEmpty ? 'no message' : t.split('\n').first;
  }
}
