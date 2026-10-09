import 'dart:convert';
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
        final imports = <String>[];
        // Strict everywhere, files under a source root included: a helper there
        // that builds a path at run time may read source whatever its callers
        // show. Runtime credit comes only from the reviewed allowlist.
        final sites = [...facts.sites];
        for (final uri in facts.uris) {
          final r = _resolve(path, uri);
          if (r.mapping != null) {
            sites.add(SourceSite(facts.uriLines[uri] ?? 1, 'package-mapping',
                "'$uri': ${r.mapping}; which directory it runs is unknown"));
          }
          if (r.file != null) imports.add(r.file!);
          if (r.missing != null) {
            // A file that is not there is a file nobody read: it could be a
            // scanner. (Detection runs after setup, so a generated helper is
            // there by now; what is missing then is missing for good.)
            sites.add(SourceSite(facts.uriLines[uri] ?? 1, 'unresolved-import',
                "'$uri' names a file that is not in the export (${r.missing}); what it does is unknown"));
          }
        }
        return _FileFacts(sites, imports);
      });

  /// What [uri] (written in [from]) names: the root-relative Dart file when it
  /// is in the export (relative URIs, `package:<this package>/...` and the
  /// packages the pubspecs and the package config place inside the export), or
  /// `missing` with the reason when it should be there and is not (the file is
  /// absent, or lies outside the export). `dart:`, other packages (hosted, git,
  /// outside the export) and other schemes are not part of the repository:
  /// both fields null.
  ({String? file, String? missing, String? mapping}) _resolve(String from, String uri) {
    const ignored = (file: null, missing: null, mapping: null);
    String? next;
    if (uri.startsWith('dart:')) return ignored;
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return ignored;
      final name = rest.substring(0, slash);
      final broken = _packages.broken[name];
      if (broken != null) return (file: null, missing: null, mapping: broken);
      final dir = _packages.lib[name];
      if (dir == null) return ignored;
      next = _relative(p.join(dir, rest.substring(slash + 1)));
    } else if (!uri.contains(':') || uri.startsWith('file:')) {
      next = _relative(p.join(p.dirname(from), uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri));
      if (next == null) return (file: null, missing: 'it lies outside the export', mapping: null);
    } else {
      return ignored;
    }
    if (next == null) return (file: null, missing: 'it lies outside the export', mapping: null);
    if (!next.endsWith('.dart')) return ignored;
    return File(p.join(root, next)).existsSync()
        ? (file: next, missing: null, mapping: null)
        : (file: null, missing: 'no such file', mapping: null);
  }

  /// Which directory each package of the export runs from.
  ///
  /// The resolved `.dart_tool/package_config.json` (setup writes it, and it is
  /// what the compiler uses) is AUTHORITATIVE: a package it maps to a place
  /// inside the export is read from there (`rootUri` + `packageUri`), whatever
  /// the pubspec suggests. The pubspecs only say which packages are EXPECTED to
  /// be in the export (the audited package and the path dependencies inside
  /// it, pubspec.yaml and pubspec_overrides.yaml). An expected package the
  /// config cannot map (no config, an unreadable one, no entry, two entries that
  /// disagree, a root that is not a file location) is `broken`: importing it is
  /// scanning evidence (`package-mapping`), because there is no way to tell
  /// what code it runs. Packages the config places outside the export, and
  /// packages nothing says are ours, are not part of the repository.
  late final _PackageMap _packages = () {
    Object? load(String name) {
      final f = File(p.join(root, name));
      if (!f.existsSync()) return null;
      try {
        return loadYaml(f.readAsStringSync());
      } on YamlException {
        return null;
      }
    }

    final expected = <String>{};
    final main = load('pubspec.yaml');
    if (main is YamlMap && main['name'] is String) expected.add(main['name'] as String);
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
          if (rel != null && rel.isNotEmpty) expected.add(e.key as String);
        }
      }
    }

    final lib = <String, String>{};
    final broken = <String, String>{};
    final configFile = File(p.join(root, '.dart_tool', 'package_config.json'));
    Object? config;
    String? configProblem;
    if (!configFile.existsSync()) {
      configProblem = 'there is no .dart_tool/package_config.json (setup did not write one)';
    } else {
      try {
        config = jsonDecode(configFile.readAsStringSync());
      } on FormatException {
        configProblem = '.dart_tool/package_config.json is not valid JSON';
      }
      if (configProblem == null && !(config is Map && config['packages'] is List)) {
        configProblem = '.dart_tool/package_config.json has no packages list';
      }
    }
    if (configProblem != null) {
      return _PackageMap(lib, {for (final n in expected) n: 'package:$n cannot be mapped to a directory: $configProblem'});
    }
    final seen = <String, String?>{}; // name -> the directory its first entry gave (null: outside the export)
    final base = Uri.directory(p.join(root, '.dart_tool'));
    for (final pkg in (config as Map)['packages'] as List) {
      final name = pkg is Map ? pkg['name'] : null;
      if (name is! String) continue;
      String? dir; // root-relative package directory, null outside the export
      var problem = '';
      final rootUri = pkg['rootUri'];
      if (rootUri is! String) {
        problem = 'its entry has no rootUri';
      } else {
        try {
          final rootDir = base.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
          if (rootDir.scheme != 'file') {
            problem = 'its rootUri ($rootUri) is not a file location';
          } else {
            final packageUri = pkg['packageUri'];
            final full = rootDir.resolve(packageUri is String ? (packageUri.endsWith('/') ? packageUri : '$packageUri/') : 'lib/');
            dir = _relative(p.normalize(full.toFilePath()));
          }
        } on FormatException {
          problem = 'its rootUri ($rootUri) cannot be parsed';
        }
      }
      if (problem.isNotEmpty) {
        broken[name] = 'package:$name cannot be mapped to a directory: $problem';
        continue;
      }
      if (seen.containsKey(name) && seen[name] != dir) {
        broken[name] = 'package:$name cannot be mapped to a directory: package_config.json lists it twice with different roots';
      }
      seen.putIfAbsent(name, () => dir);
      if (dir != null) lib[name] = dir;
    }
    for (final n in expected) {
      if (!seen.containsKey(n) && !broken.containsKey(n)) {
        broken[n] = 'package:$n cannot be mapped to a directory: package_config.json does not list it';
      }
    }
    for (final n in broken.keys) {
      lib.remove(n);
    }
    return _PackageMap(lib, broken);
  }();
}

/// Package name -> root-relative directory (the `packageUri` one) for packages
/// inside the export, and the packages that cannot be mapped, with the reason.
class _PackageMap {
  _PackageMap(this.lib, this.broken);
  final Map<String, String> lib;
  final Map<String, String> broken;
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
