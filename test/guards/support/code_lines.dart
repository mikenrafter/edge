// code_lines.dart — the file-size guard's line counter (owner rule A).
//
// STUB (red phase): returns 0 until the green phase implements it.
//
// Contract. Count the physical lines of [source] that carry code:
//   * blank (whitespace-only) lines do not count;
//   * a line holding only comment text does not count: `//`, `///`, and every
//     line of a `/* ... */` block (Dart block comments NEST);
//   * a line with code AND a comment (`x(); // note`, `/* a */ x();`) counts;
//   * a multi-line string literal is lexed as a string: `//`, `/*` and quotes
//     inside it are text, never comments. Its first and last physical lines
//     (they hold the delimiters) always count; the lines strictly BETWEEN them
//     count only when the string's text contains an SQL keyword as a whole
//     word, case-insensitively: SELECT INSERT UPDATE DELETE CREATE ALTER DROP
//     WITH PRAGMA. Prose that merely uses the word "with" is therefore SQL.
//   * handled lexically: '...', "...", ''' ''', """ """, raw r'..' / r'''..'''
//     (a backslash escapes nothing), backslash escapes, and `${...}`
//     interpolation whose expression holds further quotes or strings.
int countCodeLines(String source) => 0;
