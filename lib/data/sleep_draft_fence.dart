// sleep_draft_fence.dart — the app-level generation a session draft was built
// under. Deleting a day advances that day's generation and importing or
// deleting everything advances the dataset's, so a plan captured before either
// is refused at commit even when it only ADDS (no revision row to compare).
//
// STUB (phase 2 red): never advances.

class SleepDraftFence {
  SleepDraftFence();
  static final SleepDraftFence shared = SleepDraftFence();

  int generationOf(String dayId) => 0;
  void advanceDays(Iterable<String> dayIds) {}
  void advanceDataset() {}
}
