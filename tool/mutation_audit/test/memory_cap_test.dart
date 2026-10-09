import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// The per-run memory cap: a transient user cgroup scope around the sandbox.
/// Command line and bookkeeping here; that the kernel really enforces it was
/// checked by hand (systemd-run --user, MemoryMax, a 300 MB allocation in a
/// 64 MB scope: oom_kill=1, peak=64M).
void main() {
  const gib = 1024 * 1024 * 1024, mib = 1024 * 1024;

  group('sizes', () {
    test('parseByteSize: plain bytes and K/M/G/T suffixes (powers of 1024, as systemd reads them)', () {
      expect(parseByteSize('0'), 0);
      expect(parseByteSize('1048576'), mib);
      expect(parseByteSize('512M'), 512 * mib);
      expect(parseByteSize('4G'), 4 * gib);
      expect(parseByteSize('4g'), 4 * gib);
      expect(parseByteSize('4GB'), 4 * gib);
      expect(parseByteSize('4GiB'), 4 * gib);
      expect(parseByteSize('64k'), 64 * 1024);
      expect(parseByteSize('1T'), 1024 * gib);
      expect(parseByteSize(' 2G '), 2 * gib);
    });

    test('parseByteSize: anything else is null', () {
      for (final bad in ['', 'G', '-1', '1.5G', '4 gigs', '0x10', 'one', '4GG']) {
        expect(parseByteSize(bad), isNull, reason: bad);
      }
    });

    test('formatBytes: B, K, M, whole; G with one decimal', () {
      expect(formatBytes(0), '0B');
      expect(formatBytes(900), '900B');
      expect(formatBytes(2048), '2K');
      expect(formatBytes(812 * mib), '812M');
      expect(formatBytes(4 * gib), '4.0G');
      expect(formatBytes((1.2 * gib).round()), '1.2G');
    });
  });

  group('the command line', () {
    const cap = MemoryCap(maxBytes: 4 * gib);

    test('systemd-run puts the command in a user scope with a hard limit, no swap, and no systemd OOM stop', () {
      final a = cap.wrap(['bwrap', '--dev', '/dev', '--', 'flutter', 'test']);
      expect(a.take(4), ['systemd-run', '--user', '--scope', '--quiet']);
      expect(a, containsAllInOrder(['-p', 'MemoryMax=${4 * gib}']));
      expect(a, containsAllInOrder(['-p', 'MemorySwapMax=0']));
      // With the default policy systemd stops the whole scope on an OOM kill, taking the
      // reporting wrapper with it; "continue" lets the wrapper read the cgroup's verdict.
      expect(a, containsAllInOrder(['-p', 'OOMPolicy=continue']));
    });

    test('the original command is at the end, intact, behind the reporting wrapper', () {
      final inner = ['bwrap', '--dev', '/dev', '--', 'flutter', 'test', '--name', 'a b'];
      final a = cap.wrap(inner);
      expect(a.sublist(a.length - inner.length), inner);
      final sep = a.indexOf('--');
      expect(a[sep + 1], 'sh');
      expect(a[sep + 2], '-c');
      expect(a[sep + 3], allOf(contains('memory.peak'), contains('oom_kill'), contains('memory.max'), contains(memoryMarker)));
      expect(a[sep + 3], contains(r'"$@"'), reason: 'runs the command and keeps its exit status');
    });

    test('the limit is in bytes whatever was typed', () {
      expect(const MemoryCap(maxBytes: 512 * mib).wrap(['x']), contains('MemoryMax=${512 * mib}'));
    });

    test('a different systemd-run is used when named', () {
      expect(const MemoryCap(maxBytes: gib, systemdRun: '/opt/systemd-run').wrap(['x']).first, '/opt/systemd-run');
    });
  });

  group('reading what the wrapper reported', () {
    const cap = MemoryCap(maxBytes: 4 * gib);
    ProcessOutcome withStderr(String stderr, {int exitCode = 0}) => ProcessOutcome(exitCode: exitCode, stderr: stderr);

    test('peak and oom kills are taken from the marker line, which is removed from stderr', () {
      final o = cap.read(withStderr('some warning\n$memoryMarker peak=812000000 oom_kill=0 max=${4 * gib}\n'));
      expect(o.memoryPeakBytes, 812000000);
      expect(o.oomKills, 0);
      expect(o.stderr, 'some warning\n');
    });

    test('an OOM kill', () {
      final o = cap.read(withStderr('$memoryMarker peak=${4 * gib} oom_kill=2 max=${4 * gib}\n', exitCode: 137));
      expect(o.oomKills, 2);
      expect(o.memoryPeakBytes, 4 * gib);
      expect(o.exitCode, 137);
      expect(o.stderr, isEmpty);
    });

    test('the last marker counts; text around it survives', () {
      final o = cap.read(withStderr('a\n$memoryMarker peak=1 oom_kill=9 max=1\nb\n$memoryMarker peak=5 oom_kill=0 max=1\n'));
      expect(o.memoryPeakBytes, 5);
      expect(o.oomKills, 0);
      expect(o.stderr, 'a\n$memoryMarker peak=1 oom_kill=9 max=1\nb\n', reason: 'only the line that was read is taken out');
    });

    test('a kernel without memory.peak: oom kills known, peak unknown', () {
      final o = cap.read(withStderr('$memoryMarker peak= oom_kill=0 max=1\n'));
      expect(o.memoryPeakBytes, isNull);
      expect(o.oomKills, 0);
    });

    test('no marker (the wrapper was killed, or the run timed out): nothing is known, nothing is invented', () {
      final o = cap.read(withStderr('flutter: something\n', exitCode: -9));
      expect(o.memoryPeakBytes, isNull);
      expect(o.oomKills, isNull);
      expect(o.stderr, 'flutter: something\n');
      expect(o.exitCode, -9);
    });

    test('everything else in the outcome is carried over', () {
      const original = ProcessOutcome(
          exitCode: 3,
          stdoutLines: ['a', 'b'],
          stderr: 'x\n',
          timedOut: true,
          cancelled: true,
          outputComplete: false,
          elapsed: Duration(seconds: 7),
          lingeringStopped: 2,
          survivors: ['pid 9 (start 1)']);
      final o = cap.read(original);
      expect(o.exitCode, 3);
      expect(o.stdoutLines, ['a', 'b']);
      expect(o.timedOut, isTrue);
      expect(o.cancelled, isTrue);
      expect(o.outputComplete, isFalse);
      expect(o.elapsed, const Duration(seconds: 7));
      expect(o.lingeringStopped, 2);
      expect(o.survivors, ['pid 9 (start 1)']);
    });
  });

  group('SandboxedProcessRunner with a cap', () {
    Sandbox sandbox() => Sandbox(exportPath: '/e', home: '/home/dev', binds: const ['/usr']);

    test('the run goes through systemd-run, around bwrap; the outcome carries peak and oom kills', () async {
      final inner = FakeProcessRunner((call) => ProcessOutcome(
          exitCode: 137, stderr: '$memoryMarker peak=${3 * gib} oom_kill=1 max=${4 * gib}\n'));
      final runner = SandboxedProcessRunner(inner, sandbox(), memoryCap: const MemoryCap(maxBytes: 4 * gib));
      final o = await runner.run(['dart', 'test'], workingDirectory: '/e');
      final argv = inner.calls.single.argv;
      expect(argv.first, 'systemd-run');
      expect(argv, contains('bwrap'));
      expect(argv.indexOf('bwrap'), greaterThan(argv.indexOf('--')));
      expect(argv.sublist(argv.length - 2), ['dart', 'test']);
      expect(o.oomKills, 1);
      expect(o.memoryPeakBytes, 3 * gib);
      expect(o.stderr, isEmpty);
    });

    test('without a cap nothing changes: bwrap first, no fields', () async {
      final inner = FakeProcessRunner((call) => const ProcessOutcome(exitCode: 0, stderr: 'x'));
      final runner = SandboxedProcessRunner(inner, sandbox());
      final o = await runner.run(['dart', 'test'], workingDirectory: '/e');
      expect(inner.calls.single.argv.first, 'bwrap');
      expect(o.oomKills, isNull);
      expect(o.memoryPeakBytes, isNull);
      expect(o.stderr, 'x');
    });
  });

  group('probe', () {
    const cap = MemoryCap(maxBytes: 4 * gib);

    test('a scope that reports exactly the requested limit passes; what ran is the wrapper around "true"', () async {
      List<String>? ran;
      await MemoryCap.probe(cap, run: (argv) async {
        ran = argv;
        return ProcessResult(1, 0, '', '$memoryMarker peak=2437120 oom_kill=0 max=${4 * gib}\n');
      });
      expect(ran!.first, 'systemd-run');
      expect(ran!.last, 'true');
    });

    test('systemd-run missing: unavailable, naming the way out', () async {
      await expectLater(
          MemoryCap.probe(cap, run: (argv) async => throw const ProcessException('systemd-run', [], 'No such file or directory')),
          throwsA(isA<MemoryCapUnavailable>().having(
              (e) => e.message, 'message', allOf(contains('systemd-run'), contains('--no-memory-cap'), contains('--memory-max 0')))));
    });

    test('no user manager (systemd-run fails): unavailable, with its message', () async {
      await expectLater(
          MemoryCap.probe(cap, run: (argv) async => ProcessResult(1, 1, '', 'Failed to connect to user scope bus via local transport\n')),
          throwsA(isA<MemoryCapUnavailable>().having((e) => e.message, 'message', allOf(contains('Failed to connect'), contains('--no-memory-cap')))));
    });

    test('a scope that ignores the limit (memory controller not delegated): unavailable', () async {
      await expectLater(
          MemoryCap.probe(cap, run: (argv) async => ProcessResult(1, 0, '', '$memoryMarker peak=1 oom_kill=0 max=max\n')),
          throwsA(isA<MemoryCapUnavailable>().having((e) => e.message, 'message', allOf(contains('not enforced'), contains('max')))));
    });

    test('a scope that says nothing: unavailable', () async {
      await expectLater(MemoryCap.probe(cap, run: (argv) async => ProcessResult(1, 0, '', '')), throwsA(isA<MemoryCapUnavailable>()));
    });
  });
}
