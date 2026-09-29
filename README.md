# MoonLoom

**A pipeline query engine over semi-structured text, written in MoonBit.** Point
it at a CSV export, a JSON Lines dump, a logfmt application log, an HTTP access
log or a plain text file, and ask questions about it with a small query
language. No server, no schema declaration, no third-party dependency in the
engine itself.

```
$ moonloom query --file examples/access.log --stats \
    "where status >= 500 | stats count() as failures by path | sort failures desc"

+--------------------+----------+
| path               | failures |
+--------------------+----------+
| /api/orders?page=2 | 2        |
| /api/orders?page=1 | 1        |
| /health            | 1        |
+--------------------+----------+
rows in 21, scanned 21, filtered 17, groups 3, out 3
```

There is no single format to standardise on. Every service writes logs its own
way, every export tool has its own dialect, and every incident starts with a
file nobody can query. MoonLoom's answer is to make the *reading* part
interchangeable: one model (`Value`, `Record`, `Table`), several readers, and a
query language that runs over all of them. The same query works whether the
bytes arrived as CSV or as logfmt, and the same engine powers the command line
and the library.

## Requirements

- The [MoonBit toolchain](https://www.moonbitlang.com/download/), with
  `moonc` **0.10.14 or newer**. The interfaces in this repository were generated
  with `moon 0.1.20260920` and `moonc v0.10.14`.
- The engine packages (`moonloom`, `ascii`, `text`, `query`, `index`, `plan`,
  `exec`, `render`) import only `moonbitlang/core`. The command line adds
  `moonbitlang/x` for file access, which is the official MoonBit utility
  package.

## Quick start

```sh
moon check --target all
moon build --target wasm
moon test --deny-warn --target wasm
moon run examples/demo                  # a self-contained tour, no files needed
moon run --target js cmd/main -- query --file examples/access.log \
  "where status >= 500 | stats count() as n by path | sort n desc"
```

The demo prints the plan, the rows and the cost for six queries; its last two
sections run the same aggregation with and without an index so the difference
is visible rather than claimed.

In the examples below `moonloom` stands for the freshly built command line,
`moon run --target js cmd/main --`. Every query has to arrive as **one**
argument: a query that the shell splits makes the tool report
`unexpected extra argument` rather than running a fragment of it. Inside a
query, text literals may use either quote style, which is what makes the
examples work in PowerShell as well as in `sh`, where the outer quoting rules
differ.

## What the query language does

A query is a source and a chain of stages, each feeding the next:

```
from <name> | where ... | stats ... | sort ... | limit ...
```

The source name is for the caller; the data is always supplied by the host.

| Stage | Meaning |
| --- | --- |
| `where <expr>` / `filter` | keep the rows the expression accepts |
| `fields a, b` / `select` | keep and order these columns |
| `eval name = <expr>` | add or replace a column |
| `parse "pattern"` | extract named fields from the source line |
| `stats agg, agg by a, b` | group and aggregate |
| `sort a desc, b asc` / `order` | order rows |
| `limit n` / `head` | keep the first n rows |
| `top n by <key>` | order and cut in one step |
| `dedup a, b` / `distinct` | keep the first row per key |

Expressions support `== = != <> < <= > >=`, `=~ !~` (regular expression),
`contains`, `startswith`, `endswith`, `in [..]`, `is null` / `is not null`,
`and && or || not !`, and `+ - * / %`. Literals are integers, decimals,
single- or double-quoted text, `true`, `false`, `null`, and lists.

Aggregates: `count`, `count_distinct`, `sum`, `avg`, `min`, `max`,
`percentile(x, 95)`, `stddev`, `first`, `last`. Column names are generated
(`sum_bytes`, `p95_duration`) unless `as` gives one.

Scalar functions: `lower`, `upper`, `trim`, `len`, `str`, `int`, `float`,
`type`, `is_null`, `is_num`, `coalesce`, `if`, `concat`, `substr`, `replace`,
`abs`, `ceil`, `floor`, `round`, `sqrt`, `sign`, `pow`, `min`, `max`.

Three small examples over the files in `examples/`:

```sh
# sales: revenue per region, largest first
moon run --target js cmd/main -- query --file examples/sales.csv --output markdown \
  "stats sum(amount) as revenue by region | sort revenue desc"

# JSON Lines: nested objects become dotted field names
moon run --target js cmd/main -- query --file examples/events.jsonl \
  "where http.status >= 500 | stats count() as n, percentile(duration_ms, 95) as p95 by service"

# plain text: a pattern turns prose into columns
moon run --target js cmd/main -- query --file examples/service.log --format lines \
  "parse \"{time} {level} {service}: {message}\" | where level == \"error\""
```

## Reading formats

`--format auto` (the default) sniffs the format from the first non-blank line.
Naming one explicitly skips the guess.

| Reader | Accepts |
| --- | --- |
| `csv` / `tsv` | RFC 4180 delimited text; the delimiter is guessed from `,` `;` `\t` `|` and quoted fields may contain it, doubled quotes and line breaks |
| `json` | one document: an array of objects, or a single object |
| `jsonl` | one JSON value per line; nested objects become `a.b`, arrays become `a.0` |
| `logfmt` | `key=value`, quoted values, bare flags |
| `keyvalue` | `key: value` or `key = value`, with `[section]` headers and `#` comments |
| `access` | Common and Combined Log Format, with the request split into method, path and protocol |
| `syslog` | RFC 3164 and RFC 5424, with facility and severity decoded from the priority |
| `lines` | one record per line, with a single `line` field |

Every reader returns a table **and** a list of diagnostics. A line it cannot read
is skipped and reported instead of aborting the run, so one broken line in a
million still leaves a usable result:

```
$ moonloom schema --file examples/events.jsonl
format jsonl  records 10  skipped 0
+-------------+------+---------+---------+----------+
| name        | kind | present | missing | distinct |
+-------------+------+---------+---------+----------+
| time        | text | 10      | 0       | 9        |
| level       | text | 10      | 0       | 3        |
| duration_ms | num  | 10      | 0       | 10       |
| http.status | int  | 10      | 0       | 6        |
...
```

Types are decided while reading, and the engine only claims what the text
proves. `1` and `2.5` become numbers, `true` becomes a boolean, an empty field
becomes null, and `007` stays text because parsing it as `7` would lose the
leading zeros.

## How it executes

Two things happen between the query text and the first row, and both are
visible through `explain`:

```
$ moonloom explain --file examples/access.log \
    "where remote_host == \"203.0.113.51\" | fields time_text, method, path, status"

plan
  scan            <input>
                  rows=21
  index           remote_host=203.0.113.51  kept=3/21 (14.3%)
  1. filter       remote_host == "203.0.113.51"
  2. project      time_text, method, path, status
  columns         remote_host, time_text, method, path, status
```

1. **Index pruning.** Every column is indexed as a value-to-rows map unless it
   is unique per row, in which case indexing it would prune nothing.
   Equality predicates are collected from the first `where`, their posting
   lists are intersected, and only those rows are read. The filter still runs,
   because the index only removes rows it can prove cannot match.
2. **Column pruning.** The planner collects the fields the pipeline actually
   reads and reports them on the `columns` line. A stage after an aggregation
   can only name group keys and aggregate outputs, so it does not widen the set.

The executor reports what it cost:

```
$ moonloom query --file examples/access.log --stats "where status >= 500 | stats count() as n by path"
...
rows in 21, scanned 21, filtered 17, groups 3, out 3
```

## Using it as a library

The packages are layered, and each one is usable on its own:

| Package | What it provides |
| --- | --- |
| `haol-05/moonloom` | `Value`, `Record`, `Table`, `Dataset`, diagnostics, schema inference, number parsing |
| `.../ascii` | code-unit predicates and lexicographic text comparison |
| `.../text` | the readers plus timestamp and duration parsing |
| `.../query` | tokens, syntax tree and the parser |
| `.../index` | inverted index and candidate pruning |
| `.../plan` | plan construction and `explain` |
| `.../exec` | expression evaluation, aggregation and the operators |
| `.../render` | aligned table and JSON / JSON Lines / CSV / Markdown exports |

The shortest path from bytes to rows is one call:

```moonbit
match @exec.query_text(source, "where level == \"error\" | stats count() as n by service") {
  Ok(result) => println(@render.render_table(result))
  Err(message) => println("query error: " + message)
}
```

The long path is available when a host wants to control the pieces — parse
once, build the index once, compile the plan, print `plan.explain()`, run it,
and render in whichever format the caller needs:

```moonbit
let dataset = @text.parse_auto(source, format="logfmt")
let query = @query.Query::parse(text).unwrap()
let index = @index.TableIndex::build(dataset.table)
let plan = @plan.compile(query, dataset.table, Some(index))
println(plan.explain())
let result = @exec.run(query, dataset.table, Some(index))
```

`Query::parse` returns `Result`, so a host never has to handle an exception to
report a typo: the message carries the line and column of the mistake.

## What it does not do

- **It is not a streaming engine.** A whole input is read into memory before a
  query runs, so the working set is the size of the data. `--limit` caps how
  many records are read, which helps, but there is no windowed or incremental
  execution yet.
- **It is not a full regular expression engine.** `=~` uses the toolchain's
  matcher; a pattern that will not compile falls back to a substring test
  rather than failing the query.
- **It does not write.** There is no INSERT, UPDATE or DELETE, and no storage
  layer; MoonLoom reads text and answers questions about it.
- **Joins are out of scope.** One query looks at one input.
- **The index answers conjunctions only.** A predicate under `or` is evaluated
  by the filter instead of the index, which is correct but slower.
- **Group ordering is by group value**, not by first appearance, so results are
  reproducible regardless of input order. A query that needs another order says
  so with `sort`.
- **Display width is approximate.** The renderer implements the common East
  Asian Width ranges, not the full property, so a handful of emoji may still
  misalign a column.
- **Floats in a table are rounded to six decimals** for readability; the JSON
  and CSV exports keep the value unchanged.

## Reproducing the checks

```sh
moon version --all
moon check --deny-warn --target all
moon build --target wasm
moon test --deny-warn --target wasm
moon test --deny-warn --target wasm-gc
moon test --deny-warn --target js
moon fmt && git diff --exit-code
moon info && git diff --exit-code
moon run --target wasm examples/demo
```

## Related work

A search of GitHub and mooncakes.io on **2026-09-29** for `moonbit query
engine`, `moonbit log query`, `moonbit logfmt` and `moonbit csv query` found no
project that reads several text formats and queries them. The nearest
neighbours, and how MoonLoom differs:

- [`sundaysebasidian-byte/moon-loglens`](https://mooncakes.io/docs/sundaysebasidian-byte/moon-loglens)
  streams JSON Lines with filters and grouped metrics. It reads one format, has
  no query parser, no plan, no index and no command line, so filters are
  expressed by calling its API rather than by writing a query.
- [`ihb2032/MoonFrame`](https://mooncakes.io/docs/ihb2032/MoonFrame) is a
  DataFrame with an expression engine over structured data. It expects tabular
  input; recovering a table from an access log, a syslog file or a pattern is
  left to the caller.
- [`sqhyyy/moonlogfmt-lens`](https://mooncakes.io/docs/sqhyyy/moonlogfmt-lens)
  parses, redacts and diffs logfmt specifically.
- [`moonbit-community/sqlparser`](https://mooncakes.io/docs/moonbit-community/sqlparser)
  is an extensible SQL parser with no executor.

MoonLoom's contribution is the layer above the readers: one query language over
all of them, a planner that makes predicate and column pruning explicit, and an
executor that reports what it scanned. Those searches cover GitHub and
mooncakes.io only and are not proof of uniqueness.

`moonbitlang/x` is used by the command line for file access (Apache-2.0). No
code was copied from it or from any other project; the readers, the query
language, the planner and the executor are written for this repository. The
sample files in `examples/` are fictional: the addresses come from the
documentation ranges reserved by RFC 5737 and every name is invented.

## Environment note

Verified on 2026-09-29 on Windows with `moon 0.1.20260920` and `moonc
v0.10.14`: `moon check --deny-warn --target all`, `moon build` and `moon test
--deny-warn` on `wasm`, `wasm-gc` and `js` (95 tests each), the demo through
`moon run`, the command line through `moon run --target js cmd/main`, and
`moon fmt` / `moon info` leaving the working tree unchanged.

The `native` target does not build on that host for two reasons that are both
outside this repository: the toolchain's own runtime file
`<moon-home>/lib/runtime/env.c` calls `rand_s` without a declaration, and the C
toolchain cannot create object files under a path containing non-ASCII
characters, which every build directory on that machine has. A three-line test
package fails identically. GitHub Actions runs the same steps on
`ubuntu-latest`, including `native`.

## License

Apache-2.0. See [LICENSE](LICENSE).
