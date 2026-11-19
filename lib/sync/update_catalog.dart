// Owns one source's bounded listing continuation. UpdateStore fences every
// write; page URLs are reconstructed only after validating the source's Link.
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'update_http.dart';
import 'update_models.dart';
import 'update_store.dart';

class CatalogResponse implements Exception {
  const CatalogResponse(this.response, this.page);
  final MetadataResponse response;
  final int page;
}

class UpdateCatalog {
  UpdateCatalog(this.source, this.store, this.lease, this.wire, this.progress);
  final ReleaseSource source;
  final UpdateStore store;
  final UpdateLease lease;
  final MetadataClient wire;
  final Map<String, dynamic> progress;
  static const maxPages = 64;
  static const maxRows = 1024;
  final rows = <Map<String, dynamic>>[];
  final hashes = <String>[];
  int next = 1;
  int verify = 2;
  int requests = 0;
  final _freshPages = <int>{};
  bool sawAny = false;
  String? etag;
  bool get paginated => hashes.length > 1;

  Future<({List<Map<String, dynamic>> rows, String hash, bool next})> _page(int page,
      {String? conditional}) async {
    if (requests >= maxListingPages) throw const UpdateFailure(UpdateError.incomplete);
    requests++;
    final response = await wire.get(listingUri(source, page), etag: conditional);
    if (response.status == 304 || isRateLimit(response)) throw CatalogResponse(response, page);
    if (response.status >= 300 && response.status < 400) {
      throw const UpdateFailure(UpdateError.redirect);
    }
    if (response.status == 401 || response.status == 403) {
      throw const UpdateFailure(UpdateError.refused);
    }
    if (response.status != 200) throw const UpdateFailure(UpdateError.network);
    final decoded = await wire.parse(response.body);
    if (decoded is! List || decoded.length > 100) throw const FormatException('Bad listing');
    _lastNonempty = decoded.isNotEmpty;
    final hasNext = linkNamesNextPage(source, response.headers['link'], page);
    if (page == 1) etag = response.headers['etag'];
    final normalized = <Map<String, dynamic>>[];
    for (final value in decoded) {
      final row = Map<String, dynamic>.from(value as Map);
      // Unsupported and draft rows carry no selection fact. Retain their
      // presence separately so an unmatched catalog is never reported empty.
      if (row['draft'] != false || row['tag_name'] is! String ||
          !supportedTag(source, row['tag_name'] as String)) continue;
      final assets = row['assets'];
      normalized.add({
        'id': row['id'], 'tag_name': row['tag_name'],
        'draft': row['draft'], 'prerelease': row['prerelease'],
        'assets': assets is! List ? null : [for (final a in assets)
          if (a is Map) {'id': a['id'], 'name': a['name'], 'updated_at': a['updated_at']}
          else null],
      });
    }
    _freshPages.add(page);
    return (rows: normalized,
      hash: sha256.convert(utf8.encode('${hasNext ? 1 : 0}:${response.body}')).toString(),
      next: hasNext);
  }

  Future<void> save() async {
    progress['catalog'] = {'rows': rows, 'hashes': hashes, 'next': next,
      'verify': verify, 'sawAny': sawAny};
    if (!await store.saveProgress(lease, source, progress)) {
      throw const UpdateFailure(UpdateError.network);
    }
  }

  Future<void> collect({String? conditional}) async {
    final saved = progress['catalog'];
    if (saved is Map) {
      try {
        rows.addAll((saved['rows'] as List).map((r) => Map<String, dynamic>.from(r as Map)));
        hashes.addAll((saved['hashes'] as List).cast<String>());
        next = saved['next'] as int;
        verify = saved['verify'] as int;
        sawAny = saved['sawAny'] as bool;
        if (hashes.isEmpty || hashes.length > maxPages || rows.length > maxRows ||
            (next != 0 && next != hashes.length + 1) || verify < 2 ||
            verify > hashes.length + 1) throw const FormatException();
      } catch (_) {
        rows.clear(); hashes.clear(); next = 1; verify = 2; sawAny = false;
      }
    }
    final first = await _page(1, conditional: hashes.isEmpty || (hashes.length == 1 && next == 0) ? conditional : null);
    if (hashes.isEmpty || hashes.first != first.hash) {
      progress.clear(); rows.clear(); hashes.clear(); verify = 2;
      rows.addAll(first.rows); hashes.add(first.hash);
      // The raw listing's emptiness is encoded separately below by _page.
      sawAny = first.rows.isNotEmpty || _lastNonempty;
      next = first.next ? 2 : 0;
    }
    await save();
    while (next != 0 && requests < maxListingPages) {
      if (next > maxPages) throw const UpdateFailure(UpdateError.incomplete);
      final page = await _page(next);
      if (rows.length + page.rows.length > maxRows) {
        throw const UpdateFailure(UpdateError.incomplete);
      }
      rows.addAll(page.rows); hashes.add(page.hash);
      sawAny = sawAny || _lastNonempty;
      next = page.next ? next + 1 : 0;
      await save();
    }
    if (next != 0) throw const UpdateFailure(UpdateError.incomplete);
  }

  bool _lastNonempty = false;

  /// Re-read every later page before publishing a completed selection. A
  /// changed page invalidates both continuation and selection, even if page 1
  /// kept its ETag. Work stays within this batch's three listing requests.
  Future<bool> validate() async {
    while (verify <= hashes.length) {
      if (_freshPages.contains(verify)) { verify++; continue; }
      if (requests >= maxListingPages) break;
      final page = await _page(verify);
      if (page.hash != hashes[verify - 1]) {
        progress.clear(); rows.clear(); hashes.clear(); next = 1; verify = 2;
        // Do not save an invalid continuation; the next check starts at page 1.
        if (!await store.saveProgress(lease, source, {})) {
          throw const UpdateFailure(UpdateError.network);
        }
        return false;
      }
      verify++;
      await save();
    }
    if (verify <= hashes.length) return false;
    verify = 2;
    await save();
    return true;
  }
}
