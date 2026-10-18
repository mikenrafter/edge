// The one place a screen asks for getToday's freshness refresh AFTER its first
// paint (see LocalRepository.getTodayStored / refreshTodayFreshness).
//
// Owner of its two flags: the screen that holds the latch. A screen calls
// [afterPaint] with every stored read; the latch asks for the refresh when one
// is owed and the screen reads again when it lands.
import '../data/local_repository.dart';

class TodayRefreshLatch {
  bool _refreshing = false;
  bool _justRefreshed = false;

  /// A revision reload starts over: the next pending read may ask again.
  void reset() => _justRefreshed = false;

  /// Call with each stored read. [pending] is `status.refresh_pending`.
  ///
  /// Resolves true when the refresh just landed and the screen should read
  /// again (if still mounted); false otherwise. Not pending: nothing is asked.
  /// Pending: the refresh is asked once (the repository joins overlapping
  /// calls too). A read right after a landing that is STILL
  /// pending is not asked again (it would loop). The in-flight flag clears in
  /// `finally`, so a throw cannot stop a later load from asking; a failed
  /// refresh leaves the honest "still being worked out" state and no reload.
  Future<bool> afterPaint(LocalRepository repo, bool pending) async {
    if (!pending) {
      _justRefreshed = false;
      return false;
    }
    if (_refreshing) return false;
    if (_justRefreshed) {
      _justRefreshed = false;
      return false;
    }
    _refreshing = true;
    var ok = false;
    try {
      await repo.refreshTodayFreshness();
      ok = true;
    } catch (_) {
      // The next revision reloads and asks again.
    } finally {
      _refreshing = false;
    }
    if (ok) _justRefreshed = true;
    return ok;
  }
}
