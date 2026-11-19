// #99: the packaged-APK manifest gate. Proven on fixtures, because the build
// host's SDK is not where the test runs: a fake aapt/aapt2 prints a fixture
// tree, a fake flutter stands in for the guard group, and the real scanner
// (tool/scan_manifest.dart) must still fail the gate on a banned component.
//
// catches: the gate passing a manifest that carries an install capability, an
// aapt2-only SDK being unusable, and a missing input being read as success.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _clean = '''
N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=2)
    A: package="wtf.openstrap.edge" (Raw: "wtf.openstrap.edge")
    E: uses-permission (line=5)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.permission.BLUETOOTH_SCAN" (Raw: "android.permission.BLUETOOTH_SCAN")
    E: application (line=9)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="io.flutter.app.FlutterApplication" (Raw: "io.flutter.app.FlutterApplication")
''';
const _banned = '''
N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=2)
    E: uses-permission (line=5)
      A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.permission.REQUEST_INSTALL_PACKAGES" (Raw: "android.permission.REQUEST_INSTALL_PACKAGES")
    E: application (line=9)
''';
const _mergedClean = '<manifest><application/></manifest>';
const _mergedBanned =
    '<manifest><uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/><application/></manifest>';

/// The SDK's own dart binary. The `dart` wrapper on PATH re-enters flutter's
/// shell scripts, which read variables the test runner does not pass on.
String _dart() {
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null) Platform.environment['FLUTTER_ROOT']!,
    // flutter_tester lives at <root>/bin/cache/artifacts/engine/<platform>/.
    p.dirname(p.dirname(p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable))))),
  ];
  for (final r in roots) {
    final d = p.join(r, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
    if (File(d).existsSync()) return d;
  }
  return 'dart';
}

class _Rig {
  _Rig(this.root);
  final Directory root;
  late final String head;
  String get script => p.join(root.path, 'tool', 'check_update_apk.sh');

  static Future<_Rig> create() async {
    final root = await Directory.systemTemp.createTemp('apk-gate-rig-');
    final rig = _Rig(root);
    for (final f in const [
      'tool/check_update_apk.sh',
      'tool/scan_manifest.dart',
      'test/guards/support/no_install_scan.dart',
    ]) {
      final dst = File(p.join(root.path, f))..parent.createSync(recursive: true);
      dst.writeAsStringSync(File(f).readAsStringSync());
    }
    Future<void> git(List<String> a) async {
      final r = await Process.run('git', ['-C', root.path, ...a]);
      if (r.exitCode != 0) throw StateError('git ${a.join(' ')}: ${r.stderr}');
    }
    await git(['init', '-q']);
    await git(['add', '.']);
    await git(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'rig']);
    rig.head = ((await Process.run('git', ['-C', root.path, 'rev-parse', 'HEAD'])).stdout as String).trim();
    return rig;
  }

  /// A fake SDK tool printing [tree]; [aapt2] picks the argument shape it demands.
  File fakeTool(String name, String tree, {required bool aapt2}) {
    final f = File(p.join(root.path, 'bin', name))..parent.createSync(recursive: true);
    final shape = aapt2
        ? r'[[ "$1 $2 $3 $4" == "dump xmltree --file AndroidManifest.xml" ]] || { echo "bad aapt2 args: $*" >&2; exit 9; }'
        : r'[[ "$1 $2 $4" == "dump xmltree AndroidManifest.xml" ]] || { echo "bad aapt args: $*" >&2; exit 9; }';
    f.writeAsStringSync("#!/usr/bin/env bash\n$shape\ncat <<'EOF_TREE'\n$tree\nEOF_TREE\n");
    Process.runSync('chmod', ['+x', f.path]);
    return f;
  }

  File fakeFlutter() {
    final f = File(p.join(root.path, 'bin', 'flutter'))..parent.createSync(recursive: true);
    f.writeAsStringSync('#!/usr/bin/env bash\necho "fake flutter: guard group ran with EDGE_MERGED_MANIFEST=\$EDGE_MERGED_MANIFEST"\n');
    Process.runSync('chmod', ['+x', f.path]);
    return f;
  }

  Directory merged(String xml) {
    final d = Directory(p.join(root.path, 'merged'))..createSync(recursive: true);
    File(p.join(d.path, 'AndroidManifest.xml')).writeAsStringSync(xml);
    return d;
  }

  File apk() => File(p.join(root.path, 'edge.apk'))..writeAsStringSync('apk fixture');

  Future<ProcessResult> run(List<String> args, {Map<String, String> env = const {}}) =>
      Process.run('bash', [script, ...args], environment: {
        // PATH keeps system tools; the fakes arrive through explicit variables.
        'AAPT': '', 'AAPT2': '', 'ANDROID_HOME': '', 'ANDROID_SDK_ROOT': '',
        'DART': _dart(),
        ...env,
      });
}

void main() {
  late _Rig rig;
  setUp(() async => rig = await _Rig.create());
  tearDown(() => rig.root.delete(recursive: true));

  List<String> args({Directory? merged}) => [
        '--apk', rig.apk().path,
        '--merged-manifest', (merged ?? rig.merged(_mergedClean)).path,
        '--head', rig.head, '--variant', 'release',
        '--output', p.join(rig.root.path, 'out'),
      ];

  test('aapt2 tree and merged manifest both clean: gate passes and writes PASS', () async {
    final r = await rig.run(args(), env: {
      'AAPT2': rig.fakeTool('aapt2', _clean, aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(File(p.join(rig.root.path, 'out', 'PASS')).existsSync(), isTrue);
  });

  test('classic aapt is still accepted', () async {
    final r = await rig.run(args(), env: {
      'AAPT': rig.fakeTool('aapt', _clean, aapt2: false).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  });

  test('an install permission in the packaged manifest fails the gate, no PASS', () async {
    final r = await rig.run(args(), env: {
      'AAPT2': rig.fakeTool('aapt2', _banned, aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('REQUEST_INSTALL_PACKAGES'));
    expect(File(p.join(rig.root.path, 'out', 'PASS')).existsSync(), isFalse);
  });

  test('an install permission only in the merged manifest fails the gate', () async {
    final r = await rig.run(args(merged: rig.merged(_mergedBanned)), env: {
      'AAPT2': rig.fakeTool('aapt2', _clean, aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('REQUEST_INSTALL_PACKAGES'));
    expect(File(p.join(rig.root.path, 'out', 'PASS')).existsSync(), isFalse);
  });

  test('no aapt or aapt2 anywhere fails closed', () async {
    final r = await rig.run(args(), env: {
      'FLUTTER': rig.fakeFlutter().path,
      'PATH': '/usr/bin:/bin',
    });
    expect(r.exitCode, 2);
    expect(r.stderr, contains('aapt'));
  });

  test('a tool that prints no manifest tree fails', () async {
    final r = await rig.run(args(), env: {
      'AAPT2': rig.fakeTool('aapt2', 'nothing useful', aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, isNot(0));
  });

  test('omitting --merged-manifest without a Gradle output fails closed', () async {
    final r = await rig.run([
      '--apk', rig.apk().path, '--head', rig.head, '--variant', 'release',
    ], env: {
      'AAPT2': rig.fakeTool('aapt2', _clean, aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, 2);
    expect(r.stderr, contains('merged'));
  });

  test('head and variant default, so the APK path is enough with a merged dir', () async {
    final r = await rig.run([
      '--apk', rig.apk().path,
      '--merged-manifest', rig.merged(_mergedClean).path,
      '--output', p.join(rig.root.path, 'out'),
    ], env: {
      'AAPT2': rig.fakeTool('aapt2', _clean, aapt2: true).path,
      'FLUTTER': rig.fakeFlutter().path,
    });
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  });
}
