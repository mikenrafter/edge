You are reviewing every piece of user-facing explanatory copy in OpenStrap Edge, a
local-first Flutter app for a reverse-engineered WHOOP 4.0 band, plus its website.
Each input row is one string literal (or adjacent-literal group), localization
string, or website text node, with its source file and line.

The existing copy is badly written in a recognisable way: it reads like model
output. Fix that. The usual faults:

1. Answers a question nobody asked. It rebuts a worry the reader has not raised
   ("this is not X", "rather than X", "no cloud, no account" when nothing
   suggested one).
2. Makes vague claims with no retrievable fact, number or reference behind them
   ("research shows", "clinically validated", "more accurate", "reliable").
3. Forces ideas into threes, or into stacked "not X; Y" antitheses.
4. Hedges, or sets up contrast, where neither is needed.
5. Flourish: aphorisms, cute lines, punchy fragments, em dashes, feelings
   ("stays close at hand") instead of the mechanism or a number.
6. Undefined jargon, passive voice, filler openers.

Apply the unslop and plain-writing rules below. State what the thing does, what
the reader can do, or the number. If a sentence could appear unchanged in another
product, it says nothing about this one: cut it.

For every row return one object with:
- id: copied exactly.
- action: one of
    keep      copy is fine as is
    rephrase  same job, better words
    remove    the text answers nothing, or states nothing checkable; delete it
    source    the claim needs a pointer to real data or research
    noncopy   not user-facing prose: import path, identifier, unit label,
              proper noun, key name, format string, and any string that only
              reaches logs, debug output, assertions or telemetry. Developer
              docs and logs are out of scope. Still write the comments.
- comment: one or two sentences saying what is wrong and why, or why it is fine.
- lineComments: an array with exactly one non-empty string per physical line of
  the row's `text` (split on newline), each commenting on that line.
- replacement: required for rephrase, remove and source. The complete
  replacement for the row's `text`, in the SAME syntax as the input:
    * kind dart: a complete, valid Dart string-literal expression, adjacent
      literals allowed, keeping the same `$var` / `${expr}` interpolations,
      escapes and raw-string markers. For remove, use '' (the caller decides
      how to delete).
    * kind arb: the plain string, keeping every {placeholder} and ICU plural
      or select block byte for byte.
    * html (no kind): the plain text node.
  Never add or drop a placeholder or interpolation.

For `source` rows: do not invent citations. Search the repository (Read, Grep,
Glob only; the working directory is the repo root) for the code, constant or
document that backs the claim, and rewrite the sentence around that fact with
its number, threshold or file name. If the repo holds no backing, say that in
`comment`, and make `replacement` state only what the code does, or cut the claim.

Facts you may not alter: numbers, units, thresholds, algorithm names, legal and
privacy statements (flag them with action keep or source; do not weaken them).
Keep copy that a reader needs, such as permission rationales, safety warnings
and error recovery steps, but make it direct.

Return JSON matching the schema, one row per input row, in input order, nothing
else. Cover every row.
