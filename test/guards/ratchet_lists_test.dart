// ratchet_lists_test.dart — every improvement list may only shrink (owner rule B).
//
// Registry + counting: support/ratchets.dart. The registry names every baseline
// / allow-list / exception map; this test compares each list's counts at HEAD
// with the same list at the target branch, and fails if any count grew. A list
// added to the registry is fine; one removed from it fails.
//
// CI passes the target branch the way heavy_baseline_test.dart does:
//
//   git fetch --no-tags --depth=1 origin "$GITHUB_BASE_REF"
//   RATCHET_BASE="origin/$GITHUB_BASE_REF" flutter test \
//       test/guards/ratchet_lists_test.dart
//
// With RATCHET_BASE unset the comparison against the target branch is skipped
// (like HEAVY_BASELINE_BASE) and HEAD is compared with the checked-in snapshot
// test/guards/ratchet_counts.json instead. To record a shrink, regenerate the
// snapshot: it is the one file whose diff shows what a PR spent or saved.
//
// Red today: ratchet_counts.json does not exist and the counting is a stub.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/ratchets.dart';

const _snapshotPath = 'test/guards/ratchet_counts.json';

void main() {
  group('counting each kind', () {
    test('heavyBaselineJson: entries and total occurrences', () {
      const list = RatchetList(
          'h', 'b.json', RatchetKind.heavyBaselineJson);
      final counts = countRatchet(
        list,
        jsonEncode({
          'version': 2,
          'occurrences': [
            {'rule': 'r', 'file': 'a', 'symbol': 's', 'element': 'e', 'count': 2},
            {'rule': 'r', 'file': 'b', 'symbol': 's', 'element': 'e', 'count': 3},
          ],
        }),
      );
      expect(counts['entries'], 2);
      expect(counts['occurrences'], 5);
    });

    test('heavyBaselineJson: an empty baseline is 0 / 0', () {
      const list = RatchetList('h', 'b.json', RatchetKind.heavyBaselineJson);
      final counts =
          countRatchet(list, jsonEncode({'version': 2, 'occurrences': []}));
      expect(counts['entries'], 0);
      expect(counts['occurrences'], 0);
    });

    test('sizeMapJson: entries and one size:<path> per file', () {
      const list = RatchetList('s', 'e.json', RatchetKind.sizeMapJson);
      final counts = countRatchet(
        list,
        jsonEncode({'lib/a.dart': 6100, 'lib/b.dart': 7000}),
      );
      expect(counts['entries'], 2);
      expect(counts['size:lib/a.dart'], 6100);
      expect(counts['size:lib/b.dart'], 7000);
    });

    test('malformed JSON fails loudly and names the list', () {
      const list = RatchetList('my_list', 'e.json', RatchetKind.sizeMapJson);
      expect(
        () => countRatchet(list, '{not json'),
        throwsA(anyOf(isA<FormatException>(),
            isA<StateError>().having((e) => e.message, 'm', contains('my_list')))),
      );
    });

    group('dartLiteral', () {
      RatchetList of(String symbol, {String? sum}) => RatchetList(
            'd',
            'x.dart',
            RatchetKind.dartLiteral,
            symbol: symbol,
            sumField: sum,
          );

      int entries(String source, String symbol) =>
          countRatchet(of(symbol), source)['entries']!;

      test('a set, a list and a map each count their elements', () {
        const src = "const _set = {'x', 'y'};\n"
            "const _list = ['a', 'b', 'c'];\n"
            "const _map = <String, int>{'a': 1, 'b': 2};\n";
        expect(entries(src, '_set'), 2);
        expect(entries(src, '_list'), 3);
        expect(entries(src, '_map'), 2);
      });

      test('trailing comma or not, the count is the same', () {
        expect(entries("const _a = {'x', 'y',};", '_a'), 2);
        expect(entries("const _a = {'x', 'y'};", '_a'), 2);
        expect(entries('const _a = {\n  1,\n  2,\n  3,\n};', '_a'), 3);
      });

      test('an empty literal is 0', () {
        expect(entries('const List<Foo> kNone = <Foo>[];', 'kNone'), 0);
        expect(entries('const _m = <String, String>{};', '_m'), 0);
        expect(entries('const _m = {\n  // nothing yet\n};', '_m'), 0);
      });

      test('commas, braces and // inside strings do not split or close', () {
        const src = "const _b = <String, String>{\n"
            "  'k1': 'has, comma and } brace and ] bracket',\n"
            "  'k2': \"it's // not a comment, nor /* this\",\n"
            "  'k3': r'raw \\ , } ',\n"
            "};\n";
        expect(entries(src, '_b'), 3);
      });

      test('adjacent string literals are one value', () {
        const src = "const _b = <String, String>{\n"
            "  'k1': 'first, '\n"
            "      'second, '\n"
            "      'third',\n"
            "  'k2': 'x',\n"
            "};\n";
        expect(entries(src, '_b'), 2);
      });

      test('triple-quoted strings (with commas and quotes) are one value', () {
        const src = "const _b = <String, String>{\n"
            "  'k1': '''a, b\n"
            "it's, \"quoted\", } here\n"
            "''',\n"
            "  'k2': 'x',\n"
            "};\n";
        expect(entries(src, '_b'), 2);
      });

      test('commented-out entries do not count', () {
        const src = "const _b = {\n"
            "  'a': 1,\n"
            "  // 'b': 2,\n"
            "  /* 'c': 3,\n     'd': 4, */\n"
            "  'e': 5, // trailing, with a comma\n"
            "};\n";
        expect(entries(src, '_b'), 2);
      });

      test('constructor-call and nested-collection elements count once', () {
        const src = 'const List<Foo> kFoo = <Foo>[\n'
            "  Foo(a: 1, b: [1, 2, 3], c: {'k': 'v, w'}),\n"
            '  Foo(\n    a: 2,\n    b: [],\n  ),\n'
            '  Foo(a: 3),\n'
            '];\n';
        expect(entries(src, 'kFoo'), 3);
      });

      test('record values are one entry each, whatever is inside', () {
        const src = 'const Map<String, ({int count, String why})> _r = {\n'
            "  'f': (count: 3, why: 'a, b'),\n"
            "  'g': (\n    count: 4,\n    why: 'c',\n  ),\n"
            '};\n';
        expect(entries(src, '_r'), 2);
      });

      test('type arguments after = are skipped, even with record types', () {
        const src = 'const _g = <String, ({int count, String why})>{\n'
            "  'a': (count: 1, why: 'x'),\n"
            "  'b': (count: 2, why: 'y'),\n"
            '};\n';
        expect(entries(src, '_g'), 2);
        const nested = 'const _n = <String, Map<String, Set<String>>>{\n'
            "  'a': {'b': {'c'}},\n"
            '};\n';
        expect(entries(nested, '_n'), 1);
      });

      test('a name that is a prefix of another is not confused with it', () {
        const src = "final _allowedKeys = {'one'};\n"
            "final _allowed = {'a', 'b', 'c', 'd'};\n"
            "bool ok(String s) => _allowed.contains(s) || _allowedKeys.isEmpty;\n";
        expect(entries(src, '_allowed'), 4);
        expect(entries(src, '_allowedKeys'), 1);
      });

      test('the declaration counts, not a later use of the name', () {
        const src = 'bool ok(String s) => _allow.contains(s);\n'
            "const _allow = {'x', 'y'};\n";
        expect(entries(src, '_allow'), 2);
      });

      test('sumField adds a named integer field over record values', () {
        const src = 'const Map<String, ({int count, String why})> _r = {\n'
            "  'f': (count: 3, why: 'count: 99, not this'),\n"
            "  'g': (count: 4, why: 'c'),\n"
            '};\n';
        final counts = countRatchet(of('_r', sum: 'count'), src);
        expect(counts['entries'], 2);
        expect(counts['sum'], 7);
      });

      test('a symbol that is not in the file fails loudly', () {
        expect(
          () => countRatchet(of('_missing'), "const _other = {'x'};"),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('_missing'))),
        );
      });
    });

    group('dartLiteralNested', () {
      const list = RatchetList(
        'n',
        'x.dart',
        RatchetKind.dartLiteralNested,
        symbol: '_allowed',
      );

      test('entries are the tables, leaves are the members across them', () {
        const src = 'const _allowed = <String, Map<String, Set<String>>>{\n'
            "  'day_result': {\n"
            "    'LocalDb.putDayResult': {'insert'},\n"
            '    // Upstream\'s, kept by the merge.\n'
            "    'LocalDb._open': {'insert', 'update'},\n"
            "    'LocalDb.deleteDays': {'delete'},\n"
            '  },\n'
            "  'baselines': {\n"
            "    'LocalDb.putBaselines': {'insert'},\n"
            '  },\n'
            '};\n';
        final counts = countRatchet(list, src);
        expect(counts['entries'], 2);
        expect(counts['leaves'], 4);
      });

      test('an empty nested map has no leaves', () {
        final counts = countRatchet(
          list,
          "const _allowed = <String, Map<String, int>>{'t': {}};",
        );
        expect(counts['entries'], 1);
        expect(counts['leaves'], 0);
      });
    });

    group('dartRegexAlternatives', () {
      const list = RatchetList(
        'r',
        'x.dart',
        RatchetKind.dartRegexAlternatives,
        symbol: '_sliceEntry',
      );

      test('adjacent raw strings joined with | are the alternatives', () {
        const src = 'final _sliceEntry = RegExp(\n'
            '    r"^\\s*\'spectral_archive\': \\(SliceKeep\\.none, null, |"\n'
            '    r"^\\s*\'spectral_archive_status\': \\(SliceKeep\\.all, null, ");\n';
        expect(countRatchet(list, src)['entries'], 2);
      });

      test('a | inside a group, a class or an escape is not an alternative',
          () {
        expect(
          countRatchet(list, r"final _sliceEntry = RegExp(r'^(?:a|b)$|c');")['entries'],
          2,
        );
        expect(
          countRatchet(list, r"final _sliceEntry = RegExp(r'[|]x|\|y|z');")['entries'],
          3,
        );
      });

      test('a single pattern is one alternative', () {
        expect(
          countRatchet(list, r"final _sliceEntry = RegExp(r'abc');")['entries'],
          1,
        );
      });
    });
  });

  group('growth and shrink between two snapshots of counts', () {
    Map<String, Map<String, int>> counts(Map<String, Map<String, int>> m) => m;

    final base = counts({
      'heavy': {'entries': 10, 'occurrences': 20},
      'sizes': {'entries': 2, 'size:lib/a.dart': 7000, 'size:lib/b.dart': 6500},
      'allow': {'entries': 3},
    });

    test('equal counts pass', () {
      expect(ratchetGrowth(base: base, head: base), isEmpty);
    });

    test('a lower count in any key passes', () {
      final head = counts({
        'heavy': {'entries': 9, 'occurrences': 12},
        'sizes': {'entries': 1, 'size:lib/a.dart': 6800},
        'allow': {'entries': 0},
      });
      expect(ratchetGrowth(base: base, head: head), isEmpty);
    });

    test('entries growing fails and names the list and the key', () {
      final head = counts({
        'heavy': {'entries': 11, 'occurrences': 20},
        'sizes': base['sizes']!,
        'allow': base['allow']!,
      });
      final reasons = ratchetGrowth(base: base, head: head);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('heavy'));
      expect(reasons.single, contains('entries'));
    });

    test('total occurrences growing fails even when entries fell', () {
      final head = counts({
        'heavy': {'entries': 5, 'occurrences': 21},
        'sizes': base['sizes']!,
        'allow': base['allow']!,
      });
      final reasons = ratchetGrowth(base: base, head: head);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('occurrences'));
    });

    test('a recorded size going up fails; going down passes', () {
      final up = counts({
        'heavy': base['heavy']!,
        'sizes': {'entries': 2, 'size:lib/a.dart': 7001, 'size:lib/b.dart': 6000},
        'allow': base['allow']!,
      });
      final reasons = ratchetGrowth(base: base, head: up);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('size:lib/a.dart'));

      final down = counts({
        'heavy': base['heavy']!,
        'sizes': {'entries': 2, 'size:lib/a.dart': 6100, 'size:lib/b.dart': 6400},
        'allow': base['allow']!,
      });
      expect(ratchetGrowth(base: base, head: down), isEmpty);
    });

    test('a path newly listed in the size map fails (a new key is growth)', () {
      final head = counts({
        'heavy': base['heavy']!,
        'sizes': {
          'entries': 3,
          'size:lib/a.dart': 7000,
          'size:lib/b.dart': 6500,
          'size:lib/c.dart': 6001,
        },
        'allow': base['allow']!,
      });
      final reasons = ratchetGrowth(base: base, head: head);
      expect(reasons.join('\n'), contains('size:lib/c.dart'));
      expect(reasons.join('\n'), contains('entries'));
    });

    test('a list that is new in head is fine', () {
      final head = counts({
        ...base,
        'brand_new': {'entries': 40},
      });
      expect(ratchetGrowth(base: base, head: head), isEmpty);
    });

    test('a count key that vanished from head is a shrink', () {
      final head = counts({
        'heavy': {'entries': 10},
        'sizes': base['sizes']!,
        'allow': base['allow']!,
      });
      expect(ratchetGrowth(base: base, head: head), isEmpty);
    });

    test('a key head has and base lacks reads as 0 in base', () {
      final reasons = ratchetGrowth(
        base: {'allow': {'entries': 3}},
        head: {'allow': {'entries': 3, 'sum': 1}},
      );
      expect(reasons.single, contains('sum'));
      expect(
        ratchetGrowth(
          base: {'allow': {'entries': 3}},
          head: {'allow': {'entries': 3, 'sum': 0}},
        ),
        isEmpty,
      );
    });

    test('every growing list is reported, not just the first', () {
      final head = counts({
        'heavy': {'entries': 11, 'occurrences': 21},
        'sizes': base['sizes']!,
        'allow': {'entries': 4},
      });
      expect(ratchetGrowth(base: base, head: head), hasLength(3));
    });
  });

  group('unregistering a list is not an escape', () {
    test('a base id missing from head fails and names it', () {
      final reasons = unregisteredRatchets(
        baseIds: ['heavy_calc_baseline', 'p24_from_json_callers'],
        headIds: ['heavy_calc_baseline'],
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('p24_from_json_callers'));
    });

    test('the same ids, or extra ids in head, pass', () {
      expect(
        unregisteredRatchets(baseIds: ['a', 'b'], headIds: ['b', 'a']),
        isEmpty,
      );
      expect(
        unregisteredRatchets(baseIds: ['a'], headIds: ['a', 'b', 'c']),
        isEmpty,
      );
    });
  });

  group('snapshot file format', () {
    test('encode then parse round-trips', () {
      final counts = {
        'heavy_calc_baseline': {'entries': 1986, 'occurrences': 2190},
        'file_size_exceptions': {'entries': 2, 'size:lib/data/db.dart': 11039},
      };
      expect(parseRatchetSnapshot(encodeRatchetSnapshot(counts)), counts);
    });

    test('the encoding is stable (sorted) so diffs stay reviewable', () {
      final a = encodeRatchetSnapshot({
        'b': {'entries': 1},
        'a': {'z': 1, 'y': 2},
      });
      final b = encodeRatchetSnapshot({
        'a': {'y': 2, 'z': 1},
        'b': {'entries': 1},
      });
      expect(a, b);
    });

    test('an unknown format version is rejected, not guessed at', () {
      expect(
        () => parseRatchetSnapshot('{"version": 99, "lists": {}}'),
        throwsFormatException,
      );
    });
  });

  group('end to end: head dir vs base dir, one list per kind', () {
    late Directory baseDir;
    late Directory headDir;

    setUp(() {
      baseDir = Directory.systemTemp.createTempSync('ratchet_base_');
      headDir = Directory.systemTemp.createTempSync('ratchet_head_');
    });
    tearDown(() {
      baseDir.deleteSync(recursive: true);
      headDir.deleteSync(recursive: true);
    });

    void write(Directory d, String rel, String text) => File('${d.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);

    Future<List<String>> growth(
      RatchetList list, {
      required String base,
      required String head,
    }) async {
      write(baseDir, list.file, base);
      write(headDir, list.file, head);
      final b = await countRatchets(dirReader(baseDir.path),
          lists: [list], missingIsError: false);
      final h = await countRatchets(dirReader(headDir.path), lists: [list]);
      return ratchetGrowth(base: b, head: h);
    }

    String heavy(int entries, int each) => jsonEncode({
          'version': 2,
          'occurrences': [
            for (var i = 0; i < entries; i++)
              {
                'rule': 'r',
                'file': 'f$i',
                'symbol': 's',
                'element': 'e',
                'count': each,
              },
          ],
        });

    test('heavyBaselineJson', () async {
      const list =
          RatchetList('heavy', 'g/heavy.json', RatchetKind.heavyBaselineJson);
      expect(await growth(list, base: heavy(3, 2), head: heavy(4, 2)), isNotEmpty);
      expect(await growth(list, base: heavy(3, 2), head: heavy(3, 3)), isNotEmpty);
      expect(await growth(list, base: heavy(3, 2), head: heavy(3, 2)), isEmpty);
      expect(await growth(list, base: heavy(3, 2), head: heavy(2, 2)), isEmpty);
    });

    test('sizeMapJson', () async {
      const list = RatchetList('sizes', 'g/sizes.json', RatchetKind.sizeMapJson);
      String sizes(Map<String, int> m) => jsonEncode(m);
      expect(
        await growth(list,
            base: sizes({'lib/a.dart': 7000}),
            head: sizes({'lib/a.dart': 7000, 'lib/b.dart': 6100})),
        isNotEmpty,
      );
      expect(
        await growth(list,
            base: sizes({'lib/a.dart': 7000}), head: sizes({'lib/a.dart': 7100})),
        isNotEmpty,
      );
      expect(
        await growth(list,
            base: sizes({'lib/a.dart': 7000}), head: sizes({'lib/a.dart': 6900})),
        isEmpty,
      );
      expect(await growth(list, base: sizes({'lib/a.dart': 7000}), head: '{}'),
          isEmpty);
    });

    test('dartLiteral (entries, and the summed field)', () async {
      const list = RatchetList('callers', 'g/callers.dart', RatchetKind.dartLiteral,
          symbol: '_callers', sumField: 'count');
      String src(List<int> counts) => 'const _callers = <String, ({int count})>{\n'
          '${[for (var i = 0; i < counts.length; i++) "  'f$i': (count: ${counts[i]}),"].join('\n')}\n'
          '};\n';
      expect(await growth(list, base: src([1, 2]), head: src([1, 2, 1])),
          isNotEmpty);
      expect(await growth(list, base: src([1, 2]), head: src([1, 5])),
          isNotEmpty,
          reason: 'same entries, larger summed field');
      expect(await growth(list, base: src([1, 2]), head: src([1, 2])), isEmpty);
      expect(await growth(list, base: src([1, 2]), head: src([1, 1])), isEmpty);
      expect(await growth(list, base: src([1, 2]), head: src([2])), isEmpty);
    });

    test('dartLiteralNested', () async {
      const list = RatchetList('nested', 'g/nested.dart',
          RatchetKind.dartLiteralNested,
          symbol: '_w');
      String src(Map<String, int> members) =>
          'const _w = <String, Map<String, int>>{\n'
          '${members.entries.map((e) => "  '${e.key}': {${List.generate(e.value, (i) => "'m$i': 1").join(', ')}},").join('\n')}\n'
          '};\n';
      expect(await growth(list, base: src({'t': 2}), head: src({'t': 3})),
          isNotEmpty,
          reason: 'a member added under an existing table');
      expect(await growth(list, base: src({'t': 2}), head: src({'t': 2, 'u': 1})),
          isNotEmpty);
      expect(await growth(list, base: src({'t': 2}), head: src({'t': 2})), isEmpty);
      expect(await growth(list, base: src({'t': 2}), head: src({'t': 1})), isEmpty);
    });

    test('dartRegexAlternatives', () async {
      const list = RatchetList('rx', 'g/rx.dart',
          RatchetKind.dartRegexAlternatives,
          symbol: '_rx');
      String src(String p) => "final _rx = RegExp(r'$p');\n";
      expect(await growth(list, base: src('a|b'), head: src('a|b|c')), isNotEmpty);
      expect(await growth(list, base: src('a|b'), head: src('a|b')), isEmpty);
      expect(await growth(list, base: src('a|b'), head: src('a')), isEmpty);
    });

    test('a list whose file is absent at base was introduced: not growth',
        () async {
      const list = RatchetList('new_one', 'g/new.dart', RatchetKind.dartLiteral,
          symbol: '_x');
      write(headDir, list.file, "const _x = {'a', 'b'};");
      final b = await countRatchets(dirReader(baseDir.path),
          lists: [list], missingIsError: false);
      expect(b, isEmpty);
      final h = await countRatchets(dirReader(headDir.path), lists: [list]);
      expect(ratchetGrowth(base: b, head: h), isEmpty);
    });

    test('a registered file missing at HEAD is an error naming the list',
        () async {
      const list = RatchetList('gone', 'g/gone.dart', RatchetKind.dartLiteral,
          symbol: '_x');
      expect(
        () => countRatchets(dirReader(headDir.path), lists: [list]),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('gone'))),
      );
    });
  });

  group('reading the target branch (git show <ref>:path)', () {
    late Directory repo;

    Future<ProcessResult> git(List<String> args) => Process.run(
          'git',
          ['-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args],
          workingDirectory: repo.path,
        );

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('ratchet_git_');
      await git(['init', '-q', '-b', 'main']);
    });
    tearDown(() => repo.delete(recursive: true));

    test('returns the file as committed at the ref, not the work tree',
        () async {
      final f = File('${repo.path}/lists/a.dart')..createSync(recursive: true);
      f.writeAsStringSync("const _x = {'a', 'b', 'c'};");
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      f.writeAsStringSync("const _x = {'a'};");

      final read = gitRefReader('main', repoDir: repo.path);
      expect(await read('lists/a.dart'), "const _x = {'a', 'b', 'c'};");
    });

    test('a file absent at the ref reads as null (introduced by the change)',
        () async {
      File('${repo.path}/README').writeAsStringSync('x');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      expect(await gitRefReader('main', repoDir: repo.path)('lists/a.dart'),
          isNull);
    });

    test('an unknown ref fails loudly instead of skipping the check',
        () async {
      File('${repo.path}/README').writeAsStringSync('x');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      expect(
        () => gitRefReader('no-such-ref', repoDir: repo.path)('README'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('no-such-ref'))),
      );
    });

    test('counts through the ref reader match counts through a dir reader',
        () async {
      const list = RatchetList('x', 'lists/a.dart', RatchetKind.dartLiteral,
          symbol: '_x');
      File('${repo.path}/lists/a.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync("const _x = {'a', 'b', 'c'};");
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      final viaGit = await countRatchets(
          gitRefReader('main', repoDir: repo.path),
          lists: [list]);
      final viaDir = await countRatchets(dirReader(repo.path), lists: [list]);
      expect(viaGit, viaDir);
      expect(viaGit['x']!['entries'], 3);
    });
  });

  group('the real lists (HEAD)', () {
    test('ids are unique and every registered file exists', () {
      final ids = kRatchets.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      for (final r in kRatchets) {
        if (r.file == 'test/guards/file_size_exceptions.json') continue;
        expect(File(r.file).existsSync(), isTrue, reason: '${r.id}: ${r.file}');
      }
    });

    test('every owner-named list is registered', () {
      bool has(String file, [String? symbol]) => kRatchets
          .any((r) => r.file == file && (symbol == null || r.symbol == symbol));
      expect(has('test/guards/heavy_calc_baseline.json'), isTrue);
      expect(has('test/guards/file_size_exceptions.json'), isTrue);
      expect(has('lib/util/worker_entries.dart', 'kUnresolvedOk'), isTrue);
      const p21 = 'test/step2/p21_write_seam_guard_test.dart';
      expect(has(p21, '_pinnedDynamicWriters'), isTrue);
      expect(has(p21, '_pinnedTableLists'), isTrue);
      expect(has('test/step2/p24_call_sites_test.dart', '_fromJsonCallers'),
          isTrue);
      expect(has('test/ecg_gesture_consumer_guard_test.dart', '_allow'), isTrue);
      expect(has('test/observation_isolation_test.dart'), isTrue);
      expect(has('test/sample_archive/sample_guard_test.dart'), isTrue);
    });

    test('every registered list can be counted at HEAD', () async {
      final counts = await countRatchets(dirReader('.'));
      expect(counts.keys.toSet(), kRatchets.map((r) => r.id).toSet());
      for (final e in counts.entries) {
        expect(e.value['entries'], isNotNull, reason: e.key);
      }
    });

    test('the heavy baseline is counted the way the heavy guard reads it',
        () async {
      final counts = await countRatchets(dirReader('.'),
          lists: kRatchets.where((r) => r.id == 'heavy_calc_baseline'));
      final raw = jsonDecode(
              File('test/guards/heavy_calc_baseline.json').readAsStringSync())
          as Map<String, dynamic>;
      final occ = (raw['occurrences'] as List).cast<Map<String, dynamic>>();
      expect(counts['heavy_calc_baseline']!['entries'], occ.length);
      expect(counts['heavy_calc_baseline']!['occurrences'],
          occ.fold<int>(0, (s, o) => s + (o['count'] as int)));
    });
  });

  group('HEAD vs the checked-in snapshot (used when RATCHET_BASE is unset)',
      () {
    test('ratchet_counts.json exists and has exactly the registered ids', () {
      expect(File(_snapshotPath).existsSync(), isTrue,
          reason: '$_snapshotPath records every list\'s counts; regenerate it '
              'with encodeRatchetSnapshot(await countRatchets(dirReader(".")))');
      final snap = parseRatchetSnapshot(File(_snapshotPath).readAsStringSync());
      expect(
        unregisteredRatchets(baseIds: snap.keys, headIds: kRatchets.map((r) => r.id)),
        isEmpty,
        reason: 'a list in the snapshot was removed from the registry',
      );
      expect(
        kRatchets.map((r) => r.id).toSet().difference(snap.keys.toSet()),
        isEmpty,
        reason: 'a registered list is missing from the snapshot',
      );
    });

    test('no list grew past the snapshot', () async {
      final snap = parseRatchetSnapshot(File(_snapshotPath).readAsStringSync());
      final head = await countRatchets(dirReader('.'));
      expect(ratchetGrowth(base: snap, head: head), isEmpty);
    });
  });

  group('HEAD vs the target branch', () {
    final baseRef = Platform.environment['RATCHET_BASE'];
    final skip = baseRef == null || baseRef.isEmpty
        ? 'set RATCHET_BASE to the target branch ref (CI does)'
        : false;

    test('no list grew since the target branch', () async {
      final base = await countRatchets(
        gitRefReader(baseRef!, repoDir: Directory.current.path),
        missingIsError: false,
      );
      final head = await countRatchets(dirReader('.'));
      expect(ratchetGrowth(base: base, head: head), isEmpty);
    }, skip: skip);

    test('no list was dropped from the registry since the target branch',
        () async {
      final snapText = await gitRefReader(baseRef!, repoDir: Directory.current.path)(
          _snapshotPath);
      if (snapText == null) return; // the ratchet is being introduced
      final baseIds = parseRatchetSnapshot(snapText).keys;
      expect(
        unregisteredRatchets(
            baseIds: baseIds, headIds: kRatchets.map((r) => r.id)),
        isEmpty,
      );
    }, skip: skip);
  });
}
