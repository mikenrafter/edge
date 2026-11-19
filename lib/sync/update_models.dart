// Checked release types. UpdateCoordinator owns discovery and publication of
// observable state; UpdateStore owns all mutable update state; nothing here
// touches the network, storage or the health database.
//
// CLAIM(release-check-page-only): navigation accepts only canonical GitHub
// release pages for the two sources [test/updates/update_models_test.dart].
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

  /// An ordinary 403: a refusal or authorization problem, not a rate limit.
  refused,

  /// The installed package/version could not be identified, so no release can
  /// be called an update.
  unidentified,
}

/// How a release relates to THIS install. Always computed locally after
/// discovery and again after a cache reload; never taken from GitHub.
enum ReleaseRelation {
  /// A newer fork build of this fork install.
  forkNewer,

  /// This fork build or a later one is already installed.
  forkCurrent,

  /// Official release above this fork's base version: a separate app.
  officialSeparateApp,

  /// Official release at or below this fork's base: informational only.
  officialInformational,

  /// A newer official release of the installed official app.
  officialNewer,

  /// The installed official app is this release or newer.
  officialCurrent,

  /// Not comparable (unknown identity or base, or a fork release on an official
  /// install). Never announced.
  unknown;

  /// True when Settings and the notification say something is new.
  bool get announces =>
      this == forkNewer || this == officialSeparateApp || this == officialNewer;
}

/// The outcome of one check operation. Replaces a bare success flag so a
/// deferral is never confused with a failure.
sealed class CheckOutcome {
  const CheckOutcome();
}

/// Every due source was attempted; per-source errors live in the snapshot.
final class CheckCompleted extends CheckOutcome {
  const CheckCompleted();
}

enum DeferReason {
  disabled,
  metered,
  throttled,
  leaseHeld,
  notDue,
  closed,

  /// The install's identity is unknown: no checks, a visible explanation.
  unsupported,
}

/// Nothing was requested, by design.
final class CheckDeferred extends CheckOutcome {
  const CheckDeferred(this.reason);
  final DeferReason reason;
}

/// The check was not allowed (consent missing or withdrawn mid-batch).
final class CheckRefused extends CheckOutcome {
  const CheckRefused(this.reason);
  final DeferReason reason;
}

/// Local storage or scheduling failed; the snapshot says which.
final class CheckFailed extends CheckOutcome {
  const CheckFailed(this.error);
  final UpdateError error;
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

  /// The repository's releases list: the fallback a device that cannot
  /// identify itself offers as a manually tapped link.
  factory ReleasePage.indexOf(ReleaseSource source) => ReleasePage._(
    Uri.https('github.com', '/${source.repository}/releases'),
  );

  factory ReleasePage.forRelease(ReleaseSource source, String tag) {
    final page = tryParse(
      'https://github.com/${source.repository}/releases/tag/$tag',
    );
    if (page == null) throw const FormatException('Unsupported release tag');
    return page;
  }
  @override
  String toString() => uri.toString();
  @override
  bool operator ==(Object other) => other is ReleasePage && other.uri == uri;
  @override
  int get hashCode => uri.hashCode;
}

/// The notification payload for a release: a typed source/tag pair, never a
/// URL. [ReleaseRoute.parse] is the one validator for foreground and cold-launch
/// taps; it reconstructs the page through [ReleasePage.forRelease].
const String kRouteRelease = '/release';

String releaseRoute(ReleaseSource source, String tag) => Uri(
  path: kRouteRelease,
  queryParameters: {'source': source.name, 'tag': tag},
).toString();

/// A release announcement's identity: `release:<source>:<id>`, with a route
/// that names the SAME source. The identity is the permanent claim key.
bool isReleaseAnnouncement(String dedupeKey, String? route) {
  final m = RegExp(r'^release:(official|fork):([1-9]\d{0,17})$').firstMatch(dedupeKey);
  if (m == null || route == null) return false;
  final page = ReleaseRoute.parse(route);
  if (page == null) return false;
  final prefix = 'https://github.com/${ReleaseSource.values.byName(m.group(1)!).repository}/';
  return page.toString().startsWith(prefix);
}

abstract final class ReleaseRoute {
  /// The page a release route names, or null for anything else (an unknown
  /// source, an unsupported tag, extra parameters, an arbitrary URL).
  static ReleasePage? parse(String? route) {
    if (route == null) return null;
    final uri = Uri.tryParse(route);
    if (uri == null || uri.hasScheme || uri.hasAuthority || uri.path != kRouteRelease) return null;
    final q = uri.queryParameters;
    if (q.length != 2) return null;
    final name = q['source'];
    final tag = q['tag'];
    if (name == null || tag == null) return null;
    final source = ReleaseSource.values.where((s) => s.name == name).firstOrNull;
    if (source == null || !supportedTag(source, tag)) return null;
    return ReleasePage.forRelease(source, tag);
  }
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
    this.relation = ReleaseRelation.unknown,
  });
  final ReleaseSource source;
  final int id;
  final String tag, asset;
  final bool prerelease;
  final int? build;

  /// Local presentation state, recalculated for old cached candidates after an
  /// app upgrade. It never comes from GitHub and is never stored.
  final ReleaseRelation relation;
  /// An official release seen from a fork install: another app either way.
  bool get separateApp =>
      relation == ReleaseRelation.officialSeparateApp ||
      relation == ReleaseRelation.officialInformational;

  ReleaseCandidate withRelation(ReleaseRelation relation) => ReleaseCandidate(
    source: source,
    id: id,
    tag: tag,
    asset: asset,
    prerelease: prerelease,
    build: build,
    relation: relation,
  );
  ReleasePage get page => ReleasePage.forRelease(source, tag);
  String get route => releaseRoute(source, tag);
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
  });
  final ReleaseCandidate? candidate;
  final ReleasePage? releasePage;
  final DateTime? checkedAt, retryAt;
  final UpdateError? error;
  final String? etag;

  /// A comparable candidate that announces nothing new for this install.
  bool get current =>
      candidate != null &&
      candidate!.relation != ReleaseRelation.unknown &&
      !candidate!.relation.announces;

  /// Last good metadata shown with an error beside it.
  bool get stale => candidate != null && error != null;

  /// A result with [relation] recomputed on the candidate.
  SourceUpdate withRelation(ReleaseRelation Function(ReleaseCandidate) of) =>
      SourceUpdate(
        candidate: candidate?.withRelation(of(candidate!)),
        releasePage: releasePage,
        checkedAt: checkedAt,
        error: error,
        etag: etag,
        retryAt: retryAt,
      );
  Map<String, Object?> toJson() => {
    'candidate': candidate?.toJson(),
    'releasePage': releasePage?.toString(),
    'checkedAt': checkedAt?.millisecondsSinceEpoch,
    'error': error?.name,
    'etag': etag,
    'retryAt': retryAt?.millisecondsSinceEpoch,
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
  );
}

class UpdateSnapshot {
  const UpdateSnapshot({
    this.enabled = false,
    this.phase = UpdatePhase.off,
    this.sources = const {},
    this.waiting = false,
    this.officialPrereleases = false,
    this.authorizationReset = false,
  });
  final bool enabled, waiting, officialPrereleases;

  /// The stored consent was unreadable and was reset to off (reported once).
  final bool authorizationReset;
  final UpdatePhase phase;
  final Map<ReleaseSource, SourceUpdate> sources;
}
