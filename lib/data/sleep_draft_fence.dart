// sleep_draft_fence.dart — the app-level generation a session draft was built
// under. Deleting a day advances that day's generation and importing or
// deleting everything advances the dataset's, so a plan captured before either
// is refused at commit even when it only ADDS (no revision row to compare).
//
// CLAIM(sleep-editor-draft-generation). Both counters only grow, so their sum
// is a generation that strictly increases when either advances.

class SleepDraftFence {
  SleepDraftFence();
  static final SleepDraftFence shared = SleepDraftFence();

  int _dataset = 0;
  final Map<String, int> _days = {};

  int generationOf(String dayId) => _dataset + (_days[dayId] ?? 0);

  void advanceDays(Iterable<String> dayIds) {
    for (final d in dayIds) {
      _days[d] = (_days[d] ?? 0) + 1;
    }
  }

  void advanceDataset() => _dataset++;
}
