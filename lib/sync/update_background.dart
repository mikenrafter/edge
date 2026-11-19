// Android's best-effort daily release-metadata worker, and the one function that
// turns a checked candidate into a notification. Independent of BLE and
// headless sync: it never opens LocalDb.
import 'update_models.dart';

/// Announce [candidate] through the shared emitter (claim ledger, quiet/sleep
/// policy and destination routing live there).
Future<void> notifyRelease(ReleaseCandidate candidate) async {}
