// UpdateService owns release discovery; UpdateStore owns all mutable update state.
// CLAIM(update-release-page): navigation accepts only canonical GitHub release
// pages for the two sources [test/updates/update_checker_test.dart].
enum ReleaseSource {
  // Repository ids verified against GET /repos/{repository} on 2026-11-15.
  // Numeric Link paths must belong to the source being checked.
  official('OpenStrap/edge', 1196502414),
  fork('mikenrafter/edge', 1403688012);

  const ReleaseSource(this.repository, this.repositoryId);
  final String repository;
  final int repositoryId;
}

enum UpdatePhase { off, notChecked, checking, current, available, error }

enum UpdateError {
  offline,
  badMetadata,
  redirect,
  rateLimited,
  incomplete,
  noRelease,
  noAsset,
  network,
  storage,
  scheduling,
}

bool supportedTag(ReleaseSource source, String tag) {
  if (tag.length > 80) return false;
  if (source == ReleaseSource.fork) {
    if (!RegExp(r'^next-20\d{2}\.\d{2}\.\d{2}$').hasMatch(tag)) return false;
    final parts = tag.substring(5).split('.').map(int.parse).toList();
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    return date.year == parts[0] &&
        date.month == parts[1] &&
        date.day == parts[2];
  }
  if (!RegExp(
    r'^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  ).hasMatch(tag)) {
    return false;
  }
  if (!tag.contains('-')) return true;
  return !tag
      .substring(tag.indexOf('-') + 1)
      .split('.')
      .any(
        (part) =>
            RegExp(r'^\d+$').hasMatch(part) &&
            part.length > 1 &&
            part.startsWith('0'),
      );
}

class ReleasePage {
  const ReleasePage._(this.uri);
  final Uri uri;
  static ReleasePage? tryParse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    for (final source in ReleaseSource.values) {
      final prefix = 'https://github.com/${source.repository}/releases/tag/';
      if (raw.startsWith(prefix) &&
          supportedTag(source, raw.substring(prefix.length)) &&
          uri.toString() == raw) {
        return ReleasePage._(uri);
      }
    }
    return null;
  }

  factory ReleasePage.forRelease(ReleaseSource source, String tag) {
    final page = tryParse(
      'https://github.com/${source.repository}/releases/tag/$tag',
    );
    if (page == null) throw const FormatException('Unsupported release tag');
    return page;
  }
  @override
  String toString() => uri.toString();
}

class InstalledRelease {
  const InstalledRelease({
    required this.version,
    required this.build,
    required this.fork,
    required this.mode,
    this.abis = const [],
  });
  final String version, mode;
  final int build;
  final bool? fork;
  final List<String> abis;

  // Android labels Edge Dev profile/debug and forkDevRelease builds with a
  // final -dev. Remove only that build label, retaining upstream prereleases.
  // CLAIM(update-installed-base): platform labels do not change the fork's
  // upstream version [test/updates/update_review_regressions_test.dart].
  String get upstreamVersion => fork == true && version.endsWith('-dev')
      ? version.substring(0, version.length - '-dev'.length)
      : version;
}

class ReleaseCandidate {
  const ReleaseCandidate({
    required this.source,
    required this.id,
    required this.tag,
    required this.asset,
    required this.prerelease,
    this.build,
    this.separateApp = false,
  });
  final ReleaseSource source;
  final int id;
  final String tag, asset;
  final bool prerelease, separateApp;
  final int? build;

  // The relationship is local presentation state, recalculated even for old
  // cached candidates after an app upgrade. It never comes from GitHub.
  ReleaseCandidate forInstall(InstalledRelease installed) => ReleaseCandidate(
    source: source,
    id: id,
    tag: tag,
    asset: asset,
    prerelease: prerelease,
    build: build,
    separateApp: source == ReleaseSource.official && installed.fork == true,
  );
  ReleasePage get page => ReleasePage.forRelease(source, tag);
  String get identity => 'release:${source.name}:$id';
  Map<String, Object?> toJson() => {
    'source': source.name,
    'id': id,
    'tag': tag,
    'asset': asset,
    'prerelease': prerelease,
    'build': build,
  };
  factory ReleaseCandidate.fromJson(Map<String, dynamic> json) {
    final source = ReleaseSource.values.byName(json['source'] as String);
    final tag = json['tag'] as String;
    ReleasePage.forRelease(source, tag);
    final id = json['id'] as int;
    final asset = json['asset'] as String;
    if (id <= 0 || asset.contains('/') || asset.length > 180) {
      throw const FormatException();
    }
    return ReleaseCandidate(
      source: source,
      id: id,
      tag: tag,
      asset: asset,
      prerelease: json['prerelease'] as bool,
      build: json['build'] as int?,
    );
  }
}

class SourceUpdate {
  const SourceUpdate({
    this.candidate,
    this.releasePage,
    this.checkedAt,
    this.error,
    this.etag,
    this.retryAt,
    this.current = false,
  });
  final ReleaseCandidate? candidate;
  final ReleasePage? releasePage;
  final DateTime? checkedAt, retryAt;
  final UpdateError? error;
  final String? etag;
  final bool current;
  Map<String, Object?> toJson() => {
    'candidate': candidate?.toJson(),
    'releasePage': releasePage?.toString(),
    'checkedAt': checkedAt?.millisecondsSinceEpoch,
    'error': error?.name,
    'etag': etag,
    'retryAt': retryAt?.millisecondsSinceEpoch,
    'current': current,
  };
  factory SourceUpdate.fromJson(Map<String, dynamic> json) => SourceUpdate(
    candidate: json['candidate'] == null
        ? null
        : ReleaseCandidate.fromJson(
            Map<String, dynamic>.from(json['candidate'] as Map),
          ),
    releasePage: json['releasePage'] is String
        ? ReleasePage.tryParse(json['releasePage'] as String)
        : null,
    checkedAt: json['checkedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            json['checkedAt'] as int,
            isUtc: true,
          ),
    retryAt: json['retryAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            json['retryAt'] as int,
            isUtc: true,
          ),
    error: json['error'] == null
        ? null
        : UpdateError.values.byName(json['error'] as String),
    etag: json['etag'] as String?,
    current: json['current'] == true,
  );
}

class UpdateSnapshot {
  const UpdateSnapshot({
    this.enabled = false,
    this.phase = UpdatePhase.off,
    this.sources = const {},
    this.waiting = false,
    this.officialPrereleases = false,
  });
  final bool enabled, waiting, officialPrereleases;
  final UpdatePhase phase;
  final Map<ReleaseSource, SourceUpdate> sources;
}
