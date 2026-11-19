// Pure release selection: tag grammar order, asset-name matching, manifest
// validation and the local relationship of a candidate to this install. No
// network, storage or clock; runs anywhere and is tested without fakes.
//
// A metadata match is NOT a verified APK (spec §5.3). Names narrow the choice;
// the checker never requests, inspects or installs a binary.
import 'update_models.dart';

const _forkPackage = 'wtf.openstrap.openstrap_edge.dev';
const _supportedAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};
const _forkModes = {'profile', 'release'};

/// Orders two semantic versions without a leading `v` (prerelease aware):
/// a prerelease precedes its release, numeric identifiers compare numerically.
/// Throws [FormatException] on a malformed version.
int compareSemver(String a, String b) {
  final left = a.split('-');
  final right = b.split('-');
  final leftCore = left.first.split('.').map(int.parse).toList();
  final rightCore = right.first.split('.').map(int.parse).toList();
  if (leftCore.length != 3 || rightCore.length != 3) {
    throw const FormatException('Not a semantic version');
  }
  for (var i = 0; i < 3; i++) {
    final comparison = leftCore[i].compareTo(rightCore[i]);
    if (comparison != 0) return comparison;
  }
  if (left.length == 1 || right.length == 1) {
    return (left.length == 1 ? 1 : 0).compareTo(right.length == 1 ? 1 : 0);
  }
  final lp = left.skip(1).join('-').split('.');
  final rp = right.skip(1).join('-').split('.');
  for (var i = 0; i < lp.length && i < rp.length; i++) {
    final ln = int.tryParse(lp[i]), rn = int.tryParse(rp[i]);
    final c = ln != null && rn != null
        ? ln.compareTo(rn)
        : ln != null
        ? -1
        : rn != null
        ? 1
        : lp[i].compareTo(rp[i]);
    if (c != 0) return c;
  }
  return lp.length.compareTo(rp.length);
}

/// The one asset a release offers this install, by exact name, or null.
/// Android's ordered ABI list decides; a portable asset is the last resort.
/// Throws [FormatException] for duplicate names.
String? matchAsset(
  ReleaseSource source,
  String tag,
  String mode,
  List<String> abis,
  List<String> names,
) {
  if (names.toSet().length != names.length) {
    throw const FormatException('Duplicate assets');
  }
  if (source == ReleaseSource.fork && !_forkModes.contains(mode)) return null;
  final prefix = source == ReleaseSource.official
      ? 'openstrap-edge-$tag'
      : 'openstrap-edge-$tag-dev-$mode';
  for (final abi in abis) {
    if (!_supportedAbis.contains(abi)) continue;
    if (names.contains('$prefix-$abi.apk')) return '$prefix-$abi.apk';
  }
  return names.contains('$prefix.apk') ? '$prefix.apk' : null;
}

/// The relationship of [candidate] to [installed], recomputed on every load.
///
/// Fork builds compare only with the installed fork versionCode; official
/// releases compare by semantic version, against the upstream base a fork
/// install is built on (one final platform `-dev` label stripped, see
/// [InstalledRelease.upstreamVersion]). Official build codes are never
/// compared with fork codes.
ReleaseRelation relationFor(
  ReleaseCandidate candidate,
  InstalledRelease installed,
) {
  final isFork = installed.fork;
  if (isFork == null) return ReleaseRelation.unknown;
  if (candidate.source == ReleaseSource.fork) {
    if (!isFork || candidate.build == null) return ReleaseRelation.unknown;
    return candidate.build! > installed.build
        ? ReleaseRelation.forkNewer
        : ReleaseRelation.forkCurrent;
  }
  final int comparison;
  try {
    comparison = compareSemver(
      candidate.tag.substring(1),
      installed.upstreamVersion,
    );
  } on FormatException {
    return ReleaseRelation.unknown;
  }
  if (isFork) {
    return comparison > 0
        ? ReleaseRelation.officialSeparateApp
        : ReleaseRelation.officialInformational;
  }
  return comparison > 0
      ? ReleaseRelation.officialNewer
      : ReleaseRelation.officialCurrent;
}

/// The fields of a fork manifest the checker uses, or throws
/// [FormatException]. Publisher-only fields (hashes, source SHA, minSdk) are
/// neither required nor kept; the result is what the cache may store.
Map<String, dynamic> checkedManifest(Object? decoded) {
  try {
    final m = Map<String, dynamic>.from(decoded as Map);
    final code = m['versionCode'];
    final artifacts = (m['artifacts'] as List).map((a) {
      final artifact = Map<String, dynamic>.from(a as Map);
      final name = artifact['name'] as String;
      final abis = (artifact['abis'] as List).cast<String>();
      if (name.isEmpty ||
          name.length > 180 ||
          name.contains('/') ||
          name.contains('\\') ||
          name.contains('..') ||
          abis.isEmpty ||
          abis.any((v) => !_supportedAbis.contains(v)) ||
          !_forkModes.contains(artifact['mode']) ||
          artifact['package'] != _forkPackage) {
        throw const FormatException('Bad artifact');
      }
      return <String, dynamic>{
        'name': name,
        'mode': artifact['mode'],
        'package': artifact['package'],
        'abis': abis.toSet().toList(),
      };
    }).toList();
    if (m['formatVersion'] != 1 ||
        m['repository'] != ReleaseSource.fork.repository ||
        m['tag'] is! String ||
        code is! int ||
        code <= 0 ||
        artifacts.isEmpty) {
      throw const FormatException('Bad manifest');
    }
    return {
      'formatVersion': 1,
      'repository': m['repository'],
      'tag': m['tag'],
      'versionCode': code,
      'artifacts': artifacts,
    };
  } on TypeError {
    throw const FormatException('Bad manifest');
  }
}

List<String> _assetNames(Map<String, dynamic> release) {
  final assets = release['assets'];
  if (assets is! List) throw const FormatException('Bad assets');
  final names = <String>[
    for (final a in assets)
      if (a is Map && a['name'] is String)
        a['name'] as String
      else
        throw const FormatException('Bad asset'),
  ];
  if (names.toSet().length != names.length) {
    throw const FormatException('Duplicate assets');
  }
  return names;
}

// One release's verdict. A candidate; an unmatched build (real release, but
// none for this mode/ABI); or unrecognized (malformed, or no checked manifest).
class _Unmatched {
  const _Unmatched(this.tag, this.build);
  final String tag;
  final int? build;
}

/// The newest matching release for [source], or null when none is
/// established: no release, or a newer release exists that this install
/// cannot match or validate (so an older one is never called the newest).
///
/// A malformed, unmatched or manifest-less release older than the best
/// candidate cannot poison it. Throws [FormatException] only for an ambiguous
/// catalog (duplicate tag, id or fork versionCode).
ReleaseCandidate? selectRelease(
  ReleaseSource source,
  List<Map<String, dynamic>> releases,
  InstalledRelease installed, {
  Map<int, Map<String, dynamic>> manifests = const {},
  bool officialPrereleases = false,
}) {
  final candidates = <ReleaseCandidate>[];
  final blockers = <_Unmatched>[];
  final forkCodes = <int>{};
  final tags = <String>{};
  final ids = <int>{};
  for (final release in releases) {
    final tag = release['tag_name'];
    if (release['draft'] != false ||
        tag is! String ||
        !supportedTag(source, tag)) {
      continue;
    }
    final id = release['id'];
    final prerelease = release['prerelease'];
    if (source == ReleaseSource.official &&
        !officialPrereleases &&
        (prerelease == true || tag.contains('-'))) {
      continue;
    }
    if (id is! int || id <= 0 || prerelease is! bool) {
      blockers.add(_Unmatched(tag, null));
      continue;
    }
    if (!tags.add(tag) || !ids.add(id)) {
      throw const FormatException('Ambiguous release');
    }
    try {
      final names = _assetNames(release);
      final asset = matchAsset(
        source,
        tag,
        installed.mode,
        installed.abis,
        names,
      );
      int? build;
      if (source == ReleaseSource.fork) {
        final manifest = manifests[id];
        if (manifest == null) {
          blockers.add(_Unmatched(tag, null));
          continue;
        }
        final checked = checkedManifest(manifest);
        if (checked['tag'] != tag) throw const FormatException('Tag mismatch');
        build = checked['versionCode'] as int;
        if (!forkCodes.add(build)) {
          throw const FormatException('Ambiguous fork sequence');
        }
        final seen = <String>{};
        for (final artifact in (checked['artifacts'] as List).cast<Map>()) {
          final name = artifact['name'] as String;
          final mode = artifact['mode'] as String;
          final abis = (artifact['abis'] as List).cast<String>();
          if (!seen.add(name) ||
              !names.contains(name) ||
              matchAsset(source, tag, mode, abis, [name]) != name) {
            throw const FormatException('Ambiguous artifact');
          }
        }
        if (asset == null) {
          blockers.add(_Unmatched(tag, build));
          continue;
        }
        final match = (checked['artifacts'] as List)
            .cast<Map>()
            .where((a) => a['name'] == asset)
            .toList();
        if (match.length != 1 || match.single['mode'] != installed.mode) {
          throw const FormatException('Missing artifact');
        }
        if (installed.abis.isNotEmpty &&
            !(match.single['abis'] as List).any(installed.abis.contains)) {
          blockers.add(_Unmatched(tag, build));
          continue;
        }
      }
      if (asset == null) {
        blockers.add(_Unmatched(tag, null));
        continue;
      }
      final candidate = ReleaseCandidate(
        source: source,
        id: id,
        tag: tag,
        asset: asset,
        prerelease:
            prerelease || (source == ReleaseSource.official && tag.contains('-')),
        build: build,
      );
      candidates.add(candidate.withRelation(relationFor(candidate, installed)));
    } on FormatException catch (e) {
      // An ambiguous catalog is not a bad release: it cannot be ordered.
      if (e.message == 'Ambiguous fork sequence') rethrow;
      blockers.add(_Unmatched(tag, null));
    } on TypeError {
      blockers.add(_Unmatched(tag, null));
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort(
    (a, b) => source == ReleaseSource.official
        ? compareSemver(b.tag.substring(1), a.tag.substring(1))
        : b.build!.compareTo(a.build!),
  );
  final best = candidates.first;
  for (final blocker in blockers) {
    // Newer than the best candidate: the newest release is unknown to us.
    final newer = source == ReleaseSource.official
        ? compareSemver(blocker.tag.substring(1), best.tag.substring(1)) > 0
        : blocker.build != null
        ? blocker.build! >= best.build!
        : blocker.tag.compareTo(best.tag) > 0;
    if (newer) return null;
  }
  return best;
}
