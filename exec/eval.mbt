// The expression evaluator and the scalar function library.

///|
/// The environment an expression is evaluated in: where each column sits in the
/// row, plus a cache of compiled patterns so a `=~` in a filter does not
/// recompile its pattern for every row.
pub(all) struct Env {
  positions : Map[String, Int]
  patterns : Map[String, @string.Regex]
}

///|
/// Builds the environment for a relation with the given column order.
pub fn Env::for_columns(columns : Array[String]) -> Env {
  let positions : Map[String, Int] = Map([])
  let mut index = 0
  for name in columns {
    positions[name] = index
    index += 1
  }
  { positions, patterns: Map([]), }
}

///|
fn Env::position(self : Env, name : String) -> Int? {
  self.positions.get(name)
}

///|
/// Reads a field from a row. A name the relation does not carry is null, which
/// is what makes `user is null` work on a file where the field appears midway.
pub fn read_field(
  env : Env,
  row : Array[@moonloom.Value],
  name : String,
) -> @moonloom.Value {
  match env.position(name) {
    Some(at) => if at < row.length() { row[at] } else { @moonloom.Null }
    None => @moonloom.Null
  }
}

///|
/// Compiles a pattern once and reuses it. A pattern that will not compile falls
/// back to a plain substring test instead of failing the query.
fn matches_pattern(env : Env, pattern : String, text : String) -> Bool {
  match env.patterns.get(pattern) {
    Some(compiled) => compiled.execute(text) is Some(_)
    None => {
      let built : @string.Regex? = Some(@string.Regex::Regex(pattern)) catch {
        _ => None
      }
      match built {
        Some(compiled) => {
          env.patterns[pattern] = compiled
          compiled.execute(text) is Some(_)
        }
        None => text.contains(pattern)
      }
    }
  }
}

///|
/// Character count, which is what a user means by the length of a field.
pub fn character_length(text : String) -> Int {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
/// How a value compares with another for ordering predicates.
///
/// Numbers compare with numbers, and everything else falls back to the total
/// order used by sorting, so a comparison is never undefined.
fn compare_for_order(left : @moonloom.Value, right : @moonloom.Value) -> Int {
  match (left.as_num(), right.as_num()) {
    (Some(a), Some(b)) => if a < b { -1 } else if a > b { 1 } else { 0 }
    _ => left.compare(right)
  }
}

///|
/// Equality as a query means it: `200` and `"200"` agree, because a log field is
/// often read as text and compared against a number.
fn values_equal(left : @moonloom.Value, right : @moonloom.Value) -> Bool {
  match (left, right) {
    (@moonloom.Null, @moonloom.Null) => true
    (@moonloom.Null, _) | (_, @moonloom.Null) => false
    _ =>
      match (left.as_num(), right.as_num()) {
        (Some(a), Some(b)) => a == b
        _ => left.display() == right.display()
      }
  }
}

///|
fn numeric(
  left : @moonloom.Value,
  right : @moonloom.Value,
) -> (Double, Double)? {
  match (left.as_num(), right.as_num()) {
    (Some(a), Some(b)) => Some((a, b))
    _ => None
  }
}

///|
/// Evaluates one expression against one row.
pub fn eval(
  env : Env,
  expr : @query.Expr,
  row : Array[@moonloom.Value],
) -> @moonloom.Value {
  match expr {
    @query.LitInt(value) => @moonloom.Int(value)
    @query.LitNum(value) => @moonloom.Num(value)
    @query.LitStr(text) => @moonloom.Str(text)
    @query.LitBool(value) => @moonloom.Bool(value)
    @query.LitNull => @moonloom.Null
    @query.Field(name) => read_field(env, row, name)
    @query.List(_) => @moonloom.Null
    @query.Unary(op, inner) =>
      match op {
        @query.Neg =>
          match eval(env, inner, row).as_num() {
            Some(value) => number_value(-value)
            None => @moonloom.Null
          }
        @query.Not => @moonloom.Bool(!eval(env, inner, row).truthy())
      }
    @query.Binary(op, left, right) => eval_binary(env, op, left, right, row)
    @query.Call(name, args) => call_function(env, name, args, row)
  }
}

///|
fn number_value(value : Double) -> @moonloom.Value {
  if value.is_nan() || value.is_inf() {
    return @moonloom.Null
  }
  let rounded = value.to_int64()
  if rounded.to_double() == value && value.abs() < 1.0e15 {
    @moonloom.Int(rounded)
  } else {
    @moonloom.Num(value)
  }
}

///|
fn eval_binary(
  env : Env,
  op : @query.BinOp,
  left_expr : @query.Expr,
  right_expr : @query.Expr,
  row : Array[@moonloom.Value],
) -> @moonloom.Value {
  // `and` and `or` short-circuit, so the right side is only evaluated when the
  // left side does not already decide the answer.
  match op {
    @query.And => {
      let left = eval(env, left_expr, row)
      if !left.truthy() {
        return @moonloom.Bool(false)
      }
      return @moonloom.Bool(eval(env, right_expr, row).truthy())
    }
    @query.Or => {
      let left = eval(env, left_expr, row)
      if left.truthy() {
        return @moonloom.Bool(true)
      }
      return @moonloom.Bool(eval(env, right_expr, row).truthy())
    }
    _ => ()
  }
  let left = eval(env, left_expr, row)
  let right = eval(env, right_expr, row)
  match op {
    @query.Add =>
      match numeric(left, right) {
        Some(pair) => number_value(pair.0 + pair.1)
        None =>
          match (left, right) {
            (@moonloom.Null, @moonloom.Null) => @moonloom.Null
            _ => @moonloom.Str(left.display() + right.display())
          }
      }
    @query.Sub =>
      match numeric(left, right) {
        Some(pair) => number_value(pair.0 - pair.1)
        None => @moonloom.Null
      }
    @query.Mul =>
      match numeric(left, right) {
        Some(pair) => number_value(pair.0 * pair.1)
        None => @moonloom.Null
      }
    @query.Div =>
      match numeric(left, right) {
        Some(pair) =>
          if pair.1 == 0.0 {
            @moonloom.Null
          } else {
            number_value(pair.0 / pair.1)
          }
        None => @moonloom.Null
      }
    @query.Mod =>
      match numeric(left, right) {
        Some(pair) =>
          if pair.1 == 0.0 {
            @moonloom.Null
          } else {
            number_value(
              pair.0 - pair.1 * (pair.0 / pair.1).to_int().to_double(),
            )
          }
        None => @moonloom.Null
      }
    @query.Eq => @moonloom.Bool(values_equal(left, right))
    @query.Ne => @moonloom.Bool(!values_equal(left, right))
    @query.Lt => @moonloom.Bool(compare_for_order(left, right) < 0)
    @query.Le => @moonloom.Bool(compare_for_order(left, right) <= 0)
    @query.Gt => @moonloom.Bool(compare_for_order(left, right) > 0)
    @query.Ge => @moonloom.Bool(compare_for_order(left, right) >= 0)
    @query.Contains => @moonloom.Bool(left.display().contains(right.display()))
    @query.StartsWith =>
      @moonloom.Bool(left.display().has_prefix(right.display()))
    @query.EndsWith =>
      @moonloom.Bool(left.display().has_suffix(right.display()))
    @query.Match =>
      @moonloom.Bool(matches_pattern(env, right.display(), left.display()))
    @query.NotMatch =>
      @moonloom.Bool(!matches_pattern(env, right.display(), left.display()))
    @query.In =>
      match right_expr {
        @query.List(items) => {
          let mut found = false
          for item in items {
            if values_equal(left, eval(env, item, row)) {
              found = true
            }
          }
          @moonloom.Bool(found)
        }
        _ => @moonloom.Bool(values_equal(left, right))
      }
    @query.And | @query.Or => @moonloom.Bool(false)
  }
}

///|
/// The scalar function library. Unknown names evaluate to null so that a query
/// over data with an unusual function still scans instead of aborting.
fn call_function(
  env : Env,
  name : String,
  args : Array[@query.Expr],
  row : Array[@moonloom.Value],
) -> @moonloom.Value {
  let lower = name.to_lower()
  match lower {
    "lower" => unary_text(env, args, row, fn(text) { text.to_lower() })
    "upper" => unary_text(env, args, row, fn(text) { text.to_upper() })
    "trim" => unary_text(env, args, row, fn(text) { text.trim().to_owned() })
    "len" | "length" =>
      match args {
        [only] =>
          @moonloom.Int(
            character_length(eval(env, only, row).display()).to_int64(),
          )
        _ => @moonloom.Null
      }
    "str" | "text" =>
      match args {
        [only] => @moonloom.Str(eval(env, only, row).display())
        _ => @moonloom.Null
      }
    "int" | "to_int" =>
      match args {
        [only] =>
          match eval(env, only, row).as_int() {
            Some(value) => @moonloom.Int(value)
            None => @moonloom.Null
          }
        _ => @moonloom.Null
      }
    "float" | "num" | "to_float" =>
      match args {
        [only] =>
          match eval(env, only, row).as_num() {
            Some(value) => @moonloom.Num(value)
            None => @moonloom.Null
          }
        _ => @moonloom.Null
      }
    "type" =>
      match args {
        [only] => @moonloom.Str(eval(env, only, row).kind().label())
        _ => @moonloom.Null
      }
    "is_null" =>
      match args {
        [only] => @moonloom.Bool(eval(env, only, row).is_null())
        _ => @moonloom.Null
      }
    "is_num" =>
      match args {
        [only] => @moonloom.Bool(eval(env, only, row).as_num() is Some(_))
        _ => @moonloom.Null
      }
    "coalesce" => {
      let mut result = @moonloom.Null
      for arg in args {
        let value = eval(env, arg, row)
        if !value.is_null() {
          result = value
          break
        }
      }
      result
    }
    "if" | "iif" =>
      match args {
        [condition, yes, no] =>
          if eval(env, condition, row).truthy() {
            eval(env, yes, row)
          } else {
            eval(env, no, row)
          }
        _ => @moonloom.Null
      }
    "concat" => {
      let out = StringBuilder()
      for arg in args {
        out.write_string(eval(env, arg, row).display())
      }
      @moonloom.Str(out.to_string())
    }
    "substr" | "substring" =>
      match args {
        [text, start] =>
          match
            (eval(env, text, row).display(), eval(env, start, row).as_int()) {
            (source, Some(from)) => slice_text(source, from, None)
            _ => @moonloom.Null
          }
        [text, start, length] =>
          match
            (
              eval(env, text, row).display(),
              eval(env, start, row).as_int(),
              eval(env, length, row).as_int(),
            ) {
            (source, Some(from), Some(count)) =>
              slice_text(source, from, Some(count))
            _ => @moonloom.Null
          }
        _ => @moonloom.Null
      }
    "replace" =>
      match args {
        [text, old, fresh] =>
          @moonloom.Str(
            eval(env, text, row)
            .display()
            .replace_all(
              old=eval(env, old, row).display(),
              new=eval(env, fresh, row).display(),
            ),
          )
        _ => @moonloom.Null
      }
    "abs" => unary_number(env, args, row, fn(value) { value.abs() })
    "ceil" => unary_number(env, args, row, fn(value) { @math.ceil(value) })
    "floor" => unary_number(env, args, row, fn(value) { @math.floor(value) })
    "round" =>
      unary_number(env, args, row, fn(value) { @math.floor(value + 0.5) })
    "sqrt" => unary_number(env, args, row, fn(value) { value.sqrt() })
    "sign" =>
      unary_number(env, args, row, fn(value) {
        if value > 0.0 {
          1.0
        } else if value < 0.0 {
          -1.0
        } else {
          0.0
        }
      })
    "pow" =>
      match args {
        [base, exponent] =>
          match
            (eval(env, base, row).as_num(), eval(env, exponent, row).as_num()) {
            (Some(a), Some(b)) => number_value(@math.pow(a, b))
            _ => @moonloom.Null
          }
        _ => @moonloom.Null
      }
    "min" => fold_numbers(env, args, row, true)
    "max" => fold_numbers(env, args, row, false)
    _ => @moonloom.Null
  }
}

///|
/// Cuts a string by character offsets. A start past the end gives an empty
/// string and a negative start counts from the end.
fn slice_text(
  source : String,
  from : Int64,
  length : Int64?,
) -> @moonloom.Value {
  let characters = source.iter().to_array()
  let total = characters.length()
  let mut start = from.to_int()
  if start < 0 {
    start = total + start
  }
  if start < 0 {
    start = 0
  }
  if start > total {
    start = total
  }
  let mut finish = total
  match length {
    Some(count) => {
      let end = start + count.to_int()
      finish = if end < start {
        start
      } else if end > total {
        total
      } else {
        end
      }
    }
    None => ()
  }
  let out = StringBuilder()
  for index = start; index < finish; index = index + 1 {
    out.write_char(characters[index])
  }
  @moonloom.Str(out.to_string())
}

///|
fn unary_text(
  env : Env,
  args : Array[@query.Expr],
  row : Array[@moonloom.Value],
  transform : (String) -> String,
) -> @moonloom.Value {
  match args {
    [only] => @moonloom.Str(transform(eval(env, only, row).display()))
    _ => @moonloom.Null
  }
}

///|
fn unary_number(
  env : Env,
  args : Array[@query.Expr],
  row : Array[@moonloom.Value],
  transform : (Double) -> Double,
) -> @moonloom.Value {
  match args {
    [only] =>
      match eval(env, only, row).as_num() {
        Some(value) => number_value(transform(value))
        None => @moonloom.Null
      }
    _ => @moonloom.Null
  }
}

///|
fn fold_numbers(
  env : Env,
  args : Array[@query.Expr],
  row : Array[@moonloom.Value],
  want_min : Bool,
) -> @moonloom.Value {
  let mut best : Double? = None
  for arg in args {
    match eval(env, arg, row).as_num() {
      Some(value) =>
        best = match best {
          None => Some(value)
          Some(current) =>
            if want_min {
              Some(if value < current { value } else { current })
            } else {
              Some(if value > current { value } else { current })
            }
        }
      None => ()
    }
  }
  match best {
    Some(value) => number_value(value)
    None => @moonloom.Null
  }
}
