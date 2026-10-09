import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'export_state.dart' show ExportStateError;

export 'export_state.dart' show ExportStateError;

/// What setup leaves in a fresh export that is not ignored by every project's
/// `.gitignore` (root-relative, first path segment).
const setupArtifacts = [
  '.dart_tool',
  'build',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.packages',
];

/// What can be seen of the export from the host in a few milliseconds.
class ExportView {
  const ExportView({
    required this.head,
    required this.status,
    required this.ignored,
    required this.directories,
    this.mutatedFile,
    this.mutatedHash,
  });
  final String head;

  /// `git status --porcelain` entries (`XY path`): tracked changes and
  /// untracked files.
  final List<String> status;

  /// Ignored entries as git reports them (an ignored directory as one entry),
  /// with size and modification time.
  final Map<String, String> ignored;

  /// Modification time of the root (`.`) and of every directory directly in
  /// it: an empty directory is invisible to git, but it moves its parent's time.
  final Map<String, String> directories;

  /// The root-relative file that carries the mutant, and the hash of its bytes.
  final String? mutatedFile, mutatedHash;

  /// Human-readable differences from [other] (empty: the same).
  List<String> differences(ExportView other) {
    final out = <String>[];
    if (head != other.head) out.add('HEAD moved from ${other.head} to $head');
    if (mutatedHash != other.mutatedHash) {
      out.add('${other.mutatedFile ?? mutatedFile} (the file carrying the mutation) changed content');
    }
    for (final s in status) {
      if (!other.status.contains(s)) out.add('git status now shows "$s"');
    }
    for (final s in other.status) {
      if (!status.contains(s)) out.add('git status no longer shows "$s"');
    }
    _mapDiff(out, 'ignored entry', ignored, other.ignored);
    _mapDiff(out, 'directory', directories, other.directories);
    return out;
  }

  static void _mapDiff(List<String> out, String what, Map<String, String> now, Map<String, String> was) {
    for (final e in now.entries) {
      final before = was[e.key];
      if (before == null) {
        out.add('$what ${e.key} appeared');
      } else if (before != e.value) {
        out.add('$what ${e.key} changed (${e.value} instead of $before)');
      }
    }
    for (final k in was.keys) {
      if (!now.containsKey(k)) out.add('$what $k disappeared');
    }
  }
}

/// The host-side tripwire for the sandbox: the export on the host must be what
/// it was before a run (the mutant applied, nothing else), at the pinned
/// commit. The sandbox is the isolation; this proves it held. It is a cheap
/// check, not a restore: tracked files and untracked ones through `git status`,
/// ignored entries and directories directly under the root through their size
/// and modification time. A write deeper inside an ignored directory that does
/// not move its modification time is out of its sight (the overlay is what
/// keeps it out of the host).
class ExportIntegrity {
  ExportIntegrity({required this.root, required this.pinnedSha});
  final String root;
  final String pinnedSha;

  /// HEAD is the pinned commit. [when] says which moment this is.
  Future<void> requirePinned(String when) async {
    final head = await _git(['rev-parse', 'HEAD']);
    if (head != pinnedSha) {
      throw ExportStateError('HEAD of the export is $head $when, not the pinned commit $pinnedSha '
          '(a command checked out or committed); nothing it ran can be trusted to be the audited code');
    }
  }

  /// [requirePinned], and `git status` is empty apart from what setup leaves
  /// ([setupArtifacts]).
  Future<void> requireClean(String when) async {
    await requirePinned(when);
    final dirty = [
      for (final s in (await _view()).status)
        if (!setupArtifacts.contains(p.posix.split(s.substring(3)).first)) s.substring(3),
    ]..sort();
    if (dirty.isNotEmpty) {
      throw ExportStateError('the export is not clean $when (git status): ${_list(dirty)}; every run must start '
          'from the pinned commit with only the mutant applied, so setup must not change tracked files or '
          'leave untracked ones that are not ignored');
    }
  }

  /// The export now; [mutatedFile] (root-relative) is hashed.
  Future<ExportView> view({String? mutatedFile}) => _view(mutatedFile: mutatedFile);

  /// The export is as in [before] (and at the pinned commit). Throws
  /// [ExportStateError] naming the differences; [during] says which run.
  Future<void> verifyUnchanged(ExportView before, {required String during}) async {
    await requirePinned('after $during');
    final now = await _view(mutatedFile: before.mutatedFile);
    final diff = now.differences(before);
    if (diff.isNotEmpty) {
      throw ExportStateError('$during changed the export on the host, which the sandbox must make impossible: '
          '${_list(diff)}; the isolation did not hold');
    }
  }

  Future<ExportView> _view({String? mutatedFile}) async {
    final head = await _git(['rev-parse', 'HEAD']);
    final out = await _git(['status', '--porcelain=v1', '--untracked-files=all', '--ignored=traditional', '-z'],
        trim: false);
    final fields = out.split('\u0000');
    final status = <String>[];
    final ignored = <String, String>{};
    for (var i = 0; i < fields.length; i++) {
      final f = fields[i];
      if (f.length < 4) continue;
      final x = f[0], y = f[1];
      if (x == '!' && y == '!') {
        ignored[f.substring(3)] = _stat(p.join(root, f.substring(3)));
        continue;
      }
      status.add(f);
      if (x == 'R' || x == 'C' || y == 'R' || y == 'C') i++; // the original path follows
    }
    status.sort();
    final directories = <String, String>{'.': _stat(root)};
    for (final e in Directory(root).listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory && name != '.git') directories[name] = _stat(e.path);
    }
    String? hash;
    if (mutatedFile != null) {
      final f = File(p.join(root, mutatedFile));
      hash = f.existsSync() ? sha256.convert(f.readAsBytesSync()).toString() : 'missing';
    }
    return ExportView(
      head: head,
      status: status,
      ignored: ignored,
      directories: directories,
      mutatedFile: mutatedFile,
      mutatedHash: hash,
    );
  }

  String _stat(String path) {
    final s = FileStat.statSync(path);
    return switch (s.type) {
      FileSystemEntityType.notFound => 'missing',
      FileSystemEntityType.directory => 'dir:${s.modified.microsecondsSinceEpoch}',
      _ => '${s.size}b:${s.modified.microsecondsSinceEpoch}',
    };
  }

  String _list(List<String> items) =>
      items.length <= 6 ? items.join(', ') : '${items.take(6).join(', ')} and ${items.length - 6} more';

  Future<String> _git(List<String> args, {bool trim = true}) async {
    final r = await Process.run('git', args, workingDirectory: root, environment: {'GIT_OPTIONAL_LOCKS': '0'});
    if (r.exitCode != 0) {
      throw ExportStateError('git ${args.first} failed in the export (exit ${r.exitCode}): ${(r.stderr as String).trim()}');
    }
    final text = r.stdout as String;
    return trim ? text.trim() : text;
  }
}
