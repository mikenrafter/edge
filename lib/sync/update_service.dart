// Owns release discovery and UI state. No APK bytes, installer or companion
// endpoint participates. Remote text never becomes a navigation destination.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';
import 'update_models.dart';
import 'update_store.dart';
export 'update_models.dart';

const updateTaskName = 'edge.github.release-check.v1';
const updateTaskFrequency = Duration(days: 1);
const updateTaskNetworkType = NetworkType.unmetered;

Future<void> scheduleUpdateChecks(bool enabled) async {
  if (!Platform.isAndroid) return;
  if (!enabled) {
    await Workmanager().cancelByUniqueName(updateTaskName);
    return;
  }
  await Workmanager().registerPeriodicTask(
    updateTaskName,
    updateTaskName,
    frequency: updateTaskFrequency,
    initialDelay: const Duration(hours: 1),
    constraints: Constraints(networkType: updateTaskNetworkType),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.store,
    required this.client,
    required this.installed,
    required this.now,
    required this.unmetered,
    required this.schedule,
    this.onRelease,
    this.clientFactory,
  });
  final UpdateStore store;
  final http.Client client;
  final http.Client Function()? clientFactory;
  final InstalledRelease installed;
  final DateTime Function() now;
  final Future<bool> Function() unmetered;
  final Future<void> Function(bool) schedule;
  final Future<void> Function(ReleaseCandidate)? onRelease;
  UpdateSnapshot snapshot = const UpdateSnapshot();
  Future<void>? _checking;

  bool _closed = false;
  void _publish() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    client.close();
    super.dispose();
  }

  static Future<UpdateService> create({
    Future<void> Function(ReleaseCandidate)? onRelease,
  }) async {
    final info = await PackageInfo.fromPlatform();
    const environment = MethodChannel('openstrap/release_environment');
    final abis = Platform.isAndroid
        ? await environment.invokeListMethod<String>('abis') ?? <String>[]
        : <String>[];
    return UpdateService(
      store: await UpdateStore.open(),
      client: http.Client(),
      clientFactory: () => http.Client(),
      installed: InstalledRelease(
        version: info.version,
        build: int.tryParse(info.buildNumber) ?? 0,
        fork: info.packageName == 'wtf.openstrap.openstrap_edge.dev'
            ? true
            : info.packageName == 'wtf.openstrap.openstrap_edge'
            ? false
            : null,
        mode: kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        abis: abis,
      ),
      now: DateTime.now,
      unmetered: () async =>
          Platform.isAndroid &&
          (await environment.invokeMethod<bool>('unmetered') ?? false),
      schedule: scheduleUpdateChecks,
      onRelease: onRelease,
    );
  }

  UpdateLease? _activeLease;
  bool _isCurrent(ReleaseCandidate candidate) {
    try {
      return candidate.source == ReleaseSource.fork
          ? installed.fork == true &&
                candidate.build != null &&
                candidate.build! <= installed.build
          : installed.fork != null &&
                _compareSemver(
                      candidate.tag.substring(1),
                      installed.upstreamVersion,
                    ) <=
                    0;
    } catch (_) {
      return false;
    }
  }

  Future<void> load() async {
    final saved = await store.read();
    final sources = {
      for (final entry in saved.sources.entries)
        entry.key: SourceUpdate(
          candidate: entry.value.candidate?.forInstall(installed),
          releasePage: entry.value.releasePage,
          checkedAt: entry.value.checkedAt,
          error: entry.value.error,
          etag: entry.value.etag,
          retryAt: entry.value.retryAt,
          current:
              entry.value.candidate != null &&
              _isCurrent(entry.value.candidate!),
        ),
    };
    final phase = sources.isEmpty
        ? (saved.enabled ? UpdatePhase.notChecked : UpdatePhase.off)
        : sources.values.any(
            (v) => v.candidate != null && !v.current && v.error == null,
          )
        ? UpdatePhase.available
        : sources.values.any((v) => v.error != null)
        ? UpdatePhase.error
        : UpdatePhase.current;
    snapshot = UpdateSnapshot(
      enabled: saved.enabled,
      officialPrereleases: saved.officialPrereleases,
      phase: _activeLease != null && await store.valid(_activeLease!)
          ? UpdatePhase.checking
          : phase,
      sources: sources,
    );
    _publish();
  }

  Future<void> setEnabled(bool enabled) async {
    await store.setEnabled(enabled);
    await load();
    try {
      await schedule(enabled);
    } catch (_) {
      snapshot = UpdateSnapshot(
        enabled: enabled,
        phase: UpdatePhase.error,
        sources: {
          for (final source in ReleaseSource.values)
            source: const SourceUpdate(error: UpdateError.scheduling),
        },
      );
      _publish();
    }
  }

  Future<void> setOfficialPrereleases(bool enabled) async {
    await store.setOfficialPrereleases(enabled);
    await load();
  }

  Future<void> check({bool manual = false}) {
    if (_closed) return Future<void>.value();
    if (_checking != null) return _checking!;
    final task = _check(manual: manual);
    _checking = task;
    return task.whenComplete(() {
      _checking = null;
    });
  }

  Future<void> _notify(ReleaseCandidate candidate) async {
    try {
      await onRelease?.call(candidate).timeout(const Duration(seconds: 10));
    } catch (_) {
      /* presentation cannot hold the network lease indefinitely */
    }
  }

  Future<void> _notifyCached() async {
    if (_closed || !snapshot.enabled) return;
    for (final result in snapshot.sources.values) {
      final age = result.checkedAt == null
          ? null
          : now().difference(result.checkedAt!);
      if (result.error == null &&
          result.candidate != null &&
          !result.current &&
          age != null &&
          !age.isNegative &&
          age <= const Duration(days: 1)) {
        await _notify(result.candidate!);
      }
    }
  }

  Future<void> _check({required bool manual}) async {
    UpdateLease? lease;
    var failedStorage = false;
    try {
      await load();
      // Quiet hours/permission do not spend a release claim. A later resume
      // may deliver the fresh cached announcement without another request.
      await _notifyCached();
      if (!manual) {
        if (!snapshot.enabled) return;
        if (!await unmetered()) {
          snapshot = UpdateSnapshot(
            enabled: true,
            phase: snapshot.phase,
            sources: snapshot.sources,
            officialPrereleases: snapshot.officialPrereleases,
            waiting: true,
          );
          _publish();
          return;
        }
      }
      lease = await store.claim(now(), manual: manual);
      if (lease == null) return;
      _activeLease = lease;
      snapshot = UpdateSnapshot(
        enabled: snapshot.enabled,
        phase: UpdatePhase.checking,
        sources: snapshot.sources,
        officialPrereleases: snapshot.officialPrereleases,
      );
      _publish();
      for (final source in ReleaseSource.values) {
        if (!await store.valid(lease)) break;
        final previous = snapshot.sources[source];
        if (previous?.retryAt != null && now().isBefore(previous!.retryAt!)) {
          continue;
        }
        final result = await _source(
          source,
          previous,
          lease,
          automatic: !manual,
        );
        if (!await store.save(lease, source, result)) break;
        await load();
        // Only opted-in users receive notifications; a manual request while
        // disabled does not authorize a continuing outbound alert channel.
        if (!_closed &&
            snapshot.enabled &&
            result.error == null &&
            result.candidate != null &&
            !result.current &&
            await store.valid(lease)) {
          await _notify(result.candidate!);
        }
      }
    } catch (_) {
      failedStorage = true;
    } finally {
      _activeLease = null;
      if (lease != null) {
        try {
          await store.release(lease);
          await load();
        } catch (_) {
          failedStorage = true;
        }
      }
      if (failedStorage) {
        snapshot = UpdateSnapshot(
          enabled: snapshot.enabled,
          phase: UpdatePhase.error,
          sources: {
            for (final source in ReleaseSource.values)
              source: const SourceUpdate(error: UpdateError.storage),
          },
        );
        _publish();
      }
    }
  }

  Future<SourceUpdate> _source(
    ReleaseSource source,
    SourceUpdate? previous,
    UpdateLease lease, {
    required bool automatic,
  }) async {
    ReleasePage? inspectedPage;
    try {
      Future<_MetadataResponse> request(
        Uri uri, {
        String? etag,
        bool manifest = false,
      }) async {
        if (_closed || !await store.valid(lease)) {
          throw const _UpdateFailure(UpdateError.network);
        }
        return _request(
          uri,
          etag: etag,
          manifest: manifest,
          allowed: () async =>
              !_closed &&
              await store.valid(lease) &&
              (!automatic || await unmetered()),
        );
      }

      final releases = <Map<String, dynamic>>[];
      String? etag;
      var paginated = false;
      for (var page = 1; page <= 3; page++) {
        final uri = Uri.https(
          'api.github.com',
          '/repos/${source.repository}/releases',
          {'per_page': '100', if (page > 1) 'page': '$page'},
        );
        final response = await request(
          uri,
          etag: page == 1 ? previous?.etag : null,
        );
        if (response.status == 304) {
          if (page != 1 || previous?.checkedAt == null) {
            throw const FormatException();
          }
          return SourceUpdate(
            candidate: previous!.candidate,
            releasePage: previous.releasePage,
            checkedAt: now(),
            etag: previous.etag,
            current:
                previous.candidate != null && _isCurrent(previous.candidate!),
            error: previous.candidate == null ? previous.error : null,
          );
        }
        if (_isRateLimit(response)) {
          return _rateLimit(response, previous);
        }
        if (response.status >= 300 && response.status < 400) {
          throw const _UpdateFailure(UpdateError.redirect);
        }
        if (response.status != 200) {
          throw const _UpdateFailure(UpdateError.network);
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! List || decoded.length > 100) {
          throw const FormatException();
        }
        releases.addAll(
          decoded.map((r) => Map<String, dynamic>.from(r as Map)),
        );
        if (page == 1) etag = response.headers['etag'];
        final link = response.headers['link'] ?? '';
        final next = RegExp(r'<([^>]+)>;\s*rel="next"').firstMatch(link);
        if (next == null) break;
        paginated = true;
        final expected = Uri.https(
          'api.github.com',
          '/repos/${source.repository}/releases',
          {'per_page': '100', 'page': '${page + 1}'},
        );
        final numericExpected = Uri.https(
          'api.github.com',
          '/repositories/${source.repositoryId}/releases',
          {'per_page': '100', 'page': '${page + 1}'},
        );
        // Never fetch a Link URL. Both accepted forms identify this exact
        // repository; the next request still uses our fixed /repos path.
        final supplied = Uri.tryParse(next.group(1)!);
        if (page == 3 ||
            (supplied != expected && supplied != numericExpected)) {
          throw const _UpdateFailure(UpdateError.incomplete);
        }
      }
      final knownTags = releases
          .where(
            (r) =>
                r['draft'] == false &&
                r['tag_name'] is String &&
                supportedTag(source, r['tag_name'] as String) &&
                (source == ReleaseSource.fork ||
                    snapshot.officialPrereleases ||
                    (r['prerelease'] == false &&
                        !(r['tag_name'] as String).contains('-'))),
          )
          .map((r) => r['tag_name'] as String)
          .toList();
      knownTags.sort(
        (a, b) => source == ReleaseSource.official
            ? _compareSemver(b.substring(1), a.substring(1))
            : b.compareTo(a),
      );
      if (knownTags.isNotEmpty) {
        inspectedPage = ReleasePage.forRelease(source, knownTags.first);
      }
      final manifests = <int, Map<String, dynamic>>{};
      var fetchedManifests = 0;
      if (source == ReleaseSource.fork) {
        for (final release in releases) {
          if (release['draft'] != false ||
              release['tag_name'] is! String ||
              !supportedTag(source, release['tag_name'] as String)) {
            continue;
          }
          // A historical pre-contract or malformed release cannot poison a
          // newer valid candidate. Selection below still refuses a newer
          // unrecognized date, rather than silently falling back.
          try {
            final assets = _assets(release);
            final manifest = assets
                .where((a) => a['name'] == 'edge-release.json')
                .toList();
            if (manifest.length > 1) throw const FormatException();
            if (manifest.isEmpty) continue;
            final id = manifest.single['id'];
            final releaseId = release['id'];
            if (id is! int || id <= 0 || releaseId is! int || releaseId <= 0) {
              throw const FormatException();
            }
            final updatedAt = manifest.single['updated_at'];
            final stamp = updatedAt == null
                ? null
                : DateTime.tryParse(updatedAt as String);
            if (updatedAt != null && stamp == null) {
              throw const FormatException();
            }
            final key = jsonEncode([
              source.name,
              releaseId,
              release['tag_name'],
              id,
              stamp?.toUtc().toIso8601String(),
            ]);
            var content = await store.manifest(key);
            if (content != null) {
              try {
                selectRelease(
                  source,
                  [release],
                  installed,
                  manifests: {releaseId: content},
                );
              } catch (_) {
                content = null;
              }
            }
            if (content == null) {
              if (fetchedManifests >= 8) {
                throw const _UpdateFailure(UpdateError.incomplete);
              }
              fetchedManifests++;
              final response = await request(
                Uri.https(
                  'api.github.com',
                  '/repos/${source.repository}/releases/assets/$id',
                ),
                manifest: true,
              );
              if (_isRateLimit(response)) {
                return _rateLimit(response, previous);
              }
              if (response.status == 404) {
                throw const FormatException('Missing manifest');
              }
              if (response.status != 200) {
                throw const _UpdateFailure(UpdateError.network);
              }
              final decoded = Map<String, dynamic>.from(
                jsonDecode(response.body) as Map,
              );
              selectRelease(
                source,
                [release],
                installed,
                manifests: {releaseId: decoded},
              );
              content = _manifestMetadata(decoded);
              if (!await store.saveManifest(lease, key, content)) {
                throw const _UpdateFailure(UpdateError.network);
              }
            }
            manifests[releaseId] = content;
          } on FormatException {
            continue;
          } on TypeError {
            continue;
          }
        }
      }
      final selected = selectRelease(
        source,
        releases,
        installed,
        manifests: manifests,
        officialPrereleases: snapshot.officialPrereleases,
      );
      return SourceUpdate(
        candidate: selected,
        releasePage: selected?.page ?? inspectedPage,
        checkedAt: now(),
        etag: paginated ? null : etag,
        current: selected != null && _isCurrent(selected),
        error: selected == null
            ? (releases.isEmpty ? UpdateError.noRelease : UpdateError.noAsset)
            : null,
      );
    } on _UpdateFailure catch (e) {
      return SourceUpdate(
        candidate: previous?.candidate,
        releasePage: inspectedPage ?? previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: e.error,
      );
    } on http.ClientException {
      return SourceUpdate(
        candidate: previous?.candidate,
        releasePage: inspectedPage ?? previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: UpdateError.network,
      );
    } on SocketException {
      return SourceUpdate(
        candidate: previous?.candidate,
        releasePage: inspectedPage ?? previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: UpdateError.offline,
      );
    } on TimeoutException {
      return SourceUpdate(
        candidate: previous?.candidate,
        releasePage: inspectedPage ?? previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: UpdateError.network,
      );
    } catch (_) {
      return SourceUpdate(
        candidate: previous?.candidate,
        releasePage: inspectedPage ?? previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: UpdateError.badMetadata,
      );
    }
  }

  bool _isRateLimit(_MetadataResponse response) =>
      response.status == 429 ||
      (response.status == 403 &&
          (response.headers['x-ratelimit-remaining'] == '0' ||
              (response.headers['retry-after']?.isNotEmpty ?? false)));

  SourceUpdate _rateLimit(_MetadataResponse response, SourceUpdate? previous) {
    final instant = now();
    final latest = instant.add(const Duration(days: 7));
    DateTime? retry;
    final after = int.tryParse(response.headers['retry-after'] ?? '');
    if (after != null && after >= 0 && after <= 31536000) {
      retry = instant.add(Duration(seconds: after));
    } else {
      try {
        retry = HttpDate.parse(response.headers['retry-after'] ?? '');
      } catch (_) {}
    }
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    if (reset != null && reset >= 0 && reset <= 4102444800) {
      final resetDate = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
      if (retry == null || resetDate.isAfter(retry)) retry = resetDate;
    }
    // Respect a real server deadline without adding a daily floor. A manual
    // check may retry once it passes; even date-form headers are week-bounded.
    retry ??= instant.add(const Duration(days: 1));
    if (retry.isBefore(instant)) retry = instant;
    if (retry.isAfter(latest)) retry = latest;
    return SourceUpdate(
      candidate: previous?.candidate,
      releasePage: previous?.releasePage,
      checkedAt: previous?.checkedAt,
      error: UpdateError.rateLimited,
      retryAt: retry,
    );
  }

  // CLAIM(update-network-consent): static requests only; never forward identifiers,
  // credentials or arbitrary release content [update_checker_test]. Redirects
  // are forbidden for the API listing. Only JSON manifests may reach GitHub's
  // asset storage, with bounded HTTPS redirects and byte count; never APKs.
  Future<_MetadataResponse> _request(
    Uri uri, {
    String? etag,
    bool manifest = false,
    required Future<bool> Function() allowed,
  }) async {
    var cancelled = false;
    // A request owns its production client so a timeout can abort connect,
    // headers and body reads without closing the next source's transport.
    final requestClient = clientFactory?.call() ?? client;
    Future<_MetadataResponse> fetch() async {
      var target = uri;
      for (var redirects = 0; redirects <= 3; redirects++) {
        if (cancelled || !await allowed()) {
          throw const _UpdateFailure(UpdateError.network);
        }
        final request = http.Request('GET', target)..followRedirects = false;
        request.headers.addAll({
          'accept': manifest
              ? 'application/octet-stream'
              : 'application/vnd.github+json',
          'user-agent': 'Edge-release-checker',
          'x-github-api-version': '2022-11-28',
          if (etag != null &&
              etag.length <= 256 &&
              !etag.contains('\n') &&
              !etag.contains('\r'))
            'if-none-match': etag,
        });
        final response = await requestClient.send(request);
        if (manifest &&
            {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          final next = Uri.tryParse(response.headers['location'] ?? '');
          if (next == null ||
              next.scheme != 'https' ||
              next.userInfo.isNotEmpty ||
              next.hasPort ||
              next.host != 'release-assets.githubusercontent.com') {
            throw const _UpdateFailure(UpdateError.redirect);
          }
          target = next;
          continue;
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (cancelled || !await allowed()) {
            throw const _UpdateFailure(UpdateError.network);
          }
          if (bytes.length + chunk.length > (manifest ? 262144 : 2097152)) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        return _MetadataResponse(
          response.statusCode,
          response.headers,
          utf8.decode(bytes),
        );
      }
      throw const _UpdateFailure(UpdateError.redirect);
    }

    try {
      return await fetch().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          cancelled = true;
          throw TimeoutException('GitHub metadata timeout');
        },
      );
    } finally {
      if (clientFactory != null) requestClient.close();
    }
  }

  static Future<bool> openRelease(String raw) async {
    final page = ReleasePage.tryParse(raw);
    if (page == null) return false;
    try {
      return await launchUrl(page.uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

class _MetadataResponse {
  const _MetadataResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final String body;
}

class _UpdateFailure implements Exception {
  const _UpdateFailure(this.error);
  final UpdateError error;
}

// The manifest cache never retains arbitrary remote fields or redirect URLs.
Map<String, dynamic> _manifestMetadata(Map<String, dynamic> decoded) => {
  'formatVersion': decoded['formatVersion'],
  'repository': decoded['repository'],
  'tag': decoded['tag'],
  'sourceSha': decoded['sourceSha'],
  'versionCode': decoded['versionCode'],
  'artifacts': [
    for (final artifact in decoded['artifacts'] as List)
      {
        'name': artifact['name'],
        'mode': artifact['mode'],
        'package': artifact['package'],
        'abis': (artifact['abis'] as List).cast<String>().toSet().toList(),
      },
  ],
};

List<Map<String, dynamic>> _assets(Map<String, dynamic> release) =>
    (release['assets'] as List)
        .map((a) => Map<String, dynamic>.from(a as Map))
        .toList();
int _compareSemver(String a, String b) {
  final left = a.split('-');
  final right = b.split('-');
  final leftCore = left.first.split('.').map(int.parse).toList();
  final rightCore = right.first.split('.').map(int.parse).toList();
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
  if (source == ReleaseSource.fork &&
      !const {'profile', 'release'}.contains(mode)) {
    return null;
  }
  final prefix = source == ReleaseSource.official
      ? 'openstrap-edge-$tag'
      : 'openstrap-edge-$tag-dev-$mode';
  for (final abi in abis) {
    if (!const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi)) continue;
    if (names.contains('$prefix-$abi.apk')) return '$prefix-$abi.apk';
  }
  return names.contains('$prefix.apk') ? '$prefix.apk' : null;
}

ReleaseCandidate? selectRelease(
  ReleaseSource source,
  List<Map<String, dynamic>> releases,
  InstalledRelease installed, {
  Map<int, Map<String, dynamic>> manifests = const {},
  bool officialPrereleases = false,
}) {
  final candidates = <ReleaseCandidate>[];
  int? newestUnmatchedBuild;
  final unrecognizedTags = <String>[];
  final forkCodes = <int>{};
  final tags = <String>{};
  final ids = <int>{};
  final officialTags = releases
      .where(
        (r) =>
            r['draft'] == false &&
            r['tag_name'] is String &&
            supportedTag(source, r['tag_name'] as String) &&
            r['prerelease'] is bool &&
            (officialPrereleases ||
                (r['prerelease'] == false &&
                    !(r['tag_name'] as String).contains('-'))),
      )
      .map((r) => r['tag_name'] as String)
      .toList();
  if (source == ReleaseSource.official) {
    officialTags.sort((a, b) => _compareSemver(b.substring(1), a.substring(1)));
  }
  for (final release in releases) {
    final tag = release['tag_name'];
    final id = release['id'];
    if (release['draft'] != false ||
        tag is! String ||
        !supportedTag(source, tag) ||
        id is! int ||
        id <= 0 ||
        release['prerelease'] is! bool ||
        (source == ReleaseSource.official &&
            !officialPrereleases &&
            (release['prerelease'] == true || tag.contains('-')))) {
      continue;
    }
    if (!tags.add(tag) || !ids.add(id)) {
      throw const FormatException('Ambiguous release');
    }
    final names = _assets(release).map((a) => a['name'] as String).toList();
    final asset = matchAsset(
      source,
      tag,
      installed.mode,
      installed.abis,
      names,
    );
    if (asset == null && source == ReleaseSource.official) {
      if (tag == officialTags.first) return null;
      continue;
    }
    int? build;
    if (source == ReleaseSource.fork) {
      final manifest = manifests[id];
      if (manifest == null) {
        unrecognizedTags.add(tag);
        continue;
      }

      if (manifest['formatVersion'] != 1 ||
          manifest['repository'] != source.repository ||
          manifest['tag'] != tag ||
          manifest['sourceSha'] is! String ||
          !RegExp(
            r'^[a-f0-9]{40}$',
          ).hasMatch(manifest['sourceSha'] as String) ||
          manifest['versionCode'] is! int ||
          (manifest['versionCode'] as int) <= 0) {
        throw const FormatException('Bad manifest');
      }
      build = manifest['versionCode'] as int;
      if (!forkCodes.add(build)) {
        throw const FormatException('Ambiguous fork sequence');
      }
      final artifacts = (manifest['artifacts'] as List)
          .map((a) => Map<String, dynamic>.from(a as Map))
          .toList();
      final seen = <String>{};
      for (final artifact in artifacts) {
        final name = artifact['name'] as String;
        final mode = artifact['mode'];
        final abis = (artifact['abis'] as List).cast<String>();
        if (!seen.add(name) ||
            !names.contains(name) ||
            !const {'profile', 'release'}.contains(mode) ||
            artifact['package'] != 'wtf.openstrap.openstrap_edge.dev' ||
            abis.isEmpty ||
            abis.any(
              (a) => !const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(a),
            ) ||
            matchAsset(source, tag, mode as String, abis, [name]) != name) {
          throw const FormatException('Ambiguous artifact');
        }
      }
      if (asset == null) {
        if (newestUnmatchedBuild == null || build > newestUnmatchedBuild) {
          newestUnmatchedBuild = build;
        }
        continue;
      }
      final match = artifacts.where((a) => a['name'] == asset).toList();
      if (match.length != 1 || match.single['mode'] != installed.mode) {
        throw const FormatException('Missing artifact');
      }
      if (installed.abis.isNotEmpty &&
          !(match.single['abis'] as List).any(installed.abis.contains)) {
        if (newestUnmatchedBuild == null || build > newestUnmatchedBuild) {
          newestUnmatchedBuild = build;
        }
        continue;
      }
    }
    candidates.add(
      ReleaseCandidate(
        source: source,
        id: id,
        tag: tag,
        asset: asset!,
        prerelease:
            release['prerelease'] == true ||
            (source == ReleaseSource.official && tag.contains('-')),
        build: build,
      ).forInstall(installed),
    );
  }
  candidates.sort(
    (a, b) => source == ReleaseSource.official
        ? _compareSemver(b.tag.substring(1), a.tag.substring(1))
        : b.build!.compareTo(a.build!),
  );
  if (candidates.length > 1 &&
      source == ReleaseSource.fork &&
      candidates[0].build == candidates[1].build) {
    throw const FormatException('Ambiguous fork sequence');
  }
  if (source == ReleaseSource.fork &&
      newestUnmatchedBuild != null &&
      (candidates.isEmpty || newestUnmatchedBuild >= candidates.first.build!)) {
    return null;
  }
  if (source == ReleaseSource.fork &&
      unrecognizedTags.any(
        (tag) => candidates.isEmpty || tag.compareTo(candidates.first.tag) > 0,
      )) {
    return null;
  }
  return candidates.firstOrNull;
}
