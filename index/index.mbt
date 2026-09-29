// The inverted index and the candidate pruning it enables.

///|
/// Postings of one field.
pub(all) struct FieldIndex {
  field : String
  postings : Map[String, Array[Int]]
  entries : Int
} derive(Debug)

///|
pub extend FieldIndex with @debug.Debug::{to_repr}

///|
/// An index over a table. `order` keeps the indexed field names in a stable
/// order so that `explain` and statistics are reproducible.
pub(all) struct TableIndex {
  fields : Map[String, FieldIndex]
  order : Array[String]
  rows : Int
} derive(Debug)

///|
pub extend TableIndex with @debug.Debug::{to_repr}

///|
/// Builds an index. Without an explicit field list every column is indexed;
/// `max_entries` stops a column whose value is unique per row from being
/// indexed, because a posting list of one row per value prunes nothing.
pub fn TableIndex::build(
  table : @moonloom.Table,
  fields? : Array[String],
  max_entries? : Int,
) -> TableIndex {
  let limit = max_entries.unwrap_or(4096)
  let wanted = match fields {
    Some(names) => names
    None => table.column_names()
  }
  let index : TableIndex = { fields: Map([]), order: [], rows: table.length(), }
  for name in wanted {
    let field : FieldIndex = { field: name, postings: Map([]), entries: 0, }
    let mut row = 0
    for record in table.records {
      let value = record.field(name)
      match value {
        @moonloom.Null => ()
        _ => {
          let key = value.display()
          match field.postings.get(key) {
            Some(ids) => ids.push(row)
            None => field.postings[key] = [row]
          }
        }
      }
      row += 1
    }
    if field.postings.length() <= limit {
      index.fields[name] = field
      index.order.push(name)
    }
  }
  index
}

///|
pub fn TableIndex::indexed_fields(self : TableIndex) -> Array[String] {
  self.order.copy()
}

///|
/// Number of distinct field/value pairs the index holds.
pub fn TableIndex::entries(self : TableIndex) -> Int {
  let mut total = 0
  for name in self.order {
    match self.fields.get(name) {
      Some(field) => total += field.entries()
      None => ()
    }
  }
  total
}

///|
pub fn FieldIndex::entries(self : FieldIndex) -> Int {
  let mut total = 0
  for _, ids in self.postings {
    total += ids.length()
  }
  total
}

///|
pub fn TableIndex::is_empty(self : TableIndex) -> Bool {
  self.order.length() == 0
}

///|
/// Row ids carrying a value in an indexed field, sorted ascending.
pub fn TableIndex::lookup(
  self : TableIndex,
  field : String,
  value : String,
) -> Array[Int]? {
  match self.fields.get(field) {
    Some(indexed) => indexed.postings.get(value)
    None => None
  }
}

///|
/// Same as `lookup`, taking a value and using its printed form.
pub fn TableIndex::lookup_value(
  self : TableIndex,
  field : String,
  value : @moonloom.Value,
) -> Array[Int]? {
  self.lookup(field, value.display())
}

///|
/// The rows an equality predicate can still match.
pub(all) struct CandidateSet {
  rows : Array[Int]
  predicates : Array[String]
  total : Int
} derive(Eq, Debug)

///|
pub extend CandidateSet with Eq::{not_equal, equal}

///|
pub extend CandidateSet with @debug.Debug::{to_repr}

///|
pub fn CandidateSet::length(self : CandidateSet) -> Int {
  self.rows.length()
}

///|
/// Number of rows the index removed.
pub fn CandidateSet::pruned(self : CandidateSet) -> Int {
  self.total - self.rows.length()
}

///|
/// Share of the table the index kept, between 0 and 1.
pub fn CandidateSet::keep_ratio(self : CandidateSet) -> Double {
  if self.total == 0 {
    return 0.0
  }
  self.rows.length().to_double() / self.total.to_double()
}

///|
fn intersect(left : Array[Int], right : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    if left[i] == right[j] {
      out.push(left[i])
      i += 1
      j += 1
    } else if left[i] < right[j] {
      i += 1
    } else {
      j += 1
    }
  }
  out
}

///|
/// Collects `field == literal` predicates from a conjunction.
///
/// Disjunction is left alone: intersecting posting lists is only sound for
/// conjunctions, so a query with `or` simply keeps every row and relies on the
/// filter. Growing that case is a known extension point.
fn collect_equalities(
  expr : @query.Expr,
  out : Array[(String, @moonloom.Value)],
) -> Unit {
  match expr {
    @query.Binary(@query.And, left, right) => {
      collect_equalities(left, out)
      collect_equalities(right, out)
    }
    @query.Binary(@query.Eq, left, right) =>
      match (left, right) {
        (@query.Field(name), @query.LitInt(value)) =>
          out.push((name, @moonloom.Int(value)))
        (@query.Field(name), @query.LitNum(value)) =>
          out.push((name, @moonloom.Num(value)))
        (@query.Field(name), @query.LitStr(value)) =>
          out.push((name, @moonloom.Str(value)))
        (@query.Field(name), @query.LitBool(value)) =>
          out.push((name, @moonloom.Bool(value)))
        (@query.LitInt(value), @query.Field(name)) =>
          out.push((name, @moonloom.Int(value)))
        (@query.LitNum(value), @query.Field(name)) =>
          out.push((name, @moonloom.Num(value)))
        (@query.LitStr(value), @query.Field(name)) =>
          out.push((name, @moonloom.Str(value)))
        (@query.LitBool(value), @query.Field(name)) =>
          out.push((name, @moonloom.Bool(value)))
        _ => ()
      }
    _ => ()
  }
}

///|
/// Rows that an index alone can still admit, or `None` when no indexed
/// equality predicate was found and the whole table has to be read.
pub fn TableIndex::candidates(
  self : TableIndex,
  expr : @query.Expr,
) -> CandidateSet? {
  let found : Array[(String, @moonloom.Value)] = []
  collect_equalities(expr, found)
  let usable : Array[(String, @moonloom.Value)] = []
  for pair in found {
    if self.fields.contains(pair.0) {
      usable.push(pair)
    }
  }
  if usable.length() == 0 {
    return None
  }
  let mut rows : Array[Int]? = None
  let labels : Array[String] = []
  for pair in usable {
    let ids = match self.lookup_value(pair.0, pair.1) {
      Some(found_ids) => found_ids
      None => []
    }
    labels.push(pair.0 + "=" + pair.1.display())
    rows = match rows {
      None => Some(ids)
      Some(current) => Some(intersect(current, ids))
    }
  }
  match rows {
    Some(ids) => Some({ rows: ids, predicates: labels, total: self.rows, })
    None => None
  }
}
