// Behaviour tests for the renderers.

///|
fn result_of(csv : String, query : String) -> @exec.ResultSet raise {
  match @exec.query_text(csv, query, format="csv") {
    Ok(result) => result
    Err(message) => fail(message)
  }
}

///|
test "render: display width counts wide characters as two columns" {
  assert_eq(@render.display_width("abc"), 3)
  assert_eq(@render.display_width("日志"), 4)
  assert_eq(@render.display_width("a日b"), 4)
  assert_eq(@render.display_width(""), 0)
}

///|
test "render: truncation respects the display width" {
  assert_eq(@render.truncate_width("abcdef", 10), "abcdef")
  assert_eq(@render.truncate_width("abcdef", 4), "abc\u{2026}")
  assert_eq(@render.display_width(@render.truncate_width("日志日志", 5)), 5)
}

///|
test "render: a table is aligned and keeps its header when empty" {
  let result = result_of(
    "service,level\napi,error\nweb,info\n", "stats count() as n by service | sort service asc",
  )
  let text = @render.render_table(result)
  assert_true(text.contains("| service | n |"))
  assert_true(text.contains("| api     | 1 |"))
  let empty = result_of("service\napi\n", "where service == \"nope\"")
  let empty_text = @render.render_table(empty)
  assert_true(empty_text.contains("| service |"))
  assert_false(empty_text.contains("| api"))
}

///|
test "render: row numbers are optional" {
  let result = result_of("a\n1\n2\n", "limit 2")
  let numbered = @render.render_table(
    result,
    options=@render.TableOptions::new(row_numbers=true),
  )
  assert_true(numbered.contains("| # | a |"))
  assert_true(numbered.contains("| 1 | 1 |"))
}

///|
test "render: JSON keeps the value kinds" {
  let result = result_of("n,f,flag,t\n1,2.5,true,hi\n", "limit 1")
  let text = @render.render_json(result)
  assert_true(text.contains("\"n\":1"))
  assert_true(text.contains("\"f\":2.5"))
  assert_true(text.contains("\"flag\":true"))
  assert_true(text.contains("\"t\":\"hi\""))
}

///|
test "render: JSON escapes what has to be escaped" {
  let result = result_of("t\n\"a\"\"b\"\n", "limit 1")
  let text = @render.render_json(result)
  assert_true(text.contains("\"t\":\"a\\\"b\""))
}

///|
test "render: JSON Lines writes one object per row" {
  let result = result_of("a\n1\n2\n", "limit 2")
  let text = @render.render_jsonl(result)
  assert_eq(text, "{\"a\":1}\n{\"a\":2}\n")
}

///|
test "render: CSV quotes what would break the format" {
  let result = result_of("a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", "limit 1")
  let text = @render.render_csv(result)
  assert_eq(text, "a,b\n\"x,y\",\"say \"\"hi\"\"\"\n")
}

///|
test "render: Markdown escapes pipes" {
  let result = result_of("a,b\n1,\"x|y\"\n", "limit 1")
  let text = @render.render_markdown(result)
  assert_true(text.contains("| a | b |"))
  assert_true(text.contains("| 1 | x\\|y |"))
}

///|
test "render: the named dispatch falls back to the table" {
  let result = result_of("a\n1\n", "limit 1")
  assert_eq(@render.render(result, "csv"), "a\n1\n")
  assert_true(@render.render(result, "table").contains("| a |"))
  assert_true(@render.render(result, "nonsense").contains("| a |"))
}

///|
test "render: the table rounds long fractions but the exports do not" {
  let result = result_of("v\n1\n2\n", "stats avg(v) as mean")
  assert_true(@render.render_table(result).contains("1.5"))
  let thirds = result_of("v\n1\n1\n1\n2\n", "stats avg(v) as mean")
  assert_true(@render.render_table(thirds).contains("1.25"))
  assert_true(@render.render_json(thirds).contains("1.25"))
}

///|
test "render: a stats line names what the query cost" {
  let result = result_of(
    "a,b\n1,x\n2,y\n3,x\n", "where b == \"x\" | stats count() as n by a",
  )
  let text = @render.render_stats(result.stats)
  assert_true(text.contains("rows in 3"))
  assert_true(text.contains("index pruned 1"))
  assert_true(text.contains("out 2"))
  // Without an index the same predicate is answered by the filter instead, and
  // the line says so.
  match
    @exec.query_text(
      "a,b\n1,x\n2,y\n3,x\n",
      "where b == \"x\" | stats count() as n by a",
      format="csv",
      index=false,
    ) {
    Ok(plain) => {
      let plain_text = @render.render_stats(plain.stats)
      assert_true(plain_text.contains("filtered 1"))
      assert_false(plain_text.contains("index pruned"))
    }
    Err(message) => fail(message)
  }
}

///|
test "render: the schema table reports kinds and counts" {
  let dataset = @text.parse_csv("a,b\n1,x\n2,\n")
  let text = @render.render_schema(@moonloom.infer_fields(dataset.table))
  assert_true(text.contains("name"))
  assert_true(text.contains("kind"))
  assert_true(text.contains("| a"))
  assert_true(text.contains("| b"))
  assert_true(text.contains("int"))
  assert_true(text.contains("text"))
}
