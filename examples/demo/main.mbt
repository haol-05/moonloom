// A runnable tour of MoonLoom.
//
//   moon run examples/demo
//
// Every step prints the plan, the rows and what the run cost, so the demo is
// also the smallest possible integration test of the library.

///|
const ACCESS_LOG : String =
  #|192.0.2.14 - - [11/Mar/2024:10:00:01 +0000] "GET /api/orders HTTP/1.1" 200 1532 "-" "Mozilla/5.0"
  #|192.0.2.14 - - [11/Mar/2024:10:00:02 +0000] "GET /static/app.js HTTP/1.1" 200 84210 "-" "Mozilla/5.0"
  #|198.51.100.7 - - [11/Mar/2024:10:00:03 +0000] "POST /api/orders HTTP/1.1" 201 310 "-" "Mozilla/5.0"
  #|198.51.100.7 - - [11/Mar/2024:10:00:04 +0000] "GET /api/orders HTTP/1.1" 500 214 "-" "curl/8.4.0"
  #|203.0.113.51 - - [11/Mar/2024:10:00:05 +0000] "GET /api/orders HTTP/1.1" 500 214 "-" "curl/8.4.0"
  #|203.0.113.51 - - [11/Mar/2024:10:00:06 +0000] "GET /health HTTP/1.1" 200 12 "-" "kube-probe/1.29"
  #|203.0.113.9 - - [11/Mar/2024:10:00:07 +0000] "GET /api/products HTTP/1.1" 503 198 "-" "Googlebot/2.1"
  #|192.0.2.88 - - [11/Mar/2024:10:00:08 +0000] "GET /api/users/me HTTP/1.1" 401 87 "-" "Mozilla/5.0"
  #|192.0.2.88 - - [11/Mar/2024:10:00:09 +0000] "POST /api/login HTTP/1.1" 200 421 "-" "Mozilla/5.0"
  #|192.0.2.14 - - [11/Mar/2024:10:00:10 +0000] "GET /does-not-exist HTTP/1.1" 404 153 "-" "Mozilla/5.0"
  #|

///|
const SALES_CSV : String =
  #|region,channel,units,amount
  #|North,online,120,4800.50
  #|North,retail,80,3120.00
  #|South,online,210,8610.25
  #|South,retail,45,1780.00
  #|East,online,310,12400.00
  #|East,retail,60,2400.00
  #|West,online,95,3610.75
  #|West,retail,140,5320.00
  #|

///|
const SERVICE_LOG : String =
  #|2024-03-11T10:00:01Z info orders: order 8812 created
  #|2024-03-11T10:00:04Z error orders: database timeout after 5 retries
  #|2024-03-11T10:00:06Z warn auth: missing token for /api/users/me
  #|2024-03-11T10:00:09Z info catalog: product 4471 refreshed
  #|2024-03-11T10:00:11Z error catalog: upstream unavailable, serving 503
  #|

///|
fn heading(title : String) -> Unit {
  println("")
  println("=== " + title + " ===")
}

///|
/// Runs one query over a dataset and prints the plan, the rows and the cost.
fn show(
  title : String,
  source : String,
  format : String,
  query_text : String,
  use_index : Bool,
) -> Unit {
  heading(title)
  let dataset = @text.parse_auto(source, format~)
  let query = match @query.Query::parse(query_text) {
    Ok(parsed) => parsed
    Err(message) => {
      println("query error: " + message)
      return
    }
  }
  let built = if use_index {
    Some(@index.TableIndex::build(dataset.table))
  } else {
    None
  }
  let plan = @plan.compile(query, dataset.table, built)
  println(plan.explain())
  let result = @exec.run(query, dataset.table, built)
  println(@render.render_table(result))
  println(@render.render_stats(result.stats))
}

///|
fn main {
  println("MoonLoom demo: " + @text.known_input_formats().join(", "))
  show(
    "which requests failed",
    ACCESS_LOG,
    "access",
    "where status >= 500 | stats count() as failures by path | sort failures desc",
    true,
  )
  show(
    "where the bytes go",
    ACCESS_LOG,
    "access",
    "stats sum(bytes) as total, count() as hits by method | sort total desc",
    true,
  )
  show(
    "every request from one address",
    ACCESS_LOG,
    "access",
    "where remote_host == \"203.0.113.51\" | fields time_text, method, path, status",
    true,
  )
  show(
    "revenue by region",
    SALES_CSV,
    "csv",
    "eval thousands = amount / 1000 | stats sum(amount) as revenue, avg(units) as mean_units by region | sort revenue desc",
    true,
  )
  show(
    "the same revenue query without an index",
    SALES_CSV,
    "csv",
    "eval thousands = amount / 1000 | stats sum(amount) as revenue, avg(units) as mean_units by region | sort revenue desc",
    false,
  )
  show(
    "errors extracted from plain text",
    SERVICE_LOG,
    "lines",
    "parse \"{time} {level} {service}: {message}\" | where level == \"error\" | fields time, service, message",
    false,
  )
}
