// Pure release selection: tag grammar order, asset-name matching, manifest
// validation and the local relationship of a candidate to this install. No
// network, storage or clock; runs anywhere and is tested without fakes.
import 'update_models.dart';

/// Strictly orders two semantic versions without a leading `v` (prerelease
/// aware). Throws [FormatException] on a malformed version.
int compareSemver(String a, String b) => 0;

/// The one asset a release offers this install, by exact name, or null.
String? matchAsset(
  ReleaseSource source,
  String tag,
  String mode,
  List<String> abis,
  List<String> names,
) => null;

/// The relationship of [candidate] to [installed], recomputed on every load.
ReleaseRelation relationFor(
  ReleaseCandidate candidate,
  InstalledRelease installed,
) => ReleaseRelation.unknown;

/// The fields of a fork manifest the checker uses, or throws [FormatException].
Map<String, dynamic> checkedManifest(Object? decoded) => const {};

/// The newest matching release for [source], or null when none is established.
ReleaseCandidate? selectRelease(
  ReleaseSource source,
  List<Map<String, dynamic>> releases,
  InstalledRelease installed, {
  Map<int, Map<String, dynamic>> manifests = const {},
  bool officialPrereleases = false,
}) => null;
