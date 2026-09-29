# Changelog

## 0.1.1

- **Command line.** An argument that is not part of the query is now reported
  instead of being ignored: a second bare word produces
  `unexpected extra argument '<word>'; quote the whole query as one argument`,
  which is what a query split by the shell looks like, and an unrecognised
  option is named. A missing value and a count that is not a number are named
  too, instead of printing the usage alone.
- **Documentation.** The example outputs in the README were re-run against the
  sample files and corrected, and the quoting rule for a query argument is
  stated where the examples are introduced.

## 0.1.0

First release.

- **Core model.** `Value` (null, boolean, integer, decimal, text) with a total
  order, schema-on-read typing that only claims what the text proves, `Record`
  with a stable column order, `Table`, `Dataset` and non-fatal diagnostics.
- **Readers.** CSV and TSV with RFC 4180 quoting and a guessed delimiter, JSON
  documents and JSON Lines with nested keys flattened to dotted names, logfmt,
  key/value with sections and comments, Common and Combined access logs, syslog
  RFC 3164 and RFC 5424, user-defined `{field}` patterns, and a plain-text
  fallback. Timestamps normalise to epoch milliseconds and durations parse from
  `250ms`, `30s`, `5m`, `1h30m`.
- **Query language.** A pipeline of `where`, `fields`, `eval`, `parse`, `stats`,
  `sort`, `limit`, `top` and `dedup`, with arithmetic, comparison, text, set and
  regular expression operators, parentheses and a scalar function library. The
  parser reports the line and column of a mistake.
- **Index and planner.** An inverted index over every column that is not unique
  per row, conjunctive equality predicates answered by intersecting posting
  lists, column pruning, and `explain` reporting both.
- **Executor.** Streaming operators over an in-memory relation, short-circuit
  boolean evaluation, `count`, `count_distinct`, `sum`, `avg`, `min`, `max`,
  `percentile`, `stddev`, `first` and `last`, deterministic group ordering, and
  a cost line reporting rows in, rows scanned, rows filtered, groups and rows
  out.
- **Renderers.** An aligned table that pads by display width, plus JSON, JSON
  Lines, CSV and Markdown exports.
- **Command line.** `query`, `schema`, `explain`, `formats` and `version`, with
  input from a file or an argument and a choice of output format.
- **Tests.** 95 test cases covering line splitting, timestamp forms, delimiting,
  nested JSON, logfmt quoting, ini sections, both syslog shapes, pattern
  capture, format detection, parser precedence and error positions, index
  pruning, plan shape, expression evaluation, aggregation, sorting, and an
  invariant that an indexed run returns exactly the rows an unindexed run does.
