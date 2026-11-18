// sleep_editor_write.dart — the one write owner for sleep block intervals.
//
// STUB (phase 2 red): sentinel bodies that refuse without writing, so the new
// contract tests compile and fail on assertions. Replaced in the green commits.

import 'package:sqflite/sqflite.dart';

import 'sleep_edit_codec.dart';
import 'sleep_editor.dart';

export 'sleep_edit_codec.dart';

class SleepEditorWrite {
  const SleepEditorWrite._();

  static SleepEditorProposal propose(
          SleepEditorRead read, SleepEditorPlan plan) =>
      const SleepProposalInvalid(SleepRefusalReason.unsupportedSource);

  static Future<SleepEditorOutcome> apply(SleepEditorPlan plan,
          {required Transaction transaction}) async =>
      const SleepRefused(SleepRefusalReason.unsupportedSource);
}
