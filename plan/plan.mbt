// Plan construction and explanation.

///|
/// One step of a plan, in the order the executor runs them.
pub(all) enum PlanStep {
  IndexScan(String, @moonloom.Value, Int, Int)
  Filter(@query.Expr)
  Assign(String, @query.Expr)
  ParsePattern(String)
  Project(Array[String])
  Aggregate(Array[@query.AggSpec], Array[String])
  OrderBy(Array[@query.SortKey])
  Limit(Int)
  Top(Int, Array[@query.SortKey])
  Dedup(Array[String])
} derive(Debug)

///|
pub extend PlanStep with @debug.Debug::{to_repr}

///|
/// A compiled plan.
pub(all) struct Plan {
  source : String?
  format : String
  rows : Int
  index_predicates : Array[String]
  index_kept : Int
  index_used : Bool
  columns_needed : Array[String]
  steps : Array[PlanStep]
} derive(Debug)

///|
pub extend Plan with @debug.Debug::{to_repr}

///|
/// Rows the index removed from the scan.
pub fn Plan::pruned(self : Plan) -> Int {
  if self.index_used {
    self.rows - self.index_kept
  } else {
    0
  }
}

///|
/// Share of the table the plan still has to read.
pub fn Plan::keep_ratio(self : Plan) -> Double {
  if self.rows == 0 {
    return 0.0
  }
  let kept = if self.index_used { self.index_kept } else { self.rows }
  kept.to_double() / self.rows.to_double()
}

///|
fn collect_fields(expr : @query.Expr, out : Array[String]) -> Unit {
  match expr {
    @query.Field(name) => if !out.contains(name) { out.push(name) }
    @query.Unary(_, inner) => collect_fields(inner, out)
    @query.Binary(_, left, right) => {
      collect_fields(left, out)
      collect_fields(right, out)
    }
    @query.Call(_, args) =>
      for arg in args {
        collect_fields(arg, out)
      }
    @query.List(items) =>
      for item in items {
        collect_fields(item, out)
      }
    _ => ()
  }
}

///|
fn collect_sort_fields(
  keys : Array[@query.SortKey],
  out : Array[String],
) -> Unit {
  for key in keys {
    collect_fields(key.expr, out)
  }
}

///|
/// The columns a plan has to read from the source.
///
/// Everything before the first aggregation is read; once rows are aggregated
/// the following steps can only name the group keys and the aggregate labels,
/// so the source no longer has to be told about them.
fn needed_columns(query : @query.Query) -> Array[String] {
  let out : Array[String] = []
  let mut saw_aggregate = false
  for stage in query.stages {
    if saw_aggregate {
      continue
    }
    match stage {
      @query.Where(expr) => collect_fields(expr, out)
      @query.Fields(names) =>
        for name in names {
          if !out.contains(name) {
            out.push(name)
          }
        }
      @query.Eval(_, expr) => collect_fields(expr, out)
      @query.Parse(_) => ()
      @query.Stats(specs, groups) => {
        saw_aggregate = true
        for name in groups {
          if !out.contains(name) {
            out.push(name)
          }
        }
        for spec in specs {
          match spec.arg {
            Some(arg) => collect_fields(arg, out)
            None => ()
          }
          match spec.extra {
            Some(extra) => collect_fields(extra, out)
            None => ()
          }
        }
      }
      @query.Sort(keys) => collect_sort_fields(keys, out)
      @query.Top(_, keys) => collect_sort_fields(keys, out)
      @query.Dedup(names) =>
        for name in names {
          if !out.contains(name) {
            out.push(name)
          }
        }
      @query.Limit(_) => ()
    }
  }
  out
}

///|
/// Builds the plan for a query over a table.
///
/// Passing an index lets an equality predicate in the first `where` become an
/// index scan. The filter step is still emitted, because the index only removes
/// rows it can prove cannot match.
pub fn compile(
  query : @query.Query,
  table : @moonloom.Table,
  index : @index.TableIndex?,
) -> Plan {
  let rows = table.length()
  let steps : Array[PlanStep] = []
  let predicates : Array[String] = []
  let mut kept = rows
  let mut used = false
  match (index, query.first_filter()) {
    (Some(table_index), Some(expr)) =>
      match table_index.candidates(expr) {
        Some(candidates) => {
          used = true
          kept = candidates.length()
          for label in candidates.predicates {
            predicates.push(label)
          }
          for pair in candidate_fields(expr, table_index) {
            steps.push(IndexScan(pair.0, pair.1, kept, rows))
          }
        }
        None => ()
      }
    _ => ()
  }
  for stage in query.stages {
    match stage {
      @query.Where(expr) => steps.push(Filter(expr))
      @query.Fields(names) => steps.push(Project(names))
      @query.Eval(name, expr) => steps.push(Assign(name, expr))
      @query.Parse(pattern) => steps.push(ParsePattern(pattern))
      @query.Stats(specs, groups) => steps.push(Aggregate(specs, groups))
      @query.Sort(keys) => steps.push(OrderBy(keys))
      @query.Limit(count) => steps.push(Limit(count))
      @query.Top(count, keys) => steps.push(Top(count, keys))
      @query.Dedup(names) => steps.push(Dedup(names))
    }
  }
  {
    source: query.source,
    format: "",
    rows,
    index_predicates: predicates,
    index_kept: kept,
    index_used: used,
    columns_needed: needed_columns(query),
    steps,
  }
}

///|
/// The indexed equality predicates of the filter, in the order they appear, so
/// that each one shows up as its own index scan step.
fn candidate_fields(
  expr : @query.Expr,
  table_index : @index.TableIndex,
) -> Array[(String, @moonloom.Value)] {
  let all : Array[(String, @moonloom.Value)] = []
  collect_equalities_for_plan(expr, all)
  let out : Array[(String, @moonloom.Value)] = []
  for pair in all {
    if table_index.indexed_fields().contains(pair.0) {
      out.push(pair)
    }
  }
  out
}

///|
fn collect_equalities_for_plan(
  expr : @query.Expr,
  out : Array[(String, @moonloom.Value)],
) -> Unit {
  match expr {
    @query.Binary(@query.And, left, right) => {
      collect_equalities_for_plan(left, out)
      collect_equalities_for_plan(right, out)
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
        _ => ()
      }
    _ => ()
  }
}

///|
fn percent(value : Double) -> String {
  let scaled = value * 1000.0
  let rounded = (scaled + 0.5).to_int()
  (rounded / 10).to_string() + "." + (rounded % 10).to_string() + "%"
}

///|
/// A readable plan. Every line names what the executor does and, where it
/// matters, how much work is left.
pub fn Plan::explain(self : Plan) -> String {
  let out = StringBuilder()
  out.write_string("plan\n")
  let source = match self.source {
    Some(name) => name
    None => "<input>"
  }
  out.write_string("  scan            " + source + "\n")
  out.write_string("                  rows=" + self.rows.to_string() + "\n")
  if self.index_used {
    let kept = self.index_kept
    out.write_string(
      "  index           " +
      self.index_predicates.join(" and ") +
      "  kept=" +
      kept.to_string() +
      "/" +
      self.rows.to_string() +
      " (" +
      percent(self.keep_ratio()) +
      ")\n",
    )
  }
  let mut number = 1
  for step in self.steps {
    match step {
      // The index scan is already shown above as a property of the scan, so it
      // does not take a step number of its own.
      IndexScan(_, _, _, _) => continue
      _ => ()
    }
    match step {
      Filter(expr) =>
        out.write_string(
          "  " + number.to_string() + ". filter       " + expr.render() + "\n",
        )
      Assign(name, expr) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". assign       " +
          name +
          " = " +
          expr.render() +
          "\n",
        )
      ParsePattern(pattern) =>
        out.write_string(
          "  " + number.to_string() + ". parse        " + pattern + "\n",
        )
      Project(fields) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". project      " +
          fields.join(", ") +
          "\n",
        )
      Aggregate(specs, groups) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". aggregate    " +
          specs.map(fn(spec) { spec.render() }).join(", ") +
          (if groups.length() > 0 { " by " + groups.join(", ") } else { "" }) +
          "\n",
        )
      OrderBy(keys) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". order by     " +
          render_keys(keys) +
          "\n",
        )
      Limit(count) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". limit        " +
          count.to_string() +
          "\n",
        )
      Top(count, keys) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". top          " +
          count.to_string() +
          " by " +
          render_keys(keys) +
          "\n",
        )
      Dedup(fields) =>
        out.write_string(
          "  " +
          number.to_string() +
          ". dedup        " +
          fields.join(", ") +
          "\n",
        )
      IndexScan(_, _, _, _) => ()
    }
    number += 1
  }
  out.write_string(
    "  columns         " +
    (if self.columns_needed.length() == 0 {
      "*"
    } else {
      self.columns_needed.join(", ")
    }) +
    "\n",
  )
  out.to_string()
}

///|
fn render_keys(keys : Array[@query.SortKey]) -> String {
  keys
  .map(fn(key) { key.expr.render() + (if key.desc { " desc" } else { " asc" }) })
  .join(", ")
}
