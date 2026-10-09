import 'dart:io';

import 'package:path/path.dart' as p;

/// A throwaway git repository with committed files.
class GitFixture {
  GitFixture._(this.root, this.parent);

  /// The repository (a "developer checkout").
  final String root;

  /// The temp directory that holds it (and, beside it, things like siblings).
  final String parent;

  static Future<GitFixture> create(Map<String, String> files) async {
    final parent = Directory.systemTemp.createTempSync('mutaudit_fx_').resolveSymbolicLinksSync();
    final root = p.join(parent, 'repo');
    Directory(root).createSync();
    final fx = GitFixture._(root, parent);
    await fx.git(['init', '-q', '-b', 'main']);
    await fx.commit(files, 'first');
    return fx;
  }

  Future<String> git(List<String> args, {String? cwd}) async {
    final r = await Process.run(
      'git',
      ['-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'commit.gpgsign=false', ...args],
      workingDirectory: cwd ?? root,
    );
    if (r.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
    }
    return (r.stdout as String).trim();
  }

  /// Writes [files], commits them, returns the commit sha.
  Future<String> commit(Map<String, String> files, String message) async {
    for (final e in files.entries) {
      final f = File(p.join(root, e.key))..createSync(recursive: true);
      f.writeAsStringSync(e.value);
    }
    await git(['add', '-A']);
    await git(['commit', '-q', '-m', message]);
    return head();
  }

  Future<String> head() => git(['rev-parse', 'HEAD']);
  Future<String> status() => git(['status', '--porcelain']);
  Future<String> worktrees() => git(['worktree', 'list', '--porcelain']);

  void dispose() {
    final d = Directory(parent);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

/// A scratch directory removed by the caller.
Directory scratch([String prefix = 'mutaudit_']) =>
    Directory.systemTemp.createTempSync(prefix);
