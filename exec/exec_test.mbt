// Behaviour tests for the execution engine.

///|
fn source() -> String {
  "service,level,duration,user\napi,error,12.5,alice\napi,info,3,bob\nweb,error,20,alice\ndb,error,100,carol\nweb,info,1.5,bob\n"
}

///|
fn table() -> @moonloom.Table {
  @text.parse_csv(source()).table
}

///|
fn rows_of(text : String) -> Array[Array[@moonloom.Value]] raise {
  match @exec.run_text(text, table(), None) {
    Ok(result) => result.rows
    Err(message) => fail(message)
  }
}

///|
fn run(text : String) -> @exec.ResultSet raise {
  match @exec.run_text(text, table(), None) {
    Ok(result) => result
    Err(message) => fail(message)
  }
}

///|
test "exec: a filter keeps the matching rows and counts the rest" {
  let result = run("where level == \"error\"")
  assert_eq(result.length(), 3)
  assert_eq(result.stats.rows_in, 5)
  assert_eq(result.stats.filtered_out, 2)
  assert_eq(result.value(0, "service"), @moonloom.Str("api"))
}

///|
test "exec: a number compares equal to its text form" {
  let result = run("where duration == \"12.5\"")
  assert_eq(result.length(), 1)
  assert_eq(result.value(0, "service"), @moonloom.Str("api"))
}

///|
test "exec: numeric comparisons work across int and float" {
  assert_eq(rows_of("where duration > 10").length(), 3)
  assert_eq(rows_of("where duration >= 12.5 and duration < 100").length(), 2)
  assert_eq(rows_of("where duration <= 1.5").length(), 1)
}

///|
test "exec: and, or and not combine predicates" {
  assert_eq(
    rows_of("where level == \"error\" and service == \"api\"").length(),
    1,
  )
  assert_eq(
    rows_of("where service == \"api\" or service == \"db\"").length(),
    3,
  )
  assert_eq(rows_of("where not (level == \"error\")").length(), 2)
}

///|
test "exec: text predicates" {
  assert_eq(rows_of("where service contains \"e\"").length(), 2)
  assert_eq(rows_of("where service startswith \"a\"").length(), 2)
  assert_eq(rows_of("where service endswith \"b\"").length(), 3)
  assert_eq(rows_of("where service == \"a\"").length(), 0)
}

///|
test "exec: a pattern predicate matches with a regular expression" {
  assert_eq(rows_of("where service =~ \"^a\"").length(), 2)
  assert_eq(rows_of("where service =~ \"^(a|d)\"").length(), 3)
  assert_eq(rows_of("where service !~ \"^a\"").length(), 3)
}

///|
test "exec: membership and missing values" {
  assert_eq(rows_of("where level in [\"error\", \"fatal\"]").length(), 3)
  assert_eq(rows_of("where user is not null").length(), 5)
  assert_eq(rows_of("where missing is null").length(), 5)
  assert_eq(rows_of("where missing == 1").length(), 0)
}

///|
test "exec: arithmetic and eval add a column" {
  let result = run("eval seconds = duration / 1000 | where seconds < 0.02")
  assert_eq(result.length(), 3)
  assert_eq(result.value(0, "seconds"), @moonloom.Num(0.0125))
}

///|
test "exec: division by zero and bad arithmetic give null instead of failing" {
  let result = run("eval bad = duration / 0 | eval text = duration * user")
  assert_eq(result.length(), 5)
  assert_eq(result.value(0, "bad"), @moonloom.Null)
  assert_eq(result.value(0, "text"), @moonloom.Null)
}

///|
test "exec: scalar functions" {
  assert_eq(rows_of("where lower(service) == \"api\"").length(), 2)
  assert_eq(rows_of("where upper(service) == \"WEB\"").length(), 2)
  assert_eq(rows_of("where len(user) == 3").length(), 2)
  assert_eq(
    rows_of("where concat(service, \"/\", level) == \"api/error\"").length(),
    1,
  )
  assert_eq(rows_of("where substr(service, 0, 1) == \"a\"").length(), 2)
  assert_eq(rows_of("where coalesce(missing, user) == \"alice\"").length(), 2)
  assert_eq(rows_of("where if(level == \"error\", 1, 0) == 1").length(), 3)
  assert_eq(rows_of("where round(duration) == 13").length(), 1)
  assert_eq(rows_of("where floor(duration) == 3").length(), 1)
  assert_eq(rows_of("where abs(0 - duration) == 20").length(), 1)
  assert_eq(rows_of("where max(duration, 20) == 100").length(), 1)
  assert_eq(rows_of("where type(duration) == \"num\"").length(), 2)
  assert_eq(rows_of("where type(duration) == \"int\"").length(), 3)
  assert_eq(rows_of("where type(missing) == \"null\"").length(), 5)
}

///|
test "exec: stats counts and aggregates" {
  let result = run(
    "stats count() as n, sum(duration) as total, avg(duration) as mean",
  )
  assert_eq(result.length(), 1)
  assert_eq(result.value(0, "n"), @moonloom.Int(5L))
  assert_eq(result.value(0, "total"), @moonloom.Int(137L))
  assert_eq(result.value(0, "mean"), @moonloom.Num(27.4))
}

///|
test "exec: stats groups and orders the groups by key" {
  let result = run("stats count() as n, avg(duration) as mean by service")
  assert_eq(result.columns, ["service", "n", "mean"])
  assert_eq(result.length(), 3)
  assert_eq(result.value(0, "service"), @moonloom.Str("api"))
  assert_eq(result.value(0, "n"), @moonloom.Int(2L))
  assert_eq(result.value(1, "service"), @moonloom.Str("db"))
  assert_eq(result.value(2, "service"), @moonloom.Str("web"))
  assert_eq(result.value(2, "mean"), @moonloom.Num(10.75))
}

///|
test "exec: min, max and count_distinct" {
  let result = run(
    "stats min(duration) as lo, max(duration) as hi, count_distinct(user) as people",
  )
  assert_eq(result.value(0, "lo"), @moonloom.Num(1.5))
  assert_eq(result.value(0, "hi"), @moonloom.Int(100L))
  assert_eq(result.value(0, "people"), @moonloom.Int(3L))
}

///|
test "exec: percentile uses the nearest rank" {
  let result = run(
    "stats percentile(duration, 50) as p50, percentile(duration, 100) as p100",
  )
  assert_eq(result.value(0, "p50"), @moonloom.Num(12.5))
  assert_eq(result.value(0, "p100"), @moonloom.Int(100L))
}

///|
test "exec: stddev is zero for a constant and positive otherwise" {
  let flat = @text.parse_csv("v\n10\n10\n10\n").table
  match @exec.run_text("stats stddev(v) as s", flat, None) {
    Ok(result) => assert_eq(result.value(0, "s"), @moonloom.Int(0L))
    Err(message) => fail(message)
  }
  let spread = run("stats stddev(duration) as s")
  match spread.value(0, "s") {
    @moonloom.Num(value) => assert_true(value > 30.0)
    @moonloom.Int(value) => assert_true(value > 30L)
    _ => fail("expected a number")
  }
}

///|
test "exec: an aggregate over no rows still answers count" {
  let result = run("where service == \"none\" | stats count() as n")
  assert_eq(result.length(), 1)
  assert_eq(result.value(0, "n"), @moonloom.Int(0L))
}

///|
test "exec: sorting is stable and multi key" {
  let result = run("sort level asc, duration desc")
  assert_eq(result.length(), 5)
  assert_eq(result.value(0, "level"), @moonloom.Str("error"))
  assert_eq(result.value(0, "duration"), @moonloom.Int(100L))
  assert_eq(result.value(1, "duration"), @moonloom.Int(20L))
  assert_eq(result.value(2, "duration"), @moonloom.Num(12.5))
  assert_eq(result.value(3, "level"), @moonloom.Str("info"))
}

///|
test "exec: limit, top and dedup" {
  assert_eq(rows_of("limit 2").length(), 2)
  assert_eq(rows_of("limit 0").length(), 0)
  assert_eq(rows_of("limit 99").length(), 5)
  let top = rows_of("top 2 by duration desc")
  assert_eq(top.length(), 2)
  assert_eq(top[0][2], @moonloom.Int(100L))
  assert_eq(rows_of("dedup user").length(), 3)
}

///|
test "exec: fields projects and reorders" {
  let result = run("fields user, service")
  assert_eq(result.columns, ["user", "service"])
  assert_eq(result.value(0, "user"), @moonloom.Str("alice"))
  let missing = run("fields service, nope")
  assert_eq(missing.columns, ["service", "nope"])
  assert_eq(missing.value(0, "nope"), @moonloom.Null)
}

///|
test "exec: parse extracts fields from the source line" {
  let log = "2024-01-02T03:04:05Z error api: upstream timeout\n2024-01-02T03:04:06Z info web: ok\n"
  match
    @exec.query_text(
      log,
      "parse \"{time} {level} {service}: {message}\" | where level == \"error\"",
      format="lines",
    ) {
    Ok(result) => {
      assert_eq(result.length(), 1)
      assert_eq(result.value(0, "service"), @moonloom.Str("api"))
      assert_eq(result.value(0, "message"), @moonloom.Str("upstream timeout"))
    }
    Err(message) => fail(message)
  }
}

///|
test "exec: the index changes the plan but never the answer" {
  let table = table()
  let index = @index.TableIndex::build(table)
  let queries = [
    "where level == \"error\"", "where service == \"web\" and level == \"info\"",
    "where level == \"error\" | stats count() as n by service | sort n desc", "where service == \"nope\"",
  ]
  for text in queries {
    let plain = match @exec.run_text(text, table, None) {
      Ok(result) => result
      Err(message) => {
        fail(message)
        continue
      }
    }
    let indexed = match @exec.run_text(text, table, Some(index)) {
      Ok(result) => result
      Err(message) => {
        fail(message)
        continue
      }
    }
    assert_eq(plain.columns, indexed.columns)
    assert_eq(plain.rows, indexed.rows)
  }
}

///|
test "exec: stats can be read through the whole pipeline" {
  let result = run(
    "where level == \"error\" | stats count() as n, avg(duration) as mean by service | sort n desc, service asc | limit 2",
  )
  assert_eq(result.length(), 2)
  assert_eq(result.columns, ["service", "n", "mean"])
  assert_eq(result.value(0, "service"), @moonloom.Str("api"))
  assert_eq(result.stats.groups, 3)
  assert_eq(result.stats.rows_out, 2)
}

///|
test "exec: query_text reads the format it is given" {
  let logfmt = "level=error service=api dur=12\nlevel=info service=web dur=3\n"
  match
    @exec.query_text(logfmt, "stats count() as n by level | sort level asc") {
    Ok(result) => {
      assert_eq(result.length(), 2)
      assert_eq(result.value(0, "level"), @moonloom.Str("error"))
      assert_eq(result.value(0, "n"), @moonloom.Int(1L))
    }
    Err(message) => fail(message)
  }
  match @exec.query_text("{ bad json\n", "limit 1") {
    Ok(result) => assert_eq(result.length(), 1)
    Err(message) => fail(message)
  }
  // Named as JSON Lines, the same text has no records: the reader reports the
  // broken line instead of turning it into a row.
  match @exec.query_text("{ bad json\n", "limit 1", format="jsonl") {
    Ok(result) => assert_eq(result.length(), 0)
    Err(message) => fail(message)
  }
}

///|
test "exec: a broken query comes back as a message, not a crash" {
  match @exec.run_text("where", table(), None) {
    Ok(_) => fail("expected an error")
    Err(message) => assert_true(message.contains("expected"))
  }
}
