import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'reporter_parser.dart';
import 'source_facts.dart';

/// A failing test that was not counted as a kill, and why.
class DiscountedFailure {
  const DiscountedFailure(this.key, this.reasons);
  final String key;

  /// Human-readable reasons, e.g. `matches guard pattern test/guards/**`.
  final List<String> reasons;
}

/// Globs (relative to the repository root) of the shared source scanners of
/// this repository family: helpers that strip comments and strings from source
/// text so a test can grep it (edge: `test/support/dart_source.dart`,
/// `test/support/dart_source_lexical.dart`).
const defaultScannerGlobs = ['**/dart_source*.dart'];

/// Decides, by reading the test files of an export, which suites scan source
/// text instead of running code.
///
/// A suite is source-scanning when it, or any Dart file it reaches in the
/// export (every URI of every import / export / part, conditional ones
/// included; relative, `package:<this package>/` as `lib/`, path dependencies
/// inside the export; helpers under `lib/` and the other source roots too):
///
/// - is one of the shared scanners ([scannerGlobs]), or
/// - contains a file-system read that may reach source: the file is parsed to
///   an AST and any `File` / `Directory` / `Link` whose path is not a
///   compile-time string outside the source roots, any read call on an
///   unknown receiver, `Platform.script`, or a literal path that starts at a
///   source root is a site (see [analyseSourceReads]). The reason names
///   file:line and the rule.
///
/// This is deliberately wide: a suite wrongly taken for a scanner only loses
/// kill credit, a scanner taken for runtime would inflate the score.
class SourceScanDetector {
  SourceScanDetector({
    required this.root,
    List<String> sourceRoots = const ['lib'],
    this.scannerGlobs = defaultScannerGlobs,
  }) : sourceRoots = [
          ...{...defaultSourceRoots, ...sourceRoots}
        ];

  final String root;

  /// Top-level directories whose text counts as source: [defaultSourceRoots]
  /// plus the directories of the files being mutated.
  final List<String> sourceRoots;
  final List<String> scannerGlobs;

  final Map<String, List<String>> _cache = {};
  final Map<String, _FileFacts?> _facts = {};
  late final List<Glob> _scanners = [for (final g in scannerGlobs) Glob(g, context: p.posix)];

  /// Reasons why [suite] (root-relative, `/`-separated) is source-scanning;
  /// empty when nothing says so.
  List<String> reasons(String suite) => _cache.putIfAbsent(suite, () => _analyse(suite));

  List<String> _analyse(String suite) {
    final start = _relative(suite);
    if (start == null || _factsOf(start) == null) {
      return ['the suite file $suite is not in the export; it cannot be checked'];
    }
    final out = <String>[];
    final queue = <(String, List<String>)>[(start, const [])];
    final seen = {start};
    while (queue.isNotEmpty) {
      final (path, via) = queue.removeAt(0);
      final facts = _factsOf(path);
      if (facts == null) continue;
      // `via`: the helpers between the suite and this file.
      final where = via.isEmpty ? '' : ' (via ${via.join(' -> ')})';
      final own = path == start;
      if (_scanners.any((g) => g.matches(path))) {
        out.add(own ? 'is a source scanner ($path)' : 'imports source scanner $path$where');
      }
      for (final site in facts.sites.take(_maxSites)) {
        out.add('may read source: ${site.describe(path)}${own ? '' : ' (helper reached via ${[start, ...via, path].join(' -> ')})'}');
      }
      if (facts.sites.length > _maxSites) {
        out.add('may read source: ${facts.sites.length - _maxSites} more sites in $path');
      }
      for (final next in facts.imports) {
        if (seen.add(next)) queue.add((next, own ? via : [...via, path]));
      }
    }
    return out;
  }

  /// [suite] as a path relative to [root], or null when it lies outside.
  String? _relative(String suite) {
    final abs = p.isAbsolute(suite) ? suite : p.join(root, suite);
    final rel = p.relative(p.normalize(abs), from: root);
    return rel.startsWith('..') || p.isAbsolute(rel) ? null : p.posix.joinAll(p.split(rel));
  }

  _FileFacts? _factsOf(String path) => _facts.putIfAbsent(path, () {
        final file = File(p.join(root, path));
        if (!file.existsSync()) return null;
        final facts = analyseSourceReads(file.readAsStringSync(), sourceRoots: sourceRoots);
        // Every URI of every directive, conditional ones included, whatever
        // lies behind it: location never proves a file does not read source.
        final imports = <String>[
          for (final uri in facts.uris)
            if (_resolve(path, uri) case final next?) next,
        ];
        // Strict everywhere, files under a source root included: a helper there
        // that builds a path at run time may read source whatever its callers
        // show. Runtime credit comes only from the reviewed allowlist.
        final sites = facts.sites;
        return _FileFacts(sites, imports);
      });

  /// The root-relative Dart file [uri] (written in [from]) names, if it is in
  /// the export: relative URIs, `package:<this package>/...` (-> lib/),
  /// `package:<path dependency inside the export>/...`. Other packages and
  /// `dart:` are not part of the repository.
  String? _resolve(String from, String uri) {
    String? next;
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final dir = _packages[rest.substring(0, slash)];
      if (dir == null) return null;
      next = _relative(p.join(dir, 'lib', rest.substring(slash + 1)));
    } else if (!uri.contains(':') || uri.startsWith('file:')) {
      next = _relative(p.join(p.dirname(from), uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri));
    }
    if (next == null || !next.endsWith('.dart')) return null;
    return File(p.join(root, next)).existsSync() ? next : null;
  }

  /// Package name -> directory (root-relative; `.` for the audited package)
  /// for the audited package and every path dependency that lies inside the
  /// export. Hosted and git packages are not in the export; a path dependency
  /// that points out of it is refused elsewhere (path overrides).
  late final Map<String, String> _packages = () {
    final out = <String, String>{};
    Object? load(String name) {
      final f = File(p.join(root, name));
      if (!f.existsSync()) return null;
      try {
        return loadYaml(f.readAsStringSync());
      } on YamlException {
        return null;
      }
    }

    final main = load('pubspec.yaml');
    if (main is YamlMap && main['name'] is String) out[main['name'] as String] = '.';
    for (final doc in [main, load('pubspec_overrides.yaml')]) {
      if (doc is! YamlMap) continue;
      for (final section in ['dependencies', 'dev_dependencies', 'dependency_overrides']) {
        final deps = doc[section];
        if (deps is! YamlMap) continue;
        for (final e in deps.entries) {
          final spec = e.value;
          final path = spec is YamlMap ? spec['path'] : null;
          if (e.key is! String || path is! String) continue;
          final rel = _relative(p.join(root, path));
          if (rel != null && rel.isNotEmpty) out.putIfAbsent(e.key as String, () => rel);
        }
      }
    }
    return out;
  }();
}

class _FileFacts {
  _FileFacts(this.sites, this.imports);
  final List<SourceSite> sites;
  final List<String> imports;
}

/// Sites shown per file in a reason; the rest are counted.
const _maxSites = 3;

/// One reviewed line of the runtime allowlist.
class AllowlistEntry {
  const AllowlistEntry(this.key, this.reason);

  /// `suite` or `suite::full test name`.
  final String key;

  /// Why this really runs code (mandatory).
  final String reason;

  String get suite => key.contains('::') ? key.substring(0, key.indexOf('::')) : key;
}

/// An allowlist entry that frees something the detector or a pattern flagged:
/// what the reviewer is overriding.
class AllowlistOverride {
  const AllowlistOverride(this.entry, this.reason, this.flags);
  final String entry, reason;

  /// The reasons the suite was flagged (patterns and detection).
  final List<String> flags;

  Map<String, Object?> toJson() => {'entry': entry, 'reason': reason, 'flags': flags};
}

/// The reviewed list of tests that run code although their suite looks like a
/// source scanner. See [parse].
class RuntimeAllowlist {
  const RuntimeAllowlist._(this.suites, this.tests, this.entries);
  const RuntimeAllowlist.empty() : this._(const {}, const {}, const []);

  /// Whole suites, and single tests (`suite::full name`).
  final Set<String> suites, tests;

  /// Every entry with its reason, in file order.
  final List<AllowlistEntry> entries;

  /// One entry per line, with a mandatory reason after `#`:
  /// `test/x_test.dart  # why it runs code` (every test of that suite) or
  /// `test/x_test.dart::group full test name  # why` (only that test). The
  /// reason starts at the first whitespace-`#`-whitespace, so a `#` inside a
  /// test name (`issue #12`) is part of the name. Blank lines and lines that
  /// start with `#` are ignored. A line without a reason is a
  /// [FormatException] naming the line.
  factory RuntimeAllowlist.parse(String text) {
    final suites = <String>{}, tests = <String>{};
    final entries = <AllowlistEntry>[];
    final lines = text.split('\n');
    for (var n = 0; n < lines.length; n++) {
      final line = lines[n].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final at = RegExp(r'\s#(?:\s|$)').firstMatch(line);
      final key = at == null ? line : line.substring(0, at.start).trim();
      final reason = at == null ? '' : line.substring(at.end).trim();
      if (reason.isEmpty) {
        throw FormatException(
            'runtime allowlist line ${n + 1}: "$key" has no reason; write "$key  # why this runs code"');
      }
      (key.contains('::') ? tests : suites).add(key);
      entries.add(AllowlistEntry(key, reason));
    }
    return RuntimeAllowlist._(suites, tests, entries);
  }

  int get length => suites.length + tests.length;

  /// The suite part of every entry (to check them against the export).
  Set<String> get suiteNames => {
        ...suites,
        for (final t in tests) t.substring(0, t.indexOf('::')),
      };

  bool allows(TestOutcome test) => suites.contains(test.suite) || tests.contains(test.key);
}

/// How source guards were decided in one run; goes into the report.
class GuardReport {
  const GuardReport({
    required this.policy,
    required this.patterns,
    required this.scannerGlobs,
    required this.sourceRoots,
    required this.effectiveSuites,
    required this.sourceScanning,
    this.allowlistPath,
    this.allowlistSha256,
    this.allowlistEntries = 0,
    this.allowlistUnknownSuites = const [],
    this.allowlistOverrides = const [],
    this.allowlistUnflagged = const [],
  });

  /// `detected` (patterns plus automatic detection) or `no-guards-asserted`
  /// (`--no-guards`, accepted because nothing was detected).
  final String policy;
  final List<String> patterns, scannerGlobs, sourceRoots;

  /// Every suite the run covers (root-relative).
  final List<String> effectiveSuites;

  /// Suite -> reasons, for the effective suites that are source-scanning.
  final Map<String, List<String>> sourceScanning;
  final String? allowlistPath, allowlistSha256;
  final int allowlistEntries;

  /// Allowlist entries naming a suite that is not in the export.
  final List<String> allowlistUnknownSuites;

  /// Entries that override a flag, with the flag reasons and the reviewer's reason.
  final List<AllowlistOverride> allowlistOverrides;

  /// Entries whose suite nothing flagged (they free nothing).
  final List<String> allowlistUnflagged;

  Map<String, Object?> toJson() => {
        'policy': policy,
        'patterns': patterns,
        'scannerGlobs': scannerGlobs,
        'sourceRoots': sourceRoots,
        'effectiveSuites': effectiveSuites.length,
        'sourceScanningSuites': sourceScanning.length,
        'sourceScanning': [
          for (final e in sourceScanning.entries) {'suite': e.key, 'reasons': e.value}
        ],
        'allowlist': allowlistPath == null
            ? null
            : {
                'path': allowlistPath,
                'sha256': allowlistSha256,
                'entries': allowlistEntries,
                'unknownSuites': allowlistUnknownSuites,
                'overrides': [for (final o in allowlistOverrides) o.toJson()],
                'unflagged': allowlistUnflagged,
              },
      };
}

/// The `*_test.dart` files under [root] named by [selectors] (files,
/// directories, globs; default `test`), root-relative with `/`, sorted.
///
/// A selector that names nothing is a [FormatException]: a typo must not
/// silently shrink the effective suite set. `test` (or no selector) is the
/// whole suite.
List<String> expandTestSelectors(String root, List<String> selectors) {
  final all = <String>[];
  void walk(Directory dir, String prefix) {
    for (final e in dir.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (e is Directory) {
        if (name == '.git' || name == '.dart_tool' || name.startsWith('.')) continue;
        walk(e, rel);
      } else if (e is File && name.endsWith('_test.dart')) {
        all.add(rel);
      }
    }
  }

  walk(Directory(root), '');
  final out = <String>{};
  for (final selector in selectors.isEmpty ? const ['test'] : selectors) {
    final abs = p.normalize(p.isAbsolute(selector) ? selector : p.join(root, selector));
    final rel = p.relative(abs, from: root);
    final inside = !rel.startsWith('..') && !p.isAbsolute(rel);
    final posix = !inside ? null : (rel == '.' ? '' : p.posix.joinAll(p.split(rel)));
    if (posix != null && FileSystemEntity.isDirectorySync(abs)) {
      final hits = all.where((f) => posix.isEmpty || f.startsWith('$posix/')).toList();
      if (hits.isEmpty) throw FormatException('no *_test.dart file under', selector);
      out.addAll(hits);
    } else if (posix != null && FileSystemEntity.isFileSync(abs)) {
      out.add(posix);
    } else {
      final glob = Glob(selector, context: p.posix);
      final hits = all.where(glob.matches).toList();
      if (hits.isEmpty) throw FormatException('no test file matches', selector);
      out.addAll(hits);
    }
  }
  return out.toList()..sort();
}
