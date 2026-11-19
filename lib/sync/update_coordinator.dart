// UpdateCoordinator owns release discovery and the observable update state.
// No APK bytes, installer or companion endpoint participates; remote text
// never becomes a navigation destination (spec §5). UpdateStore owns every
// mutable fact; update_http.dart owns every byte on the wire; update_selection
// owns every comparison. This class sequences them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../data/json_payload_lane.dart';
import 'update_http.dart';
import 'update_models.dart';
import 'update_selection.dart';
import 'update_store.dart';
export 'update_models.dart';

const updateTaskName = 'edge.github.release-check.v1';

/// How long a cached announcement stays eligible to be (re)offered.
const _announceWindow = Duration(days: 1);

class UpdateCoordinator extends ChangeNotifier {
  UpdateCoordinator({
    required this.store,
    required this.client,
    required this.installed,
    required this.now,
    required this.unmetered,
    required this.schedule,
    this.onRelease,
    this.clientFactory,
    this.jitter,
    this.lane,
  });
  final UpdateStore store;
  final http.Client client;
  final http.Client Function()? clientFactory;
  final InstalledRelease installed;
  final DateTime Function() now;
  final Future<bool> Function() unmetered;
  final Future<void> Function(bool) schedule;
  final Future<void> Function(ReleaseCandidate)? onRelease;

  /// Up to six hours added to the daily slot, so devices do not all check at
  /// one minute. Null in tests that pin exact slots.
  final Duration Function()? jitter;

  /// Where metadata JSON is parsed (a registered worker); defaults to the shared
  /// isolate lane.
  final JsonPayloadDecodeLane? lane;

  UpdateSnapshot snapshot = const UpdateSnapshot();
  UpdateLease? _activeLease;
  Future<CheckOutcome>? _checking;
  bool _closed = false;

  /// An install whose identity could not be established gets a visible
  /// unsupported state, never fabricated arm64/release defaults.
  bool get supported => installed.fork != null;

  void _publish() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    client.close();
    super.dispose();
  }

  // ── state ──────────────────────────────────────────────────────────────────

  UpdatePhase _phase(bool enabled, Map<ReleaseSource, SourceUpdate> sources) {
    if (sources.isEmpty) return enabled ? UpdatePhase.notChecked : UpdatePhase.off;
    if (sources.values.any(
      (v) => v.candidate != null && v.candidate!.relation.announces && v.error == null,
    )) {
      return UpdatePhase.available;
    }
    if (sources.values.any((v) => v.error != null)) return UpdatePhase.error;
    return UpdatePhase.current;
  }

  /// Read the store and recompute every relationship against THIS install, so
  /// an app upgrade changes cached answers without a request.
  Future<void> load() async {
    final saved = await store.read();
    final sources = {
      for (final entry in saved.sources.entries)
        entry.key: entry.value.withRelation((c) => relationFor(c, installed)),
    };
    final checking = _activeLease != null && await store.valid(_activeLease!);
    snapshot = UpdateSnapshot(
      enabled: saved.enabled,
      officialPrereleases: saved.officialPrereleases,
      authorizationReset: saved.authorizationReset,
      phase: checking ? UpdatePhase.checking : _phase(saved.enabled, sources),
      sources: sources,
    );
    _publish();
  }

  Future<void> acknowledgeReset() async {
    await store.acknowledgeReset();
    await load();
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

  // ── announcements ──────────────────────────────────────────────────────────

  Future<void> _notify(ReleaseCandidate candidate) async {
    try {
      await onRelease?.call(candidate).timeout(const Duration(seconds: 10));
    } catch (_) {
      /* presentation cannot hold the network lease indefinitely */
    }
  }

  bool _fresh(SourceUpdate r) {
    final age = r.checkedAt == null ? null : now().difference(r.checkedAt!);
    return r.error == null &&
        r.candidate != null &&
        r.candidate!.relation.announces &&
        age != null &&
        !age.isNegative &&
        age <= _announceWindow;
  }

  /// Offer every fresh cached announcement. The claim ledger makes repeats
  /// harmless: a delivered release is consumed, a held one is reused.
  Future<void> _offerCached() async {
    if (_closed || !snapshot.enabled) return;
    for (final result in snapshot.sources.values) {
      if (_fresh(result)) await _notify(result.candidate!);
    }
  }

  /// A recovery pass owned by the shared alert policy: re-offer held cached
  /// candidates after revalidating the relationship against this install and
  /// consent, with no network request. Held claims that no longer deserve an
  /// alert (the install caught up, consent ended) are given back.
  Future<void> releaseHeld() async {
    if (_closed) return;
    await load();
    if (!snapshot.enabled) {
      await store.discardHeld();
      return;
    }
    await store.discardHeld(
      except: {
        for (final r in snapshot.sources.values)
          if (_fresh(r)) r.candidate!.identity,
      },
    );
    await _offerCached();
  }

  // ── checking ───────────────────────────────────────────────────────────────

  /// One check batch. Returns what happened; nothing is thrown for the
  /// expected refusals. [manual] is the one-time Check now authorization.
  Future<CheckOutcome> check({bool manual = false}) {
    if (_closed) return Future.value(const CheckDeferred(DeferReason.closed));
    final running = _checking;
    if (running != null) return running;
    final task = _check(manual: manual).whenComplete(() => _checking = null);
    return _checking = task;
  }

  Future<CheckOutcome> _check({required bool manual}) async {
    UpdateLease? lease;
    try {
      await load();
      if (!supported) return const CheckDeferred(DeferReason.unsupported);
      if (!manual && !snapshot.enabled) {
        return const CheckDeferred(DeferReason.disabled);
      }
      // Quiet hours and permission do not spend a release claim; a later pass
      // may deliver the fresh cached announcement without another request.
      await _offerCached();
      if (!manual && !await unmetered()) {
        snapshot = UpdateSnapshot(
          enabled: true,
          phase: snapshot.phase,
          sources: snapshot.sources,
          officialPrereleases: snapshot.officialPrereleases,
          waiting: true,
        );
        _publish();
        return const CheckDeferred(DeferReason.metered);
      }
      lease = await store.claim(
        now(),
        manual: manual,
        jitter: jitter?.call() ?? Duration.zero,
      );
      if (lease == null) {
        return CheckDeferred(manual ? DeferReason.throttled : DeferReason.notDue);
      }
      _activeLease = lease;
      snapshot = UpdateSnapshot(
        enabled: snapshot.enabled,
        phase: UpdatePhase.checking,
        sources: snapshot.sources,
        officialPrereleases: snapshot.officialPrereleases,
      );
      _publish();
      CheckOutcome outcome = const CheckCompleted();
      for (final source in ReleaseSource.values) {
        if (!await store.valid(lease)) {
          outcome = const CheckRefused(DeferReason.disabled);
          break;
        }
        await store.renew(lease, now());
        final previous = snapshot.sources[source];
        if (previous?.retryAt != null && now().isBefore(previous!.retryAt!)) {
          continue;
        }
        final result = await _source(source, previous, lease, automatic: !manual);
        if (!await store.save(lease, source, result)) {
          outcome = const CheckRefused(DeferReason.disabled);
          break;
        }
        await load();
        // Only opted-in installs are told: a manual request while disabled does
        // not authorize a continuing outbound alert channel.
        if (!_closed &&
            snapshot.enabled &&
            result.error == null &&
            result.candidate != null &&
            snapshot.sources[source]?.candidate?.relation.announces == true &&
            await store.valid(lease)) {
          await _notify(snapshot.sources[source]!.candidate!);
        }
      }
      return outcome;
    } catch (_) {
      snapshot = UpdateSnapshot(
        enabled: snapshot.enabled,
        phase: UpdatePhase.error,
        sources: {
          for (final source in ReleaseSource.values)
            source: const SourceUpdate(error: UpdateError.storage),
        },
      );
      _publish();
      return const CheckFailed(UpdateError.storage);
    } finally {
      _activeLease = null;
      if (lease != null) {
        try {
          await store.release(lease);
          await load();
        } catch (_) {
          /* the snapshot already says storage failed, or the next load will */
        }
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
    SourceUpdate failure(UpdateError error) => SourceUpdate(
      candidate: previous?.candidate,
      releasePage: inspectedPage ?? previous?.releasePage,
      checkedAt: previous?.checkedAt,
      error: error,
    );
    final wire = MetadataClient(
      client: client,
      clientFactory: clientFactory,
      lane: lane ?? const IsolateJsonPayloadLane(),
      allowed: () async =>
          !_closed &&
          await store.valid(lease) &&
          (!automatic || await unmetered()),
    );
    try {
      final releases = <Map<String, dynamic>>[];
      String? etag;
      var paginated = false;
      for (var page = 1; page <= maxListingPages; page++) {
        final response = await wire.get(
          listingUri(source, page),
          etag: page == 1 ? previous?.etag : null,
        );
        if (response.status == 304) {
          return await _notModified(source, previous, page);
        }
        if (isRateLimit(response)) return _rateLimited(response, previous);
        if (response.status >= 300 && response.status < 400) {
          throw const UpdateFailure(UpdateError.redirect);
        }
        if (response.status == 401 || response.status == 403) {
          throw const UpdateFailure(UpdateError.refused);
        }
        if (response.status != 200) throw const UpdateFailure(UpdateError.network);
        final decoded = await wire.parse(response.body);
        if (decoded is! List || decoded.length > 100) {
          throw const FormatException('Bad listing');
        }
        releases.addAll(decoded.map((r) => Map<String, dynamic>.from(r as Map)));
        if (page == 1) etag = response.headers['etag'];
        if (!linkNamesNextPage(source, response.headers['link'], page)) break;
        paginated = true;
        if (page == maxListingPages) {
          throw const UpdateFailure(UpdateError.incomplete);
        }
      }
      final knownTags = [
        for (final r in releases)
          if (r['draft'] == false &&
              r['tag_name'] is String &&
              supportedTag(source, r['tag_name'] as String) &&
              (source == ReleaseSource.fork ||
                  snapshot.officialPrereleases ||
                  (r['prerelease'] == false &&
                      !(r['tag_name'] as String).contains('-'))))
            r['tag_name'] as String,
      ]..sort(
          (a, b) => source == ReleaseSource.official
              ? compareSemver(b.substring(1), a.substring(1))
              : b.compareTo(a),
        );
      if (knownTags.isNotEmpty) {
        inspectedPage = ReleasePage.forRelease(source, knownTags.first);
      }
      final manifests = <int, Map<String, dynamic>>{};
      if (source == ReleaseSource.fork) {
        final rate = await _collectManifests(
          source,
          releases,
          lease,
          wire,
          manifests,
          previous,
        );
        if (rate != null) return rate;
      }
      final selected = selectRelease(
        source,
        releases,
        installed,
        manifests: manifests,
        officialPrereleases: snapshot.officialPrereleases,
      );
      if (selected != null) {
        return SourceUpdate(
          candidate: selected,
          releasePage: selected.page,
          checkedAt: now(),
          etag: paginated ? null : etag,
        );
      }
      // Nothing established. An empty list is a fact; a list we could not
      // match or validate keeps the dated last good metadata beside the error.
      final retained = releases.isEmpty ? null : previous?.candidate;
      return SourceUpdate(
        candidate: retained,
        releasePage: inspectedPage,
        checkedAt: retained == null ? now() : previous!.checkedAt,
        etag: paginated ? null : etag,
        error: releases.isEmpty ? UpdateError.noRelease : UpdateError.noAsset,
      );
    } on UpdateFailure catch (e) {
      return failure(e.error);
    } on http.ClientException {
      return failure(UpdateError.network);
    } on SocketException {
      return failure(UpdateError.offline);
    } on TimeoutException {
      return failure(UpdateError.network);
    } catch (_) {
      return failure(UpdateError.badMetadata);
    }
  }

  /// A 304 refreshes freshness only when what it stands for is complete: a
  /// stored result for page 1, and for a fork candidate its validated manifest
  /// still cached. Otherwise it is a retryable failure, never "current".
  Future<SourceUpdate> _notModified(
    ReleaseSource source,
    SourceUpdate? previous,
    int page,
  ) async {
    if (page != 1 || previous?.checkedAt == null) {
      throw const UpdateFailure(UpdateError.network);
    }
    final c = previous!.candidate;
    if (source == ReleaseSource.fork &&
        c != null &&
        (c.build == null || !await store.hasManifest(c.tag, c.build!))) {
      throw const UpdateFailure(UpdateError.incomplete);
    }
    return SourceUpdate(
      candidate: previous.candidate,
      releasePage: previous.releasePage,
      checkedAt: now(),
      etag: previous.etag,
      error: previous.error,
    );
  }

  /// Fetch (at most [maxNewManifests] new) and validate the fork manifests of
  /// the newest relevant releases, newest tag first. Positive AND negative
  /// results are cached by release, asset id and modification time, so a broken
  /// historical manifest costs one request, and a large cold catalog makes
  /// progress across checks. Returns a rate-limit result, or null.
  Future<SourceUpdate?> _collectManifests(
    ReleaseSource source,
    List<Map<String, dynamic>> releases,
    UpdateLease lease,
    MetadataClient wire,
    Map<int, Map<String, dynamic>> manifests,
    SourceUpdate? previous,
  ) async {
    final relevant = [
      for (final r in releases)
        if (r['draft'] == false &&
            r['tag_name'] is String &&
            supportedTag(source, r['tag_name'] as String))
          r,
    ]..sort((a, b) => (b['tag_name'] as String).compareTo(a['tag_name'] as String));
    var fetched = 0;
    for (final release in relevant) {
      try {
        final assets = release['assets'];
        if (assets is! List) continue;
        final declared = [
          for (final a in assets)
            if (a is Map && a['name'] == 'edge-release.json') a,
        ];
        if (declared.length != 1) continue;
        final asset = declared.single;
        final id = asset['id'];
        final releaseId = release['id'];
        if (id is! int || id <= 0 || releaseId is! int || releaseId <= 0) {
          continue;
        }
        final updatedAt = asset['updated_at'];
        final stamp = updatedAt == null ? null : DateTime.tryParse('$updatedAt');
        if (updatedAt != null && stamp == null) continue;
        final tag = release['tag_name'] as String;
        final key = jsonEncode([
          source.name,
          releaseId,
          tag,
          id,
          stamp?.toUtc().toIso8601String(),
        ]);
        final cached = await store.manifest(key);
        if (cached != null) {
          if (cached['unusable'] == true) continue;
          try {
            final checked = checkedManifest(cached);
            if (checked['tag'] == tag) {
              manifests[releaseId] = checked;
              continue;
            }
          } on FormatException {
            /* a stale or damaged entry is refetched below */
          }
        }
        if (fetched >= maxNewManifests) {
          throw const UpdateFailure(UpdateError.incomplete);
        }
        fetched++;
        final response = await wire.get(manifestUri(source, id), manifest: true);
        if (isRateLimit(response)) return _rateLimited(response, previous);
        Map<String, dynamic>? checked;
        if (response.status == 200) {
          try {
            checked = checkedManifest(await wire.parse(response.body));
            if (checked['tag'] != tag) checked = null;
          } on FormatException {
            checked = null;
          }
        } else if (response.status != 404) {
          throw const UpdateFailure(UpdateError.network);
        }
        final saved = await store.saveManifest(
          lease,
          key,
          checked ?? const {'unusable': true},
        );
        if (!saved) throw const UpdateFailure(UpdateError.network);
        if (checked != null) manifests[releaseId] = checked;
      } on TypeError {
        continue; // one malformed historical release is not the catalog
      }
    }
    return null;
  }

  // A rate limit keeps the server's own deadline beside the due slot.
  SourceUpdate _rateLimited(MetadataResponse r, SourceUpdate? previous) =>
      SourceUpdate(
        candidate: previous?.candidate,
        releasePage: previous?.releasePage,
        checkedAt: previous?.checkedAt,
        error: UpdateError.rateLimited,
        retryAt: retryDeadline(r, now()),
      );

  /// Open a canonical release page in the browser. The one outward action.
  static Future<bool> openRelease(ReleasePage page) async {
    try {
      return await launchUrl(page.uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
