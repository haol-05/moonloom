// The syntax tree of a query.

///|
/// Binary operators, in the spelling the query uses.
pub(all) enum BinOp {
  Add
  Sub
  Mul
  Div
  Mod
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
  And
  Or
  Match
  NotMatch
  Contains
  StartsWith
  EndsWith
  In
} derive(Eq, Debug)

///|
pub extend BinOp with Eq::{not_equal, equal}

///|
pub extend BinOp with @debug.Debug::{to_repr}

///|
/// Operator spelling, used by `explain` and by error messages.
pub fn BinOp::symbol(self : BinOp) -> String {
  match self {
    Add => "+"
    Sub => "-"
    Mul => "*"
    Div => "/"
    Mod => "%"
    Eq => "=="
    Ne => "!="
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
    And => "&&"
    Or => "||"
    Match => "=~"
    NotMatch => "!~"
    Contains => "contains"
    StartsWith => "startswith"
    EndsWith => "endswith"
    In => "in"
  }
}

///|
/// Unary operators.
pub(all) enum UnOp {
  Neg
  Not
} derive(Eq, Debug)

///|
pub extend UnOp with Eq::{not_equal, equal}

///|
pub extend UnOp with @debug.Debug::{to_repr}

///|
/// One expression.
pub(all) enum Expr {
  LitInt(Int64)
  LitNum(Double)
  LitStr(String)
  LitBool(Bool)
  LitNull
  Field(String)
  Unary(UnOp, Expr)
  Binary(BinOp, Expr, Expr)
  Call(String, Array[Expr])
  List(Array[Expr])
} derive(Eq, Debug)

///|
pub extend Expr with Eq::{not_equal, equal}

///|
pub extend Expr with @debug.Debug::{to_repr}

///|
/// Aggregate functions accepted by `stats`.
pub(all) enum AggFunc {
  Count
  CountDistinct
  Sum
  Avg
  Min
  Max
  Percentile
  Stddev
  First
  Last
} derive(Eq, Debug)

///|
pub extend AggFunc with Eq::{not_equal, equal}

///|
pub extend AggFunc with @debug.Debug::{to_repr}

///|
pub fn AggFunc::name(self : AggFunc) -> String {
  match self {
    Count => "count"
    CountDistinct => "count_distinct"
    Sum => "sum"
    Avg => "avg"
    Min => "min"
    Max => "max"
    Percentile => "percentile"
    Stddev => "stddev"
    First => "first"
    Last => "last"
  }
}

///|
/// Looks up an aggregate by name, accepting the spellings a query may use.
pub fn AggFunc::from_name(name : String) -> AggFunc? {
  match name {
    "count" => Some(Count)
    "count_distinct" | "distinct" | "nunique" => Some(CountDistinct)
    "sum" => Some(Sum)
    "avg" | "mean" => Some(Avg)
    "min" => Some(Min)
    "max" => Some(Max)
    "percentile" | "p" | "quantile" => Some(Percentile)
    "stddev" | "std" => Some(Stddev)
    "first" => Some(First)
    "last" => Some(Last)
    _ => None
  }
}

///|
/// One `stats` output column.
pub(all) struct AggSpec {
  func : AggFunc
  arg : Expr?
  extra : Expr?
  label : String
} derive(Eq, Debug)

///|
pub extend AggSpec with Eq::{not_equal, equal}

///|
pub extend AggSpec with @debug.Debug::{to_repr}

///|
/// One ordering key. The expression is evaluated against the row as it looks at
/// that point in the pipeline, so after `stats` it can name an aggregate.
pub(all) struct SortKey {
  expr : Expr
  desc : Bool
} derive(Eq, Debug)

///|
pub extend SortKey with Eq::{not_equal, equal}

///|
pub extend SortKey with @debug.Debug::{to_repr}

///|
/// One pipeline stage.
pub(all) enum Stage {
  Where(Expr)
  Fields(Array[String])
  Eval(String, Expr)
  Parse(String)
  Stats(Array[AggSpec], Array[String])
  Sort(Array[SortKey])
  Limit(Int)
  Top(Int, Array[SortKey])
  Dedup(Array[String])
} derive(Eq, Debug)

///|
pub extend Stage with Eq::{not_equal, equal}

///|
pub extend Stage with @debug.Debug::{to_repr}

///|
/// Stage keyword, used by `explain`.
pub fn Stage::keyword(self : Stage) -> String {
  match self {
    Where(_) => "where"
    Fields(_) => "fields"
    Eval(_, _) => "eval"
    Parse(_) => "parse"
    Stats(_, _) => "stats"
    Sort(_) => "sort"
    Limit(_) => "limit"
    Top(_, _) => "top"
    Dedup(_) => "dedup"
  }
}

///|
/// A parsed query.
pub(all) struct Query {
  source : String?
  stages : Array[Stage]
  text : String
} derive(Eq, Debug)

///|
pub extend Query with Eq::{not_equal, equal}

///|
pub extend Query with @debug.Debug::{to_repr}

///|
/// A query and where it came from.
pub fn Query::new(source : String?, stages : Array[Stage], text : String) -> Query {
  { source, stages, text }
}

///|
/// The first `where` stage, which the planner uses for index selection.
pub fn Query::first_filter(self : Query) -> Expr? {
  for stage in self.stages {
    match stage {
      Where(expr) => return Some(expr)
      _ => ()
    }
  }
  None
}

///|
/// The `stats` stage, when the query aggregates.
pub fn Query::stats_stage(self : Query) -> (Array[AggSpec], Array[String])? {
  for stage in self.stages {
    match stage {
      Stats(specs, groups) => return Some((specs, groups))
      _ => ()
    }
  }
  None
}

///|
fn join_strings(items : Array[String], separator : String) -> String {
  let out = StringBuilder()
  let mut first = true
  for item in items {
    if !first {
      out.write_string(separator)
    }
    out.write_string(item)
    first = false
  }
  out.to_string()
}

///|
/// Writes an expression back as query text.
///
/// Nested operators keep their parentheses, so the result is unambiguous even
/// though the parser would read it the same way without them. `explain` uses
/// this to show what it is about to run.
pub fn Expr::render(self : Expr) -> String {
  match self {
    LitInt(value) => value.to_string()
    LitNum(value) => @moonloom.format_double(value)
    LitStr(text) => "\"" + text + "\""
    LitBool(value) => if value { "true" } else { "false" }
    LitNull => "null"
    Field(name) => name
    Unary(Neg, inner) => "-" + inner.render_operand()
    Unary(Not, inner) => "not " + inner.render_operand()
    Binary(_, _, _) => self.render_binary()
    Call(name, args) =>
      name + "(" + join_strings(args.map(fn(arg) { arg.render() }), ", ") + ")"
    List(items) => "[" + join_strings(items.map(fn(item) { item.render() }), ", ") + "]"
  }
}

///|
fn Expr::render_binary(self : Expr) -> String {
  match self {
    Binary(op, left, right) =>
      left.render_operand() + " " + op.symbol() + " " + right.render_operand()
    _ => self.render()
  }
}

///|
/// Renders an operand, adding parentheses when it is itself an operator so that
/// precedence survives the round trip.
fn Expr::render_operand(self : Expr) -> String {
  match self {
    Binary(_, _, _) | Unary(_, _) => "(" + self.render() + ")"
    _ => self.render()
  }
}

///|
/// Writes an aggregate back as query text.
pub fn AggSpec::render(self : AggSpec) -> String {
  let out = StringBuilder()
  out.write_string(self.func.name())
  out.write_string("(")
  match self.arg {
    Some(arg) => out.write_string(arg.render())
    None => ()
  }
  match self.extra {
    Some(extra) => out.write_string(", " + extra.render())
    None => ()
  }
  out.write_string(")")
  out.write_string(" as " + self.label)
  out.to_string()
}
