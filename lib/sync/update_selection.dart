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
  final summary = ReleaseSelection(source, installed,
      officialPrereleases: officialPrereleases);
  for (final release in releases) {
    summary.add(release, manifest: manifests[release['id']]);
  }
  return summary.selected;
}

/// Bounded selection facts: one maximum, two blocker maxima and duplicate sets.
/// No manifest bodies or catalog pages survive here. A catalog beyond the
/// duplicate-set bound is refused rather than silently losing ambiguity checks.
class ReleaseSelection {
  ReleaseSelection(this.source, this.installed, {this.officialPrereleases = false});
  static const maxReleases = 1024;
  final ReleaseSource source;
  final InstalledRelease installed;
  final bool officialPrereleases;
  final forkCodes = <int>{};
  final tags = <String>{};
  final ids = <int>{};
  ReleaseCandidate? _best;
  String? _unknownTag;
  String? latestTag;
  int? _blockerBuild;
  bool hasReleases = false;
  bool ambiguous = false;

  int _compare(ReleaseCandidate a, ReleaseCandidate b) =>
      source == ReleaseSource.official
          ? compareSemver(a.tag.substring(1), b.tag.substring(1))
          : a.build!.compareTo(b.build!);

  int _compareTag(String a, String b) => source == ReleaseSource.official
      ? compareSemver(a.substring(1), b.substring(1)) : a.compareTo(b);

  void _block(String tag, int? build) {
    if (build == null) {
      if (_unknownTag == null || _compareTag(tag, _unknownTag!) > 0) _unknownTag = tag;
    } else if (_blockerBuild == null || build > _blockerBuild!) {
      _blockerBuild = build;
    }
  }

  void add(Map<String, dynamic> release, {Map<String, dynamic>? manifest}) {
    hasReleases = true;
    if (ids.length >= maxReleases) throw const FormatException('Catalog too large');

    final tag = release['tag_name'];
    if (release['draft'] != false ||
        tag is! String ||
        !supportedTag(source, tag)) {
      return;
    }
    final id = release['id'];
    final prerelease = release['prerelease'];
    if (source == ReleaseSource.official &&
        !officialPrereleases &&
        (prerelease == true || tag.contains('-'))) {
      return;
    }
    if (latestTag == null || _compareTag(tag, latestTag!) > 0) latestTag = tag;
    if (id is! int || id <= 0 || prerelease is! bool) {
      _block(tag, null);
      return;
    }
    if (!tags.add(tag) || !ids.add(id)) {
      ambiguous = true;
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
        if (manifest == null) {
          _block(tag, null);
          return;
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
          _block(tag, build);
          return;
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
          _block(tag, build);
          return;
        }
      }
      if (asset == null) {
        _block(tag, null);
        return;
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
      if (_best == null || _compare(candidate, _best!) > 0) {
        _best = candidate;
      }
    } on FormatException catch (e) {
      // An ambiguous catalog is not a bad release: it cannot be ordered.
      if (e.message == 'Ambiguous fork sequence') {
        ambiguous = true;
        rethrow;
      }
      _block(tag, null);
    } on TypeError {
      _block(tag, null);
    }
  }

  ReleaseCandidate? get selected {
    if (ambiguous) throw const FormatException('Ambiguous release');
    final best = _best;
    if (best == null) return null;
    if (_unknownTag != null && _compareTag(_unknownTag!, best.tag) > 0) return null;
    if (source == ReleaseSource.fork && _blockerBuild != null &&
        _blockerBuild! >= best.build!) {
      return null;
    }
    return best.withRelation(relationFor(best, installed));
  }

  Map<String, Object?> toJson() => {
    'best': _best?.toJson(), 'unknownTag': _unknownTag, 'blockerBuild': _blockerBuild,
    'latestTag': latestTag, 'hasReleases': hasReleases, 'ambiguous': ambiguous,
    'codes': forkCodes.toList(), 'tags': tags.toList(), 'ids': ids.toList(),
  };

  factory ReleaseSelection.fromJson(ReleaseSource source, InstalledRelease installed,
      Map<String, dynamic> json, {bool officialPrereleases = false}) {
    final summary = ReleaseSelection(source, installed, officialPrereleases: officialPrereleases);
    summary.forkCodes.addAll((json['codes'] as List).cast<int>());
    summary.tags.addAll((json['tags'] as List).cast<String>());
    summary.ids.addAll((json['ids'] as List).cast<int>());
    if (summary.ids.length > maxReleases || summary.tags.length > maxReleases ||
        summary.forkCodes.length > maxReleases) {
      throw const FormatException('Catalog too large');
    }
    final best = json['best'];
    summary._best = best == null ? null : ReleaseCandidate.fromJson(Map<String, dynamic>.from(best as Map));
    if (summary._best != null && summary._best!.source != source) throw const FormatException();
    summary._unknownTag = json['unknownTag'] as String?;
    summary._blockerBuild = json['blockerBuild'] as int?;
    summary.latestTag = json['latestTag'] as String?;
    summary.hasReleases = json['hasReleases'] as bool;
    summary.ambiguous = json['ambiguous'] as bool;
    return summary;
  }
}
