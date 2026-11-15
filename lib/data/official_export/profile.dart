// The reviewed v0.11.3 contract. Mutable export state belongs to the coordinator.
import 'dart:convert';
import 'package:crypto/crypto.dart';

const officialTargetTag = 'v0.11.3';
const officialTargetSha = '27a4c4857f272d9b6d290284091def0d86abff20';

class OfficialProfile {
  factory OfficialProfile.parse(String text) =>
      OfficialProfile.fromJson(jsonDecode(text));
  OfficialProfile.fromJson(Map<String, dynamic> json)
    : identity = (json['source'] as Map).cast<String, Object?>(),
      source = (json['sourceTables'] as Map).cast<String, dynamic>(),
      target = (json['target'] as Map).cast<String, dynamic>(),
      policies = (json['policies'] as Map).cast<String, String>(),
      enums = (json['enums'] as Map).cast<String, dynamic>() {
    if (target['tag'] != officialTargetTag ||
        target['sha'] != officialTargetSha ||
        target['schema'] != 58) {
      throw const FormatException('Unsupported official compatibility profile');
    }
  }
  final Map<String, dynamic> source, target, enums;
  final Map<String, Object?> identity;
  final Map<String, String> policies;
  Set<String> sourceColumns(String table) => {
    for (final c in (source[table] as List? ?? const [])) c['name'] as String,
  };
  List<String> unclassified(Map<String, Set<String>> actual) => [
    for (final e in actual.entries)
      if (!policies.containsKey(e.key))
        e.key
      else ...[
        for (final c in e.value.difference(sourceColumns(e.key))) '${e.key}.$c',
      ],
  ];
  static String hash(String text) =>
      sha256.convert(utf8.encode(text)).toString();
}

class ExportSkip {
  const ExportSkip(
    this.table,
    this.rows,
    this.reason, {
    this.identity,
    this.columns = const [],
  });
  final String table, reason;
  final int rows;
  final String? identity;
  final List<String> columns;
  Map<String, Object?> toJson() => {
    'table': table,
    'rows': rows,
    'reason': reason,
    'identity': identity,
    'columns': columns,
  };
}

class OfficialExportReport {
  OfficialExportReport({
    required this.skipped,
    required this.sourceInventory,
    required this.outputInventory,
    required this.profileHash,
    this.days = const {},
    this.sourceIdentity = const {},
    this.snapshotHash = '',
  });
  final List<ExportSkip> skipped;
  final Map<String, Object?> sourceInventory, outputInventory;
  final String profileHash;
  final Map<String, String> days;
  final Map<String, Object?> sourceIdentity;
  final String snapshotHash;
  Map<String, Object?> toJson() => {
    'version': 1,
    'target': {
      'tag': officialTargetTag,
      'sha': officialTargetSha,
      'schema': 58,
      'algorithm': 113,
    },
    'profile_sha256': profileHash,
    'source_identity': sourceIdentity,
    'snapshot_sha256': snapshotHash,
    'snapshot_boundary':
        'SQL VACUUM INTO with stable portable preferences/files',
    'source': sourceInventory,
    'official': outputInventory,
    'skipped': [for (final s in skipped) s.toJson()],
    'days': days,
    'normalizations': [
      'on_wrist/hr_valid cleared by official importer',
      'skin temperature sentinel <= -49.995 cleared',
      'primary pairing not imported',
      'live coverage IDs deduplicated by target',
      'dismissed legacy workout suggestions create decided activity-review rows in target',
      'fork daily and session scores cleared',
    ],
    'limits': [
      'Fresh official install only',
      'Some older workout details stay blank after recordings were removed',
      'Credentials need reentry; pair locally',
    ],
  };
}

/// Owned by one coordinator; checked between bounded I/O operations.
class OfficialExportCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const ExportCancellation();
  }
}

abstract interface class OfficialExportProgress {
  void update(String stage, int? count);
}

abstract interface class OfficialSnapshot {
  Future<String> capture(String destinationPath);
}

abstract interface class OfficialRecoveryChoice {
  Future<bool?> choose();
}

class ExportCancellation implements Exception {
  const ExportCancellation();
}

// A row identity contains only the fixed, reviewed primary-key fields.
String officialRowIdentity(
  Map<String, Object?> row,
  List<String> primaryKeys,
) => jsonEncode({for (final key in primaryKeys) key: row[key]});

/// Stable release tags use semantic versions; a rollback is not a newer build.
bool isNewerOfficialRelease(String tag) {
  List<int>? parts(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
    return match == null
        ? null
        : [int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!)];
  }

  final latest = parts(tag), tested = parts(officialTargetTag)!;
  if (latest == null) return false;
  for (var i = 0; i < 3; i++) {
    if (latest[i] != tested[i]) return latest[i] > tested[i];
  }
  return false;
}
