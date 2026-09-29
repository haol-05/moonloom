// Behaviour tests for the planner.

///|
fn plan_table() -> @moonloom.Table {
  return @text.parse_csv(
      "service,level,duration\napi,error,12.5\napi,info,3\nweb,error,20\ndb,error,100\nweb,info,1.5\n",
    ).table
}

///|
fn compiled(text : String, index : @index.TableIndex?) -> @plan.Plan raise {
  match @query.Query::parse(text) {
    Ok(query) => @plan.compile(query, plan_table(), index)
    Err(message) => fail(message)
  }
}

///|
test "plan: steps follow the pipeline order" {
  let plan = compiled(
    "where level == \"error\" | stats count() as n by service | sort n desc | limit 2",
    None,
  )
  assert_eq(plan.steps.length(), 4)
  match plan.steps[0] {
    @plan.Filter(_) => ()
    _ => fail("expected the filter first")
  }
  match plan.steps[1] {
    @plan.Aggregate(specs, groups) => {
      assert_eq(specs.length(), 1)
      assert_eq(groups, ["service"])
    }
    _ => fail("expected an aggregate")
  }
  match plan.steps[3] {
    @plan.Limit(count) => assert_eq(count, 2)
    _ => fail("expected a limit")
  }
}

///|
test "plan: an equality predicate becomes an index scan" {
  let table = plan_table()
  let index = @index.TableIndex::build(table)
  let plan = compiled("where level == \"error\"", Some(index))
  assert_true(plan.index_used)
  assert_eq(plan.index_kept, 3)
  assert_eq(plan.rows, 5)
  assert_eq(plan.pruned(), 2)
  assert_true(plan.explain().contains("index"))
  assert_true(plan.explain().contains("level=error"))
}

///|
test "plan: without an index every row is scanned" {
  let plan = compiled("where level == \"error\"", None)
  assert_false(plan.index_used)
  assert_eq(plan.pruned(), 0)
  assert_false(plan.explain().contains("index           "))
}

///|
test "plan: only the columns the query reads are kept" {
  let plan = compiled(
    "where level == \"error\" | stats count() as n by service",
    None,
  )
  assert_eq(plan.columns_needed, ["level", "service"])
}

///|
test "plan: a stage after an aggregate does not widen the read set" {
  let plan = compiled(
    "stats avg(duration) as mean by service | sort mean desc | limit 3",
    None,
  )
  assert_eq(plan.columns_needed, ["service", "duration"])
}

///|
test "plan: explain names every step and the source" {
  let plan = compiled("from app.log | where level == \"error\" | limit 1", None)
  let text = plan.explain()
  assert_true(text.contains("scan            app.log"))
  assert_true(text.contains("rows=5"))
  assert_true(text.contains("filter"))
  assert_true(text.contains("level == \"error\""))
  assert_true(text.contains("limit        1"))
  assert_true(text.contains("columns         level"))
}

///|
test "plan: top is planned as a top step" {
  let plan = compiled("top 2 by duration desc", None)
  match plan.steps[0] {
    @plan.Top(count, keys) => {
      assert_eq(count, 2)
      assert_eq(keys.length(), 1)
      assert_true(keys[0].desc)
    }
    _ => fail("expected a top step")
  }
}
