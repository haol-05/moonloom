# Example inputs

Every file here is fictional. The IP addresses come from the ranges that
RFC 5737 reserves for documentation (`192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`), the domains use `example.com`, and every name and number was
invented for this repository.

| File | Format | Rows | What it is for |
| --- | --- | --- | --- |
| `access.log` | `access` | 21 | a Combined Log Format access log with 2xx, 3xx, 4xx and 5xx responses |
| `sales.csv` | `csv` | 10 | a delimited export with text, integer and decimal columns |
| `events.jsonl` | `jsonl` | 10 | one application event per line, with nested `http` and `user` objects |
| `app.logfmt` | `logfmt` | 8 | the same events in `key=value` form |
| `service.log` | `lines` | 6 | plain text that needs a `parse` pattern to become columns |

Queries to try, from the repository root:

```sh
moon run --target js cmd/main -- query --file examples/access.log --stats \
  "where status >= 500 | stats count() as failures by path | sort failures desc"

moon run --target js cmd/main -- query --file examples/access.log --output csv \
  "stats sum(bytes) as bytes, count() as hits by method | sort bytes desc"

moon run --target js cmd/main -- query --file examples/events.jsonl \
  "where http.status >= 500 | stats count() as n, percentile(duration_ms, 95) as p95 by service"

moon run --target js cmd/main -- query --file examples/sales.csv \
  "stats sum(amount) as revenue, avg(units) as mean_units by region | sort revenue desc"

moon run --target js cmd/main -- query --file examples/app.logfmt --plan \
  "where level == \"error\" | stats count() as n by service"

moon run --target js cmd/main -- query --file examples/service.log --format lines \
  "parse \"{time} {level} {service}: {message}\" | where level == \"error\" | fields time, service, message"

moon run --target js cmd/main -- schema --file examples/events.jsonl
```
