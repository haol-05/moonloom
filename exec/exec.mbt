// Execution: operators, aggregation and the entry points that run a plan.

///|
/// What the run cost, reported alongside the rows so a caller can see how much
/// of the input the index and the filters removed.
pub(all) struct ExecStats {
  rows_in : Int
  scanned : Int
  filtered_out : Int
  groups : Int
  rows_out : Int
  index_used : Bool
  pruned : Int
} derive(Debug)

///|
pub extend ExecStats with @debug.Debug::{to_repr}

///|
/// The result of a query: named columns and value rows.
pub(all) struct ResultSet {
  columns : Array[String]
  rows : Array[Array[@moonloom.Value]]
  stats : ExecStats
} derive(Debug)

///|
pub extend ResultSet with @debug.Debug::{to_repr}

///|
pub fn ResultSet::length(self : ResultSet) -> Int {
  self.rows.length()
}

///|
pub fn ResultSet::is_empty(self : ResultSet) -> Bool {
  self.rows.is_empty()
}

///|
/// Index of a column, or `None` when the result does not carry it.
pub fn ResultSet::column_index(self : ResultSet, name : String) -> Int? {
  let mut index = 0
  for column in self.columns {
    if column == name {
      return Some(index)
    }
    index += 1
  }
  None
}

///|
pub fn ResultSet::value(self : ResultSet, row : Int, column : String) -> @moonloom.Value {
  match self.column_index(column) {
    Some(at) =>
      if row < self.rows.length() && at < self.rows[row].length() {
        self.rows[row][at]
      } else {
        @moonloom.Null
      }
    None => @moonloom.Null
  }
}

///|
/// The relation an operator chain works on. `raws` keeps the source text of each
/// row so that a `parse` stage can still read it after earlier stages dropped
/// the column that held it.
priv struct Rel {
  columns : Array[String]
  rows : Array[Array[@moonloom.Value]]
  raws : Array[String]
}

///|
fn Rel::env(self : Rel) -> Env {
  Env::for_columns(self.columns)
}

///|
fn Rel::column_position(self : Rel, name : String) -> Int? {
  let mut index = 0
  for column in self.columns {
    if column == name {
      return Some(index)
    }
    index += 1
  }
  None
}

///|
/// Pads every row to the current width; used after a new column is appended.
fn Rel::widen(self : Rel) -> Unit {
  for row in self.rows {
    while row.length() < self.columns.length() {
      row.push(@moonloom.Null)
    }
  }
}

///|
fn relation_of(
  table : @moonloom.Table,
  candidates : @index.CandidateSet?,
) -> Rel {
  let columns = table.column_names()
  let rows : Array[Array[@moonloom.Value]] = []
  let raws : Array[String] = []
  match candidates {
    Some(set) =>
      for at in set.rows {
        if at < table.records.length() {
          let record = table.records[at]
          let row : Array[@moonloom.Value] = []
          for name in columns {
            row.push(record.field(name))
          }
          rows.push(row)
          raws.push(record.raw)
        }
      }
    None =>
      for record in table.records {
        let row : Array[@moonloom.Value] = []
        for name in columns {
          row.push(record.field(name))
        }
        rows.push(row)
        raws.push(record.raw)
      }
  }
  { columns, rows, raws }
}

///|
fn apply_filter(rel : Rel, expr : @query.Expr) -> Rel {
  let env = rel.env()
  let kept : Array[Array[@moonloom.Value]] = []
  let kept_raws : Array[String] = []
  let mut index = 0
  for row in rel.rows {
    if eval(env, expr, row).truthy() {
      kept.push(row)
      kept_raws.push(rel.raws[index])
    }
    index += 1
  }
  { columns: rel.columns, rows: kept, raws: kept_raws }
}

///|
fn apply_assign(rel : Rel, name : String, expr : @query.Expr) -> Rel {
  let env = rel.env()
  let position = match rel.column_position(name) {
    Some(at) => at
    None => {
      rel.columns.push(name)
      rel.columns.length() - 1
    }
  }
  rel.widen()
  for row in rel.rows {
    row[position] = eval(env, expr, row)
  }
  rel
}

///|
fn apply_parse(rel : Rel, pattern : String) -> Rel {
  match @text.Pattern::compile(pattern) {
    None => rel
    Some(compiled) => {
      let line_position = rel.column_position("line")
      for row_index = 0; row_index < rel.rows.length(); row_index = row_index + 1 {
        let text = if rel.raws[row_index] != "" {
          rel.raws[row_index]
        } else {
          match line_position {
            Some(at) => rel.rows[row_index][at].display()
            None => ""
          }
        }
        match compiled.capture(text) {
          Some(record) => {
            for name in record.order {
              let position = match rel.column_position(name) {
                Some(at) => at
                None => {
                  rel.columns.push(name)
                  rel.columns.length() - 1
                }
              }
              rel.widen()
              // An extracted value fills a column that was empty; it never
              // overwrites something the source already provided.
              if rel.rows[row_index][position].is_null() {
                rel.rows[row_index][position] = record.field(name)
              }
            }
          }
          None => ()
        }
      }
      rel
    }
  }
}

///|
fn apply_project(rel : Rel, fields : Array[String]) -> Rel {
  let out_columns : Array[String] = []
  let positions : Array[Int] = []
  for name in fields {
    out_columns.push(name)
    match rel.column_position(name) {
      Some(at) => positions.push(at)
      None => positions.push(-1)
    }
  }
  let rows : Array[Array[@moonloom.Value]] = []
  for row in rel.rows {
    let projected : Array[@moonloom.Value] = []
    for at in positions {
      if at >= 0 && at < row.length() {
        projected.push(row[at])
      } else {
        projected.push(@moonloom.Null)
      }
    }
    rows.push(projected)
  }
  { columns: out_columns, rows, raws: rel.raws }
}

///|
fn group_key(values : Array[@moonloom.Value]) -> String {
  let out = StringBuilder()
  for value in values {
    out.write_string(value.kind().label())
    out.write_string(":")
    out.write_string(value.display())
    out.write_string("\u{1F}")
  }
  out.to_string()
}

///|
/// One aggregate accumulator. Numbers are accumulated as running sums so that
/// `sum`, `avg` and `stddev` do not have to keep the data, while `percentile`
/// keeps only the numbers it needs to rank.
priv struct AggState {
  func : @query.AggFunc
  rank : Double
  mut count : Int
  mut numeric_count : Int
  mut sum : Double
  mut sum_squares : Double
  mut least_number : Double?
  mut greatest_number : Double?
  mut least_any : @moonloom.Value?
  mut greatest_any : @moonloom.Value?
  mut first : @moonloom.Value?
  mut last : @moonloom.Value?
  distinct : Set[String]
  numbers : Array[Double]
}

///|
fn AggState::new(spec : @query.AggSpec) -> AggState {
  {
    func: spec.func,
    rank: if spec.func == @query.Percentile { rank_of(spec.extra) } else { 0.0 },
    count: 0,
    numeric_count: 0,
    sum: 0.0,
    sum_squares: 0.0,
    least_number: None,
    greatest_number: None,
    least_any: None,
    greatest_any: None,
    first: None,
    last: None,
    distinct: Set([]),
    numbers: [],
  }
}

///|
/// The requested percentile, clamped to the range a percentile can have.
fn rank_of(extra : @query.Expr?) -> Double {
  let raw = match extra {
    Some(@query.LitInt(value)) => value.to_double()
    Some(@query.LitNum(value)) => value
    _ => 95.0
  }
  if raw < 0.0 {
    0.0
  } else if raw > 100.0 {
    100.0
  } else {
    raw
  }
}

///|
fn AggState::update(self : AggState, value : @moonloom.Value, counts_rows : Bool) -> Unit {
  if !counts_rows && value.is_null() {
    return
  }
  self.count += 1
  match value.as_num() {
    Some(number) => {
      self.numeric_count += 1
      self.sum += number
      self.sum_squares += number * number
      self.least_number = match self.least_number {
        None => Some(number)
        Some(current) => Some(if number < current { number } else { current })
      }
      self.greatest_number = match self.greatest_number {
        None => Some(number)
        Some(current) => Some(if number > current { number } else { current })
      }
      if self.func == @query.Percentile {
        self.numbers.push(number)
      }
    }
    None => ()
  }
  if self.func == @query.CountDistinct {
    self.distinct.add(value.display())
  }
  let comparison = match self.least_any {
    None => -1
    Some(current) => value.compare(current)
  }
  if comparison < 0 {
    self.least_any = Some(value)
  }
  let against_greatest = match self.greatest_any {
    None => 1
    Some(current) => value.compare(current)
  }
  if against_greatest > 0 {
    self.greatest_any = Some(value)
  }
  if self.first is None {
    self.first = Some(value)
  }
  self.last = Some(value)
}

///|
fn AggState::finish(self : AggState) -> @moonloom.Value {
  match self.func {
    @query.Count => @moonloom.Int(self.count.to_int64())
    @query.CountDistinct => @moonloom.Int(self.distinct.length().to_int64())
    @query.Sum =>
      if self.numeric_count == 0 {
        @moonloom.Null
      } else {
        number_value(self.sum)
      }
    @query.Avg =>
      if self.numeric_count == 0 {
        @moonloom.Null
      } else {
        number_value(self.sum / self.numeric_count.to_double())
      }
    @query.Stddev => self.finish_stddev()
    @query.Min =>
      if self.count > 0 && self.numeric_count == self.count {
        match self.least_number {
          Some(value) => number_value(value)
          None => @moonloom.Null
        }
      } else {
        match self.least_any {
          Some(value) => value
          None => @moonloom.Null
        }
      }
    @query.Max =>
      if self.count > 0 && self.numeric_count == self.count {
        match self.greatest_number {
          Some(value) => number_value(value)
          None => @moonloom.Null
        }
      } else {
        match self.greatest_any {
          Some(value) => value
          None => @moonloom.Null
        }
      }
    @query.Percentile => self.finish_percentile()
    @query.First =>
      match self.first {
        Some(value) => value
        None => @moonloom.Null
      }
    @query.Last =>
      match self.last {
        Some(value) => value
        None => @moonloom.Null
      }
  }
}

///|
fn AggState::finish_stddev(self : AggState) -> @moonloom.Value {
  if self.numeric_count < 2 {
    return @moonloom.Null
  }
  let n = self.numeric_count.to_double()
  let mean = self.sum / n
  let variance = (self.sum_squares - n * mean * mean) / (n - 1.0)
  number_value((if variance < 0.0 { 0.0 } else { variance }).sqrt())
}

///|
fn AggState::finish_percentile(self : AggState) -> @moonloom.Value {
  if self.numbers.length() == 0 {
    return @moonloom.Null
  }
  let sorted = self.numbers.copy()
  sorted.sort()
  let n = sorted.length().to_double()
  let mut position = @math.ceil(self.rank / 100.0 * n).to_int() - 1
  if position < 0 {
    position = 0
  }
  if position >= sorted.length() {
    position = sorted.length() - 1
  }
  number_value(sorted[position])
}

///|
/// Groups rows and aggregates each group.
///
/// Groups come out ordered by their group values, so the same input always
/// produces the same result regardless of the order rows arrived in.
fn apply_aggregate(rel : Rel, specs : Array[@query.AggSpec], groups : Array[String]) -> Rel {
  let env = rel.env()
  let keys : Array[Array[@moonloom.Value]] = []
  let states : Array[Array[AggState]] = []
  let lookup : Map[String, Int] = Map([])
  for row in rel.rows {
    let values : Array[@moonloom.Value] = []
    for name in groups {
      values.push(read_field(env, row, name))
    }
    let key = group_key(values)
    let slot = match lookup.get(key) {
      Some(at) => at
      None => {
        let at = keys.length()
        keys.push(values)
        let fresh : Array[AggState] = []
        for spec in specs {
          fresh.push(AggState::new(spec))
        }
        states.push(fresh)
        lookup[key] = at
        at
      }
    }
    for spec_index = 0; spec_index < specs.length(); spec_index = spec_index + 1 {
      let spec = specs[spec_index]
      let value = match spec.arg {
        Some(arg) => eval(env, arg, row)
        None => @moonloom.Null
      }
      states[slot][spec_index].update(value, spec.arg is None)
    }
  }
  // An aggregation with no grouping over no rows still has one answer: `count()`
  // is zero rather than an empty table.
  if keys.length() == 0 && groups.length() == 0 {
    keys.push([])
    let fresh : Array[AggState] = []
    for spec in specs {
      fresh.push(AggState::new(spec))
    }
    states.push(fresh)
  }
  let order : Array[Int] = []
  for index = 0; index < keys.length(); index = index + 1 {
    order.push(index)
  }
  order.sort_by(fn(a, b) { compare_group_keys(keys[a], keys[b], a, b) })
  let columns : Array[String] = []
  for name in groups {
    columns.push(name)
  }
  for spec in specs {
    columns.push(spec.label)
  }
  let rows : Array[Array[@moonloom.Value]] = []
  let raws : Array[String] = []
  for at in order {
    let row : Array[@moonloom.Value] = []
    for value in keys[at] {
      row.push(value)
    }
    for state in states[at] {
      row.push(state.finish())
    }
    rows.push(row)
    raws.push("")
  }
  { columns, rows, raws }
}

///|
fn compare_group_keys(
  left : Array[@moonloom.Value],
  right : Array[@moonloom.Value],
  left_index : Int,
  right_index : Int,
) -> Int {
  let mut index = 0
  while index < left.length() && index < right.length() {
    let comparison = left[index].compare(right[index])
    if comparison != 0 {
      return comparison
    }
    index += 1
  }
  left_index - right_index
}

///|
/// Orders rows by a list of keys. Keys are evaluated once per row and the
/// original position breaks ties, so the result does not depend on the sorting
/// algorithm being stable.
fn apply_order_by(rel : Rel, keys : Array[@query.SortKey]) -> Rel {
  if keys.length() == 0 || rel.rows.length() < 2 {
    return rel
  }
  let env = rel.env()
  let key_values : Array[Array[@moonloom.Value]] = []
  for row in rel.rows {
    let values : Array[@moonloom.Value] = []
    for key in keys {
      values.push(eval(env, key.expr, row))
    }
    key_values.push(values)
  }
  let order : Array[Int] = []
  for index = 0; index < rel.rows.length(); index = index + 1 {
    order.push(index)
  }
  order.sort_by(fn(a, b) {
    let mut result = 0
    let mut index = 0
    while index < keys.length() && result == 0 {
      let comparison = key_values[a][index].compare(key_values[b][index])
      result = if keys[index].desc { -comparison } else { comparison }
      index += 1
    }
    if result == 0 {
      a - b
    } else {
      result
    }
  })
  reorder(rel, order)
}

///|
fn reorder(rel : Rel, order : Array[Int]) -> Rel {
  let rows : Array[Array[@moonloom.Value]] = []
  let raws : Array[String] = []
  for at in order {
    rows.push(rel.rows[at])
    raws.push(rel.raws[at])
  }
  { columns: rel.columns, rows, raws }
}

///|
fn apply_limit(rel : Rel, count : Int) -> Rel {
  if count < 0 || rel.rows.length() <= count {
    return rel
  }
  let rows : Array[Array[@moonloom.Value]] = []
  let raws : Array[String] = []
  for index = 0; index < count; index = index + 1 {
    rows.push(rel.rows[index])
    raws.push(rel.raws[index])
  }
  { columns: rel.columns, rows, raws }
}

///|
/// `top n by k` is an ordering followed by a cut, which is what makes its
/// result identical to `sort k | limit n`.
fn apply_top(rel : Rel, count : Int, keys : Array[@query.SortKey]) -> Rel {
  apply_limit(apply_order_by(rel, keys), count)
}

///|
fn apply_dedup(rel : Rel, fields : Array[String]) -> Rel {
  if fields.length() == 0 {
    return rel
  }
  let env = rel.env()
  let seen : Set[String] = Set([])
  let rows : Array[Array[@moonloom.Value]] = []
  let raws : Array[String] = []
  let mut index = 0
  for row in rel.rows {
    let values : Array[@moonloom.Value] = []
    for name in fields {
      values.push(read_field(env, row, name))
    }
    let key = group_key(values)
    if !seen.contains(key) {
      seen.add(key)
      rows.push(row)
      raws.push(rel.raws[index])
    }
    index += 1
  }
  { columns: rel.columns, rows, raws }
}

///|
/// Runs a parsed query over a table.
pub fn run(
  query : @query.Query,
  table : @moonloom.Table,
  index : @index.TableIndex?,
) -> ResultSet {
  let plan = @plan.compile(query, table, index)
  let candidates = if plan.index_used {
    match (index, query.first_filter()) {
      (Some(table_index), Some(expr)) => table_index.candidates(expr)
      _ => None
    }
  } else {
    None
  }
  let mut rel = relation_of(table, candidates)
  let rows_in = table.length()
  let scanned = rel.rows.length()
  let mut filtered_out = 0
  let mut groups = 0
  for step in plan.steps {
    match step {
      @plan.IndexScan(_, _, _, _) => ()
      @plan.Filter(expr) => {
        let before = rel.rows.length()
        rel = apply_filter(rel, expr)
        filtered_out += before - rel.rows.length()
      }
      @plan.Assign(name, expr) => rel = apply_assign(rel, name, expr)
      @plan.ParsePattern(pattern) => rel = apply_parse(rel, pattern)
      @plan.Project(fields) => rel = apply_project(rel, fields)
      @plan.Aggregate(specs, group_fields) => {
        rel = apply_aggregate(rel, specs, group_fields)
        groups = rel.rows.length()
      }
      @plan.OrderBy(keys) => rel = apply_order_by(rel, keys)
      @plan.Limit(count) => rel = apply_limit(rel, count)
      @plan.Top(count, keys) => rel = apply_top(rel, count, keys)
      @plan.Dedup(fields) => rel = apply_dedup(rel, fields)
    }
  }
  {
    columns: rel.columns,
    rows: rel.rows,
    stats: {
      rows_in,
      scanned,
      filtered_out,
      groups,
      rows_out: rel.rows.length(),
      index_used: plan.index_used,
      pruned: plan.pruned(),
    },
  }
}

///|
/// Parses a query, then runs it. The parse message is returned unchanged so a
/// caller can show exactly where the mistake is.
pub fn run_text(
  query_text : String,
  table : @moonloom.Table,
  index : @index.TableIndex?,
) -> Result[ResultSet, String] {
  match @query.Query::parse(query_text) {
    Ok(query) => Ok(run(query, table, index))
    Err(message) => Err(message)
  }
}

///|
/// The whole pipeline in one call: read text, optionally index it, run a query.
///
/// This is the entry point a host program wants; the packages underneath stay
/// available for callers that already have a table or want to control the
/// index.
pub fn query_text(
  source : String,
  query_text : String,
  format? : String,
  index? : Bool,
) -> Result[ResultSet, String] {
  let dataset = @text.parse_auto(source, format?=format)
  let built = if index.unwrap_or(true) {
    Some(@index.TableIndex::build(dataset.table))
  } else {
    None
  }
  run_text(query_text, dataset.table, built)
}
