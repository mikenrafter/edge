// WHY: what the checker calls "an update" must come from the installed identity
// and the release's checked metadata, never from API order, a counter shared
// across repositories, or text GitHub controls. These are pure selection tests:
// no network, no clock, no store.
// Proves CLAIM(release-check-asset-match), CLAIM(release-check-source-order).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/update_models.dart';
import 'package:openstrap_edge/sync/update_selection.dart';

import 'update_checker_test.dart' show release;

ReleaseCandidate official(String tag, {int id = 1}) => ReleaseCandidate(
  source: ReleaseSource.official,
  id: id,
  tag: tag,
  asset: 'openstrap-edge-$tag.apk',
  prerelease: tag.contains('-'),
);

ReleaseCandidate fork(int? build, {int id = 2}) => ReleaseCandidate(
  source: ReleaseSource.fork,
  id: id,
  tag: 'next-2026.11.15',
  asset: 'openstrap-edge-next-2026.11.15-dev-profile.apk',
  prerelease: true,
  build: build,
);

InstalledRelease installed(
  String version, {
  bool? fork = true,
  int build = 81,
  String mode = 'profile',
  List<String> abis = const ['arm64-v8a'],
}) => InstalledRelease(
  version: version,
  build: build,
  fork: fork,
  mode: mode,
  abis: abis,
);

Map<String, dynamic> manifest(
  String tag,
  int code, {
  List<String> abis = const ['arm64-v8a'],
  String mode = 'profile',
  String? name,
}) => {
  'formatVersion': 1,
  'repository': 'mikenrafter/edge',
  'tag': tag,
  'versionCode': code,
  'artifacts': [
    {
      'name': name ?? 'openstrap-edge-$tag-dev-$mode.apk',
      'mode': mode,
      'package': 'wtf.openstrap.openstrap_edge.dev',
      'abis': abis,
    },
  ],
};

Map<String, Object?> forkRelease(String tag, int id, {String mode = 'profile'}) =>
    release(
      tag,
      id: id,
      prerelease: true,
      assets: ['edge-release.json', 'openstrap-edge-$tag-dev-$mode.apk'],
    );

void main() {
  // WHY: the fork's real identity is `0.12.2-dev`, code 81, on package .dev.
  // The platform's -dev label is not a prerelease, so official v0.12.2 is the
  // same upstream version: informational, never "official news".
  // CLAIM(release-check-source-order) catches: announcing equal official 0.12.2
  // on the real profile identity (mutation named in spec §7).
  group('relationship to the install', () {
    final real = installed('0.12.2-dev');
    test('equal official release on the real fork identity is informational', () {
      expect(
        relationFor(official('v0.12.2'), real),
        ReleaseRelation.officialInformational,
      );
      expect(
        relationFor(official('v0.12.1'), real),
        ReleaseRelation.officialInformational,
      );
      expect(relationFor(official('v0.12.2'), real).announces, isFalse);
    });
    test('a higher official release is a separate app', () {
      final r = relationFor(official('v0.12.3'), real);
      expect(r, ReleaseRelation.officialSeparateApp);
      expect(r.announces, isTrue);
      expect(official('v0.12.3').withRelation(r).separateApp, isTrue);
    });
    // catches: splitting at the first hyphen; stripping a genuine prerelease.
    test('only one final -dev is the platform label; rc semantics survive', () {
      final rc = installed('0.12.2-rc.1-dev');
      expect(relationFor(official('v0.12.2-rc.1'), rc),
          ReleaseRelation.officialInformational);
      expect(relationFor(official('v0.12.2-rc.2'), rc),
          ReleaseRelation.officialSeparateApp);
      expect(relationFor(official('v0.12.2'), rc),
          ReleaseRelation.officialSeparateApp);
      // `-dev.1` is a real prerelease: 0.12.2-dev.1 < 0.12.2.
      expect(relationFor(official('v0.12.2'), installed('0.12.2-dev.1')),
          ReleaseRelation.officialSeparateApp);
    });
    // catches: normalizing the official package's version as if it were a fork.
    test('an official-package 0.12.2-dev is not normalized', () {
      final official0 = installed('0.12.2-dev', fork: false);
      expect(relationFor(official('v0.12.2'), official0),
          ReleaseRelation.officialNewer);
      expect(relationFor(official('v0.12.2'), installed('0.12.2', fork: false)),
          ReleaseRelation.officialCurrent);
    });
    // WHY: an unknown base must not become news (spec §5.3).
    test('unknown identity or unparsable base yields unknown, never news', () {
      expect(relationFor(official('v0.12.3'), installed('0.12.2', fork: null)),
          ReleaseRelation.unknown);
      expect(relationFor(official('v0.12.3'), installed('garbage-dev')),
          ReleaseRelation.unknown);
      expect(relationFor(fork(90), installed('0.12.2-dev', fork: null)),
          ReleaseRelation.unknown);
    });
    // catches: comparing the official build counter with the fork's code.
    test('fork builds compare only with the installed fork code', () {
      expect(relationFor(fork(82), real), ReleaseRelation.forkNewer);
      expect(relationFor(fork(81), real), ReleaseRelation.forkCurrent);
      expect(relationFor(fork(80), real), ReleaseRelation.forkCurrent);
      expect(relationFor(fork(null), real), ReleaseRelation.unknown);
      // A fork release is another app for an official install.
      expect(relationFor(fork(99), installed('0.12.2', fork: false)),
          ReleaseRelation.unknown);
    });
  });

  group('older malformed releases cannot poison a valid newer candidate', () {
    final inst = installed('0.11.3-dev', abis: const ['arm64-v8a']);
    // catches: one bad `assets` shape in history failing the whole source.
    test('official: older bad assets shape and duplicate names are ignored', () {
      final good = release('v0.11.4', id: 4);
      final badShape = release('v0.10.0', id: 1)..['assets'] = 'oops';
      final duplicate = release('v0.10.1', id: 2, assets: [
        'openstrap-edge-v0.10.1.apk',
        'openstrap-edge-v0.10.1.apk',
      ]);
      final selected = selectRelease(
        ReleaseSource.official,
        [badShape, duplicate, good],
        inst,
      );
      expect(selected?.tag, 'v0.11.4');
    });
    // WHY: a malformed NEWER relevant release means the newest is unknown;
    // claiming the older one is current would be a false answer.
    // catches: silently falling back across a newer malformed release.
    test('official: a newer malformed release blocks a current claim', () {
      final good = release('v0.11.4', id: 4);
      final newerBad = release('v0.12.0', id: 5)..['assets'] = 'oops';
      expect(
        selectRelease(ReleaseSource.official, [good, newerBad], inst),
        isNull,
      );
    });
    test('fork: older missing, malformed or foreign manifest is ignored', () {
      final newer = forkRelease('next-2026.11.15', 91);
      final old = forkRelease('next-2026.11.01', 92);
      expect(
        selectRelease(
          ReleaseSource.fork,
          [old, newer],
          inst,
          manifests: {91: manifest('next-2026.11.15', 80)},
        )?.tag,
        'next-2026.11.15',
      );
      for (final bad in [
        {...manifest('next-2026.11.01', 70), 'formatVersion': 2},
        {...manifest('next-2026.11.01', 70), 'repository': 'evil/edge'},
        {...manifest('next-2026.11.01', 70), 'versionCode': -3},
      ]) {
        expect(
          selectRelease(
            ReleaseSource.fork,
            [old, newer],
            inst,
            manifests: {91: manifest('next-2026.11.15', 80), 92: bad},
          )?.tag,
          'next-2026.11.15',
          reason: '$bad',
        );
      }
    });
    test('fork: a newer unrecognized release blocks fallback to an older one', () {
      final newer = forkRelease('next-2026.11.16', 93);
      final old = forkRelease('next-2026.11.15', 91);
      expect(
        selectRelease(
          ReleaseSource.fork,
          [newer, old],
          inst,
          manifests: {
            93: {...manifest('next-2026.11.16', 81), 'formatVersion': 9},
            91: manifest('next-2026.11.15', 80),
          },
        ),
        isNull,
      );
    });
  });

  // WHY: spec §5.3 validates only the fields the checker selects with; publisher
  // inspection fields (hashes, source SHA, minSdk) are not the app's contract.
  // catches: requiring `sourceSha` (the pilot did), or trusting extra fields.
  test('manifest needs no sourceSha and ignores publisher-only fields', () {
    final m = {
      ...manifest('next-2026.11.15', 80),
      'sourceSha': 'not-a-sha',
      'apkSha256': 'x',
      'minSdk': 'banana',
    };
    final selected = selectRelease(
      ReleaseSource.fork,
      [forkRelease('next-2026.11.15', 91)],
      installed('0.11.3-dev'),
      manifests: {91: m},
    );
    expect(selected?.build, 80);
    expect(selected?.asset, 'openstrap-edge-next-2026.11.15-dev-profile.apk');
  });

  // WHY: Android's ordered ABI list decides, never file order or a substring.
  // catches: choosing arm64 by substring, or a portable asset not declaring the ABI.
  test('first supported ABI wins; portable asset must declare a supported ABI', () {
    const tag = 'next-2026.11.15';
    final r = release(tag, id: 91, prerelease: true, assets: [
      'edge-release.json',
      'openstrap-edge-$tag-dev-profile-armeabi-v7a.apk',
      'openstrap-edge-$tag-dev-profile-arm64-v8a.apk',
    ]);
    final m = {
      ...manifest(tag, 80, abis: ['arm64-v8a'], name: 'openstrap-edge-$tag-dev-profile-arm64-v8a.apk'),
      'artifacts': [
        {
          'name': 'openstrap-edge-$tag-dev-profile-armeabi-v7a.apk',
          'mode': 'profile',
          'package': 'wtf.openstrap.openstrap_edge.dev',
          'abis': ['armeabi-v7a'],
        },
        {
          'name': 'openstrap-edge-$tag-dev-profile-arm64-v8a.apk',
          'mode': 'profile',
          'package': 'wtf.openstrap.openstrap_edge.dev',
          'abis': ['arm64-v8a'],
        },
      ],
    };
    expect(
      selectRelease(ReleaseSource.fork, [r], installed('0.11.3-dev', abis: ['arm64-v8a', 'armeabi-v7a']), manifests: {91: m})
          ?.asset,
      'openstrap-edge-$tag-dev-profile-arm64-v8a.apk',
    );
    // x86_64 device, no x86_64 asset and no portable one: no matching build.
    expect(
      selectRelease(ReleaseSource.fork, [r], installed('0.11.3-dev', abis: ['x86_64']), manifests: {91: m}),
      isNull,
    );
  });

  // catches: tolerating two releases with one versionCode (an ambiguous order).
  test('two fork releases with one versionCode are ambiguous', () {
    expect(
      () => selectRelease(
        ReleaseSource.fork,
        [forkRelease('next-2026.11.15', 91), forkRelease('next-2026.11.08', 92)],
        installed('0.11.3-dev'),
        manifests: {
          91: manifest('next-2026.11.15', 80),
          92: manifest('next-2026.11.08', 80),
        },
      ),
      throwsFormatException,
    );
  });

  test('semantic order: prerelease below release, numeric identifiers numeric', () {
    expect(compareSemver('0.12.0-beta.10', '0.12.0-beta.2'), greaterThan(0));
    expect(compareSemver('0.12.0-beta.1', '0.12.0'), lessThan(0));
    expect(compareSemver('0.12.0', '0.12.0'), 0);
    expect(compareSemver('1.0.0', '0.99.99'), greaterThan(0));
    expect(() => compareSemver('x', '1.0.0'), throwsFormatException);
  });
}
