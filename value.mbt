// The value model shared by every MoonLoom package.
//
// MoonLoom reads semi-structured text, so the type of a field is decided while
// reading rather than declared up front. `Int` keeps whole numbers exact,
// `Num` holds fractional numbers, `Str` keeps every other payload verbatim, and
// `Null` marks a field that was absent or empty.

///|
/// One field value.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int64)
  Num(Double)
  Str(String)
} derive(Eq, Debug)

///|
pub extend Value with Eq::{not_equal, equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
/// The coarse type of a value, used by schema inference and by the renderer.
/// `KindMixed` is never produced by a single value; inference reports it for a
/// column whose rows disagree.
pub(all) enum ValueKind {
  KindNull
  KindBool
  KindInt
  KindNum
  KindText
  KindMixed
} derive(Eq, Debug)

///|
pub extend ValueKind with Eq::{not_equal, equal}

///|
pub extend ValueKind with @debug.Debug::{to_repr}

///|
/// Stable label of a kind, as printed by `moonloom schema`.
pub fn ValueKind::label(self : ValueKind) -> String {
  match self {
    KindNull => "null"
    KindBool => "bool"
    KindInt => "int"
    KindNum => "num"
    KindText => "text"
    KindMixed => "mixed"
  }
}

///|
/// The kind of a value.
pub fn Value::kind(self : Value) -> ValueKind {
  match self {
    Null => KindNull
    Bool(_) => KindBool
    Int(_) => KindInt
    Num(_) => KindNum
    Str(_) => KindText
  }
}

///|
pub fn Value::is_null(self : Value) -> Bool {
  match self {
    Null => true
    _ => false
  }
}

///|
/// User-facing text of a value. Strings are printed verbatim, without quotes;
/// use `Value::json_text` when the output has to stay machine readable.
pub fn Value::display(self : Value) -> String {
  match self {
    Null => ""
    Bool(b) => if b { "true" } else { "false" }
    Int(i) => i.to_string()
    Num(d) => format_double(d)
    Str(s) => s
  }
}

///|
/// The text of a value as it would appear inside a JSON document.
pub fn Value::json_text(self : Value) -> String {
  match self {
    Null => "null"
    Bool(b) => if b { "true" } else { "false" }
    Int(i) => i.to_string()
    Num(d) => format_double(d)
    Str(s) => "\"" + escape_json(s) + "\""
  }
}

///|
/// Numeric view of a value: integers are widened, booleans become 0 or 1, and
/// everything else has no numeric view.
pub fn Value::as_num(self : Value) -> Double? {
  match self {
    Int(i) => Some(i.to_double())
    Num(d) => Some(d)
    Bool(b) => Some(if b { 1.0 } else { 0.0 })
    _ => None
  }
}

///|
/// Integral view of a value. Fractional values are only accepted when they have
/// no fractional part, so `1.0` converts while `1.5` does not.
pub fn Value::as_int(self : Value) -> Int64? {
  match self {
    Int(i) => Some(i)
    Num(d) => {
      let t = d.to_int64()
      if t.to_double() == d {
        Some(t)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Text view of a value, used by string functions and by grouping.
pub fn Value::as_text(self : Value) -> String {
  self.display()
}

///|
/// Truth value used by `where` and by boolean functions. Missing values are
/// false, numbers are true when non-zero, and non-empty strings are true.
pub fn Value::truthy(self : Value) -> Bool {
  match self {
    Null => false
    Bool(b) => b
    Int(i) => i != 0L
    Num(d) => d != 0.0
    Str(s) => s != ""
  }
}

///|
fn Value::value_rank(self : Value) -> Int {
  match self {
    Null => 0
    Bool(_) => 1
    Int(_) | Num(_) => 2
    Str(_) => 3
  }
}

///|
fn compare_double(a : Double, b : Double) -> Int {
  if a.is_nan() && b.is_nan() {
    0
  } else if a.is_nan() {
    -1
  } else if b.is_nan() {
    1
  } else if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
/// Total order over values, used for sorting and for range predicates:
/// missing first, then booleans, then every number together, then text.
pub fn Value::compare(self : Value, other : Value) -> Int {
  let ra = self.value_rank()
  let rb = other.value_rank()
  if ra != rb {
    return if ra < rb { -1 } else { 1 }
  }
  match (self, other) {
    (Null, Null) => 0
    (Bool(a), Bool(b)) => if a == b { 0 } else if a { 1 } else { -1 }
    (Int(a), Int(b)) => if a == b { 0 } else if a < b { -1 } else { 1 }
    (Int(a), Num(b)) => compare_double(a.to_double(), b)
    (Num(a), Int(b)) => compare_double(a, b.to_double())
    (Num(a), Num(b)) => compare_double(a, b)
    (Str(a), Str(b)) => if a == b { 0 } else if a < b { -1 } else { 1 }
    _ => 0
  }
}

///|
/// True when two values carry the same text, ignoring their kinds. `1` and
/// `"1"` agree here, which is what a text filter over a log expects.
pub fn Value::text_eq(self : Value, other : Value) -> Bool {
  self.display() == other.display()
}

///|
fn looks_like_integer(text : StringView) -> Bool {
  let cu = text.code_units()
  let n = cu.length()
  if n == 0 {
    return false
  }
  let mut index = 0
  if @ascii.ascii_is_sign(cu[0]) {
    index = 1
  }
  if index >= n {
    return false
  }
  while index < n {
    if !@ascii.ascii_is_digit(cu[index]) {
      return false
    }
    index += 1
  }
  true
}

///|
fn looks_like_number(text : StringView) -> Bool {
  let cu = text.code_units()
  let n = cu.length()
  if n == 0 {
    return false
  }
  let mut digits = 0
  let mut dots = 0
  let mut exponent = false
  let mut index = 0
  if @ascii.ascii_is_sign(cu[0]) {
    index = 1
  }
  while index < n {
    let c = cu[index]
    if @ascii.ascii_is_digit(c) {
      digits += 1
    } else if @ascii.code_unit_is(c, '.') {
      dots += 1
    } else if @ascii.code_unit_is(c, 'e') || @ascii.code_unit_is(c, 'E') {
      if digits == 0 {
        return false
      }
      exponent = true
      index += 1
      let tail = text[index:]
      return digits > 0 && looks_like_integer(tail)
    } else {
      return false
    }
    index += 1
  }
  dots <= 1 && digits > 0 && (dots == 1 || exponent)
}

///|
/// Schema-on-read typing of one text field.
///
/// The result only claims what the text itself proves: an integer is only
/// reported when the digits round-trip, so `"007"` stays text instead of
/// silently losing its leading zeros, and a value only becomes a number when it
/// really carries a fraction or an exponent.
pub fn Value::from_text(text : String) -> Value {
  let t = text.trim()
  if t.length() == 0 {
    return Null
  }
  let lower = t.to_lower()
  if lower == "true" {
    return Bool(true)
  }
  if lower == "false" {
    return Bool(false)
  }
  if lower == "null" {
    return Null
  }
  if looks_like_integer(t) {
    try {
      let i = @string.parse_int64(t)
      if i.to_string() == t.to_owned() {
        return Int(i)
      }
    } catch {
      _ => ()
    }
  }
  if looks_like_number(t) {
    try {
      let d = @string.parse_double(t)
      if !d.is_nan() && !d.is_inf() {
        return Num(d)
      }
    } catch {
      _ => ()
    }
  }
  Str(t.to_owned())
}

///|
/// Renders a double in a compact, stable form: whole numbers lose the `.0`
/// suffix so that a count of `3` prints as `3` rather than `3.0`, while
/// fractional values keep their digits.
pub fn format_double(d : Double) -> String {
  if d.is_nan() {
    return "NaN"
  }
  if d.is_inf() {
    return if d > 0.0 { "inf" } else { "-inf" }
  }
  if d == d.to_int64().to_double() && d.abs() < 1.0e15 {
    d.to_int64().to_string()
  } else {
    d.to_string()
  }
}

///|
/// Escapes a string for embedding inside a JSON document.
pub fn escape_json(s : String) -> String {
  let out = StringBuilder()
  for c in s {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      '\u{08}' => out.write_string("\\b")
      '\u{0C}' => out.write_string("\\f")
      _ => {
        let code = c.to_int()
        if code < 0x20 {
          out.write_string("\\u")
          let hex = code.to_string(radix=16)
          let mut pad = 4 - hex.length()
          while pad > 0 {
            out.write_string("0")
            pad -= 1
          }
          out.write_string(hex)
        } else {
          out.write_char(c)
        }
      }
    }
  }
  out.to_string()
}
