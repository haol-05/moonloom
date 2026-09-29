// Behaviour tests for the index.

///|
fn sample_table() -> @moonloom.Table {
  return @text.parse_csv(
    "service,level,duration\napi,error,12.5\napi,info,3\nweb,error,20\ndb,error,100\nweb,info,1.5\n",
  ).table
}

///|
test "index: postings list the rows that carry a value" {
  let table = sample_table()
  let index = @index.TableIndex::build(table)
  assert_eq(index.indexed_fields(), ["service", "level", "duration"])
  match index.lookup("level", "error") {
    Some(rows) => assert_eq(rows, [0, 2, 3])
    None => fail("expected postings for level")
  }
  match index.lookup("service", "web") {
    Some(rows) => assert_eq(rows, [2, 4])
    None => fail("expected postings for service")
  }
  assert_eq(index.lookup("service", "missing"), None)
}

///|
test "index: only the named fields are indexed" {
  let table = sample_table()
  let index = @index.TableIndex::build(table, fields=["level"])
  assert_eq(index.indexed_fields(), ["level"])
  assert_eq(index.lookup("service", "api"), None)
}

///|
test "index: a column that is unique per row is not worth indexing" {
  let table = @text.parse_csv("id,v\n1,a\n2,a\n3,b\n").table
  let index = @index.TableIndex::build(table, max_entries=2)
  assert_eq(index.indexed_fields(), ["v"])
}

///|
test "index: a conjunction narrows to the rows that match every predicate" {
  let table = sample_table()
  let index = @index.TableIndex::build(table)
  let query = match @query.Query::parse("where level == \"error\" and service == \"web\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.first_filter() {
    Some(expr) =>
      match index.candidates(expr) {
        Some(candidates) => {
          assert_eq(candidates.rows, [2])
          assert_eq(candidates.total, 5)
          assert_eq(candidates.pruned(), 4)
          assert_eq(candidates.predicates, ["level=error", "service=web"])
          assert_true(candidates.keep_ratio() < 0.5)
        }
        None => fail("expected candidates")
      }
    None => fail("expected a filter")
  }
}

///|
test "index: a disjunction is not used for pruning" {
  let table = sample_table()
  let index = @index.TableIndex::build(table)
  let query = match @query.Query::parse("where level == \"error\" or service == \"web\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.first_filter() {
    Some(expr) => assert_eq(index.candidates(expr), None)
    None => fail("expected a filter")
  }
}

///|
test "index: a predicate on a field the index has not seen is skipped" {
  let table = sample_table()
  let index = @index.TableIndex::build(table, fields=["level"])
  let query = match @query.Query::parse("where service == \"api\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.first_filter() {
    Some(expr) => assert_eq(index.candidates(expr), None)
    None => fail("expected a filter")
  }
}

///|
test "index: a value that is absent from the table selects nothing" {
  let table = sample_table()
  let index = @index.TableIndex::build(table)
  let query = match @query.Query::parse("where service == \"nope\"") {
    Ok(q) => q
    Err(message) => {
      fail(message)
      return
    }
  }
  match query.first_filter() {
    Some(expr) =>
      match index.candidates(expr) {
        Some(candidates) => assert_eq(candidates.rows, [])
        None => fail("expected candidates")
      }
    None => fail("expected a filter")
  }
}

///|
test "index: numbers and text reach the same posting list" {
  let table = sample_table()
  let index = @index.TableIndex::build(table)
  let by_text = index.lookup("duration", "12.5")
  let by_value = index.lookup_value("duration", @moonloom.Num(12.5))
  assert_eq(by_text, by_value)
}
