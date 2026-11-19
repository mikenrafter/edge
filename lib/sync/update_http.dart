// The one outbound adapter of the update checker: bounded, serialized GETs of
// GitHub release metadata. Nothing here can request an APK: the listing is a
// fixed API path, a manifest is an API asset id whose redirect may only go to
// GitHub's asset host, and every hop re-checks consent through [allowed].
//
// CLAIM(release-check-consent) / CLAIM(release-check-page-only): static headers
// only (no installed version, ABI, package, device identifier, health data or
// credential), no redirect for the listing, manifest redirects limited to one
// reviewed host, and no body ever becomes a navigation target.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/json_payload_lane.dart';
import 'update_models.dart';

/// Reviewed numeric host policy: the API host, the one asset-storage host.
const githubApiHost = 'api.github.com';
const githubAssetHost = 'release-assets.githubusercontent.com';

const maxListingBytes = 2 * 1024 * 1024;
const maxManifestBytes = 256 * 1024;
const requestTimeout = Duration(seconds: 12);
const maxListingPages = 3;
const maxNewManifests = 8;

class MetadataResponse {
  const MetadataResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final String body;
}

/// A failure with a specific user-visible reason.
class UpdateFailure implements Exception {
  const UpdateFailure(this.error);
  final UpdateError error;
}

/// `/repos/<owner>/<name>/releases` for [source] with [page] (1-based).
Uri listingUri(ReleaseSource source, int page) => Uri.https(
  githubApiHost,
  '/repos/${source.repository}/releases',
  {'per_page': '100', if (page > 1) 'page': '$page'},
);

Uri manifestUri(ReleaseSource source, int assetId) => Uri.https(
  githubApiHost,
  '/repos/${source.repository}/releases/assets/$assetId',
);

/// The next-page URL GitHub named in a Link header, accepted only when it is
/// the fixed `/repos/...` form or the numeric `/repositories/<id>/...` form of
/// THIS source for page+1. The request itself still uses the fixed path:
/// reconstructing the checked page number is a deliberate constrained choice
/// (GitHub recommends following Link metadata); a foreign URL is never followed.
bool linkNamesNextPage(ReleaseSource source, String? link, int page) {
  final next = RegExp(r'<([^>]+)>;\s*rel="next"').firstMatch(link ?? '');
  if (next == null) return false;
  final supplied = Uri.tryParse(next.group(1)!);
  final expected = listingUri(source, page + 1);
  final numeric = Uri.https(
    githubApiHost,
    '/repositories/${source.repositoryId}/releases',
    {'per_page': '100', 'page': '${page + 1}'},
  );
  if (supplied != expected && supplied != numeric) {
    throw const UpdateFailure(UpdateError.incomplete);
  }
  return true;
}

class MetadataClient {
  MetadataClient({
    required this.client,
    this.clientFactory,
    required this.allowed,
    this.lane = const IsolateJsonPayloadLane(),
  });
  final http.Client client;
  final http.Client Function()? clientFactory;

  /// Consent, generation and network eligibility, asked before every hop and
  /// every chunk of a body.
  final Future<bool> Function() allowed;
  final JsonPayloadDecodeLane lane;

  /// A GET with static headers. [manifest] allows the one reviewed redirect.
  Future<MetadataResponse> get(
    Uri uri, {
    String? etag,
    bool manifest = false,
  }) async {
    var cancelled = false;
    // A request owns its production client so a timeout can abort connect,
    // headers and body reads without closing the next source's transport.
    final requestClient = clientFactory?.call() ?? client;
    Future<MetadataResponse> fetch() async {
      var target = uri;
      for (var redirects = 0; redirects <= 3; redirects++) {
        if (cancelled || !await allowed()) {
          throw const UpdateFailure(UpdateError.network);
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
            const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          final next = Uri.tryParse(response.headers['location'] ?? '');
          if (next == null ||
              next.scheme != 'https' ||
              next.userInfo.isNotEmpty ||
              next.hasPort ||
              next.host != githubAssetHost) {
            throw const UpdateFailure(UpdateError.redirect);
          }
          target = next;
          continue;
        }
        final limit = manifest ? maxManifestBytes : maxListingBytes;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (cancelled || !await allowed()) {
            throw const UpdateFailure(UpdateError.network);
          }
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('Metadata too large');
          }
          bytes.addAll(chunk);
        }
        return MetadataResponse(
          response.statusCode,
          response.headers,
          utf8.decode(bytes),
        );
      }
      throw const UpdateFailure(UpdateError.redirect);
    }

    try {
      return await fetch().timeout(
        requestTimeout,
        onTimeout: () {
          cancelled = true;
          throw TimeoutException('GitHub metadata timeout');
        },
      );
    } finally {
      if (clientFactory != null) requestClient.close();
    }
  }

  /// Parse a bounded body in the registered JSON worker, never on the UI
  /// isolate. A body that is not valid JSON is a [FormatException].
  Future<Object> parse(String body) async {
    final result = await lane.run(
      JsonPayloadsInput(values: [body], encode: false),
    );
    final value = result.values.single;
    if (value == null) throw const FormatException('Invalid JSON');
    return value;
  }
}

/// A 429, or a 403 carrying rate-limit evidence.
bool isRateLimit(MetadataResponse r) =>
    r.status == 429 ||
    (r.status == 403 &&
        (r.headers['x-ratelimit-remaining'] == '0' ||
            (r.headers['retry-after']?.isNotEmpty ?? false)));

/// The server's own retry deadline: Retry-After (seconds or HTTP date) and the
/// rate-limit reset, parsed defensively and capped at seven days. Kept apart
/// from our own due slot so Check now can retry once it has passed.
DateTime retryDeadline(MetadataResponse r, DateTime now) {
  final latest = now.add(const Duration(days: 7));
  DateTime? retry;
  final after = int.tryParse(r.headers['retry-after'] ?? '');
  if (after != null && after >= 0 && after <= 31536000) {
    retry = now.add(Duration(seconds: after));
  } else {
    try {
      retry = HttpDate.parse(r.headers['retry-after'] ?? '');
    } catch (_) {}
  }
  final reset = int.tryParse(r.headers['x-ratelimit-reset'] ?? '');
  if (reset != null && reset >= 0 && reset <= 4102444800) {
    final resetDate = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    if (retry == null || resetDate.isAfter(retry)) retry = resetDate;
  }
  // A real server deadline needs no daily floor; absent one, wait a day.
  retry ??= now.add(const Duration(days: 1));
  if (retry.isBefore(now)) retry = now;
  if (retry.isAfter(latest)) retry = latest;
  return retry;
}
