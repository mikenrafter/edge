// #84: a release build carries the full commit and the tag in the app
// (lib/data/official_export/mapper.dart reads OPENSTRAP_SOURCE_SHA / _TAG and
// falls back to "unknown"). The builder refuses to start without both.
//
// catches: a release APK that exports `source_sha: unknown`, a short or stale
// sha, and a second build path that skips the guard.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Rig {
  _Rig(this.root, this.head);
  final Directory root;
  final String head;
  String get builder => p.join(root.path, 'tool', 'build_release.sh');

  static Future<_Rig> create() async {
    final root = await Directory.systemTemp.createTemp('provenance-rig-');
    for (final f in const [
      'tool/build_release.sh',
      'tool/check_release_provenance.sh',
    ]) {
      File(p.join(root.path, f))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(File(f).readAsStringSync());
    }
    Future<ProcessResult> git(List<String> a) =>
        Process.run('git', ['-C', root.path, '-c', 'user.email=t@t', '-c', 'user.name=t', ...a]);
    await git(['init', '-q']);
    await git(['add', '.']);
    await git(['commit', '-qm', 'rig']);
    final head = ((await git(['rev-parse', 'HEAD'])).stdout as String).trim();
    return _Rig(root, head);
  }

  Future<ProcessResult> build(List<String> args, {Map<String, String> env = const {}}) =>
      Process.run('bash', [builder, ...args],
          environment: {
            'OPENSTRAP_SOURCE_SHA': '',
            'OPENSTRAP_SOURCE_TAG': '',
            'RELEASE_BUILD_DRY_RUN': '1',
            ...env,
          });
}

void main() {
  late _Rig rig;
  setUp(() async => rig = await _Rig.create());
  tearDown(() => rig.root.delete(recursive: true));

  test('both set: the exact command line carries the full sha and the tag', () async {
    final r = await rig.build(['--target-platform', 'android-arm64'],
        env: {'OPENSTRAP_SOURCE_TAG': 'pilot-1'});
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = (r.stdout as String).trim();
    expect(out, startsWith('flutter build apk --release'));
    expect(out, contains('--target-platform android-arm64'));
    expect(out, contains('--dart-define=OPENSTRAP_SOURCE_SHA=${rig.head}'));
    expect(out, contains('--dart-define=OPENSTRAP_SOURCE_TAG=pilot-1'));
  });

  test('appbundle and ios go through the same guard', () async {
    for (final kind in ['appbundle', 'ios']) {
      final r = await rig.build([kind, '--no-codesign'],
          env: {'OPENSTRAP_SOURCE_TAG': 'pilot-1'});
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(r.stdout, startsWith('flutter build $kind --release --no-codesign'));
      expect(r.stdout, contains('OPENSTRAP_SOURCE_SHA=${rig.head}'));
      final bad = await rig.build([kind]);
      expect(bad.exitCode, isNot(0), reason: kind);
    }
  });

  test('a missing tag fails', () async {
    final r = await rig.build([]);
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('OPENSTRAP_SOURCE_TAG'));
  });

  test('an annotated or lightweight tag on HEAD is read when none is passed', () async {
    await Process.run('git', ['-C', rig.root.path, 'tag', 'v9.9.9']);
    final r = await rig.build([]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(r.stdout, contains('OPENSTRAP_SOURCE_TAG=v9.9.9'));
  });

  for (final unknown in ['unknown', 'UNKNOWN', ' Unknown ']) {
    test('tag "$unknown" fails', () async {
      final r = await rig.build([], env: {'OPENSTRAP_SOURCE_TAG': unknown});
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('OPENSTRAP_SOURCE_TAG'));
    });
    test('sha "$unknown" fails', () async {
      final r = await rig.build([],
          env: {'OPENSTRAP_SOURCE_TAG': 'pilot-1', 'OPENSTRAP_SOURCE_SHA': unknown});
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('OPENSTRAP_SOURCE_SHA'));
    });
  }

  test('a short sha fails', () async {
    final r = await rig.build([], env: {
      'OPENSTRAP_SOURCE_TAG': 'pilot-1',
      'OPENSTRAP_SOURCE_SHA': rig.head.substring(0, 12),
    });
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('40'));
  });

  test('a full sha that is not the checked-out commit fails', () async {
    final r = await rig.build([], env: {
      'OPENSTRAP_SOURCE_TAG': 'pilot-1',
      'OPENSTRAP_SOURCE_SHA': 'a' * 40,
    });
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('HEAD'));
  });

  test('a tag with whitespace or a comma fails (it rides a dart-define)', () async {
    for (final bad in ['pilot 1', 'a,b', '']) {
      final r = await rig.build([], env: {'OPENSTRAP_SOURCE_TAG': bad});
      expect(r.exitCode, isNot(0), reason: 'tag "$bad"');
    }
  });

  test('passing the defines by hand is refused: one source per concern', () async {
    final r = await rig.build(['--dart-define=OPENSTRAP_SOURCE_SHA=${rig.head}'],
        env: {'OPENSTRAP_SOURCE_TAG': 'pilot-1'});
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('OPENSTRAP_SOURCE'));
  });

  test('the guard script alone checks explicit values', () async {
    final guard = p.join(rig.root.path, 'tool', 'check_release_provenance.sh');
    final ok = await Process.run('bash', [guard, '--sha', rig.head, '--tag', 'pilot-1']);
    expect(ok.exitCode, 0, reason: '${ok.stderr}');
    final bad = await Process.run('bash', [guard, '--sha', rig.head, '--tag', 'unknown']);
    expect(bad.exitCode, isNot(0));
  });

  // WHY: the guard is worthless if a release can be built another way.
  test('no workflow or Makefile target builds a release without the guard', () {
    final offenders = <String>[];
    for (final path in ['.github/workflows/build.yml', 'Makefile']) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('#')) continue;
        if (RegExp(r'flutter build (apk|appbundle|ios)\b').hasMatch(l) &&
            !l.contains('--debug') &&
            !l.contains('--profile')) {
          offenders.add('$path:${i + 1}: ${l.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'build via tool/build_release.sh:\n${offenders.join('\n')}');
  });
}
