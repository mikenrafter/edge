import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// The test-visible state of the export cannot be kept the same before every
/// run (a change that cannot be put back, a dirty start, a moved HEAD). The
/// audit stops: nothing after this point could be trusted.
class ExportStateError implements Exception {
  ExportStateError(this.message);
  final String message;
  @override
  String toString() => 'ExportStateError: $message';
}

/// Directories and files that may hold anything between runs: build caches
/// the test tool rebuilds and reuses. Root-relative, glob syntax.
const defaultCacheDirs = [
  '.dart_tool',
  'build',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.packages',
];

/// Keeps what a test run can see in the export the same before every run.
///
/// The export is a git worktree of the pinned commit, so "the same" has three
/// parts, all checked from the export itself:
///
/// - tracked and untracked-but-not-ignored files: `git status` must be empty
///   (apart from caches) when the audit starts ([snapshot]) and is made empty
///   again after every run ([restore]: tracked files from HEAD, index too;
///   `git clean -fd` without `-x` for the rest);
/// - ignored files outside the caches: a content-hash manifest taken at
///   [snapshot]. A file a run ADDED is deleted; one it CHANGED or REMOVED
///   cannot be put back (no copy is kept) and stops the audit;
/// - HEAD: a test that committed would move the target of every restore.
///
/// Files inside the cache directories ([defaultCacheDirs] plus the ones passed
/// in) are not looked at. That is what a cache is for, and it is a declared
/// channel between runs.
class ExportStateGuard {
  ExportStateGuard({required this.root, List<String> cacheDirs = const []})
      : cacheDirs = [
          ...{
            ...defaultCacheDirs,
            for (final c in cacheDirs) _clean(c),
          }
        ];

  /// The export (a git worktree).
  final String root;

  /// Cache paths (root-relative globs), defaults included.
  final List<String> cacheDirs;

  String? _head;
  Map<String, String>? _ignored;
  late final List<Glob> _caches = [for (final c in cacheDirs) Glob(c, context: p.posix)];

  static String _clean(String c) {
    var v = c.trim();
    while (v.startsWith('./')) {
      v = v.substring(2);
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// Takes the reference state. Throws [ExportStateError] when the export is
  /// not clean (setup or the baseline changed a tracked file, or left an
  /// untracked one outside the caches).
  Future<void> snapshot() async {
    _head = await _git(['rev-parse', 'HEAD']);
    final dirty = await _dirty();
    if (dirty.isNotEmpty) {
      throw ExportStateError('the export is not clean after setup and the baseline (git status): '
          '${_list(dirty)}; the audit needs every run to start from the pinned commit, so setup and the '
          'tests must not change tracked files or leave untracked ones (declare caches with --cache-dir)');
    }
    _ignored = await _ignoredManifest();
  }

  /// Puts the export back to the snapshot and returns how many files had to be
  /// changed (restored, removed or deleted). [keep] are root-relative tracked
  /// paths that are mutated on purpose and must stay as they are. Throws
  /// [ExportStateError] when something differs that cannot be restored, or the
  /// tree is still not clean afterwards.
  Future<int> restore({Set<String> keep = const {}}) async {
    final reference = _ignored;
    if (reference == null) throw StateError('restore before snapshot');
    final head = await _git(['rev-parse', 'HEAD']);
    if (head != _head) {
      throw ExportStateError('HEAD moved from $_head to $head during a run (a test committed or checked '
          'out); the export cannot be put back to the pinned commit');
    }
    final dirty = [for (final d in await _dirty()) if (!keep.contains(d)) d];
    if (dirty.isNotEmpty) {
      await _git([
        'restore', '--source=HEAD', '--staged', '--worktree', '--', '.',
        for (final k in keep) ':(exclude,literal)$k',
      ]);
    }
    await _git([
      'clean', '-f', '-d', '-q',
      for (final c in cacheDirs) ...['-e', '/$c'],
    ]);

    // Ignored files outside the caches: delete additions, refuse the rest.
    final now = await _ignoredManifest();
    final added = [for (final k in now.keys) if (!reference.containsKey(k)) k]..sort();
    final lost = [
      for (final e in reference.entries)
        if (!now.containsKey(e.key)) '${e.key} (removed)' else if (now[e.key] != e.value) '${e.key} (changed)',
    ]..sort();
    if (lost.isNotEmpty) {
      throw ExportStateError('a run changed ignored files outside the caches, which cannot be restored '
          '(no copy is kept): ${_list(lost)}; declare the directory with --cache-dir if it is a cache');
    }
    for (final a in added) {
      File(p.join(root, a)).deleteSync();
    }

    final left = [for (final d in await _dirty()) if (!keep.contains(d)) d];
    if (left.isNotEmpty) {
      throw ExportStateError('the export is still not clean after the restore: ${_list(left)}');
    }
    return dirty.length + added.length;
  }

  String _list(List<String> paths) =>
      paths.length <= 6 ? paths.join(', ') : '${paths.take(6).join(', ')} and ${paths.length - 6} more';

  bool _isCache(String rel) {
    final parts = p.posix.split(rel);
    for (var i = 1; i <= parts.length; i++) {
      final prefix = parts.take(i).join('/');
      if (_caches.any((g) => g.matches(prefix))) return true;
    }
    return false;
  }

  /// Paths `git status` reports (tracked changes, staged ones, untracked files
  /// that are not ignored), outside the caches.
  Future<List<String>> _dirty() async {
    final out = await _git(['status', '--porcelain=v1', '--untracked-files=all', '-z'], trim: false);
    final fields = out.split('\u0000');
    final paths = <String>[];
    for (var i = 0; i < fields.length; i++) {
      final f = fields[i];
      if (f.length < 4) continue;
      final x = f[0], y = f[1];
      paths.add(f.substring(3));
      if (x == 'R' || x == 'C' || y == 'R' || y == 'C') i++; // the original path follows
    }
    return [for (final path in paths) if (!_isCache(path)) path]..sort();
  }

  /// Content hashes of the files git ignores, outside the caches.
  Future<Map<String, String>> _ignoredManifest() async {
    final out = await _git(['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'], trim: false);
    final manifest = <String, String>{};
    for (final entry in out.split('\u0000')) {
      if (entry.isEmpty) continue;
      if (entry.endsWith('/')) {
        await _walk(entry.substring(0, entry.length - 1), manifest);
      } else if (!_isCache(entry)) {
        manifest[entry] = await _fingerprint(File(p.join(root, entry)));
      }
    }
    return manifest;
  }

  Future<void> _walk(String relDir, Map<String, String> into) async {
    if (_isCache(relDir)) return;
    final dir = Directory(p.join(root, relDir));
    if (!dir.existsSync()) return;
    for (final e in dir.listSync(followLinks: false)) {
      final rel = '$relDir/${p.basename(e.path)}';
      if (_isCache(rel)) continue;
      if (e is Directory) {
        await _walk(rel, into);
      } else {
        into[rel] = await _fingerprint(e);
      }
    }
  }

  Future<String> _fingerprint(FileSystemEntity e) async {
    try {
      if (e is Link) return 'link:${e.targetSync()}';
      return (await sha256.bind((e as File).openRead()).first).toString();
    } on FileSystemException catch (x) {
      return 'unreadable:${x.osError?.errorCode}';
    }
  }

  Future<String> _git(List<String> args, {bool trim = true}) async {
    final r = await Process.run('git', args, workingDirectory: root, environment: {'GIT_OPTIONAL_LOCKS': '0'});
    if (r.exitCode != 0) {
      throw ExportStateError('git ${args.first} failed in the export (exit ${r.exitCode}): ${(r.stderr as String).trim()}');
    }
    final text = r.stdout as String;
    return trim ? text.trim() : text;
  }
}
