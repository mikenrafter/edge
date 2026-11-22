import 'package:shared_preferences/shared_preferences.dart';

/// The experimental HMM sleep staging switch (Settings > Labs), default off.
/// This key is THE persisted choice: the Settings switch, the derivation engine
/// (every isolate) and backup/restore all read and write it. The upstream
/// worker HMM (`useHmmStages`) is the one staging owner.
const kSleepHmmStagesPref = 'sleep_hmm_stages';

/// The fork's earlier Labs key, which selected a second classifier (`hmm628`).
/// It is retired: [readSleepHmmChoice] folds it into [kSleepHmmStagesPref] once
/// and removes it. It stays in the backup type table so an old backup restores.
const kLegacySleepHmmPref = 'compute.experimental_sleep_hmm';

/// The one HMM choice. A saved older key migrates here, once: an opt-in under
/// either key stays an opt-in, then the older key is removed so a later switch
/// off cannot be undone by it. Idempotent; a failed write keeps the older key
/// for the next read. Any failure reads as off.
Future<bool> readSleepHmmChoice(SharedPreferences sp) async {
  try {
    final legacy = sp.get(kLegacySleepHmmPref);
    final current = sp.get(kSleepHmmStagesPref);
    final on = current is bool && current;
    if (legacy == null) return on;
    final legacyOn = legacy is bool && legacy;
    if (legacyOn && !on) {
      if (!await sp.setBool(kSleepHmmStagesPref, true)) return true;
    }
    await sp.remove(kLegacySleepHmmPref);
    return on || legacyOn;
  } catch (_) {
    return false;
  }
}
