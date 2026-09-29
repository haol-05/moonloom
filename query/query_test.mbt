// Behaviour tests for the query front end.

///|
test "query: a full pipeline parses into stages" {
  let text = "from app.log | where level == \"error\" | stats count() as n, avg(duration) as mean by service | sort n desc | limit 5"
  let query = match @query.Query::parse(text) {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  assert_eq(query.source, Some("app.log"))
  assert_eq(query.stages.length(), 4)
  assert_eq(query.stages[0].keyword(), "where")
  match query.stats_stage() {
    Some((specs, groups)) => {
      assert_eq(specs.length(), 2)
      assert_eq(specs[0].func, @query.Count)
      assert_eq(specs[0].label, "n")
      assert_eq(specs[1].func, @query.Avg)
      assert_eq(specs[1].label, "mean")
      assert_eq(groups, ["service"])
    }
    None => fail("expected a stats stage")
  }
}

///|
test "query: a pipeline may start without a source and without a pipe" {
  let query = match @query.Query::parse("where n > 3 | limit 1") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  assert_eq(query.source, None)
  assert_eq(query.stages.length(), 2)
}

///|
test "query: comparison, logic and unary operators" {
  let query = match @query.Query::parse("where not (a >= 2 and b < 3) or c != \"x\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(expr) =>
      assert_eq(
        expr,
        @query.Binary(
          @query.Or,
          @query.Unary(
            @query.Not,
            @query.Binary(
              @query.And,
              @query.Binary(@query.Ge, @query.Field("a"), @query.LitInt(2L)),
              @query.Binary(@query.Lt, @query.Field("b"), @query.LitInt(3L)),
            ),
          ),
          @query.Binary(@query.Ne, @query.Field("c"), @query.LitStr("x")),
        ),
      )
    _ => fail("expected a where stage")
  }
}

///|
test "query: arithmetic binds tighter than comparison" {
  let query = match @query.Query::parse("where a + b * 2 == 10") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(expr) =>
      assert_eq(
        expr,
        @query.Binary(
          @query.Eq,
          @query.Binary(
            @query.Add,
            @query.Field("a"),
            @query.Binary(@query.Mul, @query.Field("b"), @query.LitInt(2L)),
          ),
          @query.LitInt(10L),
        ),
      )
    _ => fail("expected a where stage")
  }
}

///|
test "query: text predicates and lists" {
  let query = match @query.Query::parse("where msg contains \"timeout\" and level in [\"warn\", \"error\"]") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(expr) =>
      match expr {
        @query.Binary(@query.And, left, right) => {
          assert_eq(left, @query.Binary(@query.Contains, @query.Field("msg"), @query.LitStr("timeout")))
          assert_eq(
            right,
            @query.Binary(
              @query.In,
              @query.Field("level"),
              @query.List([@query.LitStr("warn"), @query.LitStr("error")]),
            ),
          )
        }
        _ => fail("expected an and expression")
      }
    _ => fail("expected a where stage")
  }
}

///|
test "query: is null and is not null" {
  let missing = match @query.Query::parse("where user is null") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match missing.stages[0] {
    @query.Where(expr) =>
      assert_eq(expr, @query.Binary(@query.Eq, @query.Field("user"), @query.LitNull))
    _ => fail("expected a where stage")
  }
  let present = match @query.Query::parse("where user is not null") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match present.stages[0] {
    @query.Where(expr) =>
      assert_eq(expr, @query.Binary(@query.Ne, @query.Field("user"), @query.LitNull))
    _ => fail("expected a where stage")
  }
}

///|
test "query: nested field names survive the lexer" {
  let query = match @query.Query::parse("where http.status >= 500 and tags.0 == \"a\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(@query.Binary(@query.And, left, right)) => {
      assert_eq(left, @query.Binary(@query.Ge, @query.Field("http.status"), @query.LitInt(500L)))
      assert_eq(right, @query.Binary(@query.Eq, @query.Field("tags.0"), @query.LitStr("a")))
    }
    _ => fail("expected a where stage")
  }
}

///|
test "query: aggregate aliases are generated when absent" {
  let query = match @query.Query::parse("stats count(), sum(bytes), count_distinct(user), percentile(duration, 95)") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stats_stage() {
    Some((specs, groups)) => {
      assert_eq(specs[0].label, "count")
      assert_eq(specs[1].label, "sum_bytes")
      assert_eq(specs[2].label, "count_distinct_user")
      assert_eq(specs[3].label, "p95_duration")
      assert_eq(groups, [])
    }
    None => fail("expected a stats stage")
  }
}

///|
test "query: grouping and multi key ordering" {
  let query = match @query.Query::parse("stats count() as n by service, level | sort n desc, service asc") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stats_stage() {
    Some((_, groups)) => assert_eq(groups, ["service", "level"])
    None => fail("expected a stats stage")
  }
  match query.stages[1] {
    @query.Sort(keys) => {
      assert_eq(keys.length(), 2)
      assert_true(keys[0].desc)
      assert_false(keys[1].desc)
    }
    _ => fail("expected a sort stage")
  }
}

///|
test "query: top, dedup, eval and parse stages" {
  let query = match @query.Query::parse("eval ms = duration * 1000 | top 3 by ms desc | dedup user") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Eval(name, expr) => {
      assert_eq(name, "ms")
      assert_eq(expr, @query.Binary(@query.Mul, @query.Field("duration"), @query.LitInt(1000L)))
    }
    _ => fail("expected an eval stage")
  }
  match query.stages[1] {
    @query.Top(count, keys) => {
      assert_eq(count, 3)
      assert_eq(keys.length(), 1)
      assert_true(keys[0].desc)
    }
    _ => fail("expected a top stage")
  }
  match query.stages[2] {
    @query.Dedup(names) => assert_eq(names, ["user"])
    _ => fail("expected a dedup stage")
  }
  let parsed = match @query.Query::parse("parse \"{time} {level} {msg}\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match parsed.stages[0] {
    @query.Parse(pattern) => assert_eq(pattern, "{time} {level} {msg}")
    _ => fail("expected a parse stage")
  }
}

///|
test "query: comments and flexible spacing are ignored" {
  let query = match @query.Query::parse("// look at errors\nwhere   level=='error'   |limit 10") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  assert_eq(query.stages.length(), 2)
  match query.stages[0] {
    @query.Where(expr) =>
      assert_eq(expr, @query.Binary(@query.Eq, @query.Field("level"), @query.LitStr("error")))
    _ => fail("expected a where stage")
  }
}

///|
test "query: mistakes are reported with a position" {
  let unknown = @query.Query::parse("where a > 1 | explode")
  assert_true(unknown is Err(_))
  match unknown {
    Err(message) => assert_true(message.contains("unknown stage") && message.contains("column"))
    Ok(_) => fail("expected an error")
  }
  let no_pipe = @query.Query::parse("where a > 1 limit 2")
  assert_true(no_pipe is Err(_))
  let unterminated = @query.Query::parse("where a == \"oops")
  assert_true(unterminated is Err(_))
  match unterminated {
    Err(message) => assert_true(message.contains("unterminated"))
    Ok(_) => fail("expected an error")
  }
  let bad_agg = @query.Query::parse("stats median(x)")
  assert_true(bad_agg is Err(_))
  let bad_percentile = @query.Query::parse("stats percentile(x)")
  assert_true(bad_percentile is Err(_))
  let empty = @query.Query::parse("")
  match empty {
    Ok(q) => assert_eq(q.stages.length(), 0)
    Err(message) => fail(message)
  }
}

///|
test "lexer: text literals understand escapes and both quote styles" {
  let query = match @query.Query::parse("where a == 'it\\'s' and b == \"x\\ty\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(@query.Binary(@query.And, left, right)) => {
      assert_eq(left, @query.Binary(@query.Eq, @query.Field("a"), @query.LitStr("it's")))
      assert_eq(right, @query.Binary(@query.Eq, @query.Field("b"), @query.LitStr("x\ty")))
    }
    _ => fail("expected a where stage")
  }
}

///|
test "lexer: numbers keep their kind" {
  let query = match @query.Query::parse("where a == 42 and b == 2.5 and c == 1e3") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(expr) =>
      match expr {
        @query.Binary(@query.And, left, right) => {
          assert_eq(right, @query.Binary(@query.Eq, @query.Field("c"), @query.LitNum(1000.0)))
          match left {
            @query.Binary(@query.And, first, second) => {
              assert_eq(first, @query.Binary(@query.Eq, @query.Field("a"), @query.LitInt(42L)))
              assert_eq(second, @query.Binary(@query.Eq, @query.Field("b"), @query.LitNum(2.5)))
            }
            _ => fail("expected a nested and on the left: " + left.to_repr().to_string())
          }
        }
        _ => fail("expected an and expression")
      }
    _ => fail("expected a where stage")
  }
}

///|
test "query: function calls inside expressions" {
  let query = match @query.Query::parse("where lower(service) == \"api\" and len(msg) > 10") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.stages[0] {
    @query.Where(@query.Binary(@query.And, left, right)) => {
      assert_eq(
        left,
        @query.Binary(
          @query.Eq,
          @query.Call("lower", [@query.Field("service")]),
          @query.LitStr("api"),
        ),
      )
      assert_eq(
        right,
        @query.Binary(
          @query.Gt,
          @query.Call("len", [@query.Field("msg")]),
          @query.LitInt(10L),
        ),
      )
    }
    _ => fail("expected a where stage")
  }
}
