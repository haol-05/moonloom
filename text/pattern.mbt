// Pattern extraction.
//
// A pattern names the parts of a line that matter, for example
// `{time} {level} {service}: {message}`. Fields are filled left to right and
// every field stops at the next literal in the pattern, which makes the match
// non-greedy and predictable. Two neighbouring fields would be ambiguous, so a
// pattern like `{a}{b}` is rejected at compile time instead of guessing.

///|
/// One piece of a compiled pattern.
pub(all) enum PatternPart {
  Literal(String)
  Field(String)
} derive(Eq, Debug)

///|
pub extend PatternPart with Eq::{not_equal, equal}

///|
pub extend PatternPart with @debug.Debug::{to_repr}

///|
/// A compiled pattern.
pub(all) struct Pattern {
  parts : Array[PatternPart]
  source : String
} derive(Eq, Debug)

///|
pub extend Pattern with Eq::{not_equal, equal}

///|
pub extend Pattern with @debug.Debug::{to_repr}

///|
/// Compiles a pattern. `{{` and `}}` produce literal braces.
///
/// Returns `None` for a malformed pattern: an unclosed `{`, an empty name, or
/// two fields with no literal between them.
pub fn Pattern::compile(source : String) -> Pattern? {
  let parts : Array[PatternPart] = []
  let literal = StringBuilder()
  let cu = source.code_units()
  let n = cu.length()
  let mut index = 0
  while index < n {
    let c = cu[index]
    if @ascii.code_unit_is(c, '{') {
      if index + 1 < n && @ascii.code_unit_is(cu[index + 1], '{') {
        literal.write_char('{')
        index += 2
        continue
      }
      let close = find_index(cu, index + 1, '}')
      if close < 0 {
        return None
      }
      let name = source[index + 1:close].to_owned().trim().to_owned()
      if name == "" {
        return None
      }
      if !literal.is_empty() {
        parts.push(Literal(literal.to_string()))
        literal.reset()
      }
      if parts.length() > 0 {
        match parts[parts.length() - 1] {
          Field(_) => return None
          Literal(_) => ()
        }
      }
      parts.push(Field(name))
      index = close + 1
    } else if @ascii.code_unit_is(c, '}') {
      if index + 1 < n && @ascii.code_unit_is(cu[index + 1], '}') {
        literal.write_char('}')
        index += 2
        continue
      }
      return None
    } else {
      match c.to_int().to_char() {
        Some(ch) => literal.write_char(ch)
        None => ()
      }
      index += 1
    }
  }
  if !literal.is_empty() {
    parts.push(Literal(literal.to_string()))
  }
  if parts.length() == 0 {
    return None
  }
  Some({ parts, source })
}

///|
fn find_index(cu : ArrayView[UInt16], start : Int, needle : Char) -> Int {
  let mut index = start
  while index < cu.length() {
    if @ascii.code_unit_is(cu[index], needle) {
      return index
    }
    index += 1
  }
  -1
}

///|
/// Index of `needle` in `line` at or after `from`.
pub fn find_from(line : String, needle : String, from : Int) -> Int? {
  let n = line.code_units().length()
  let m = needle.code_units().length()
  if m == 0 {
    return if from <= n { Some(from) } else { None }
  }
  if from + m > n {
    return None
  }
  let cu = line.code_units()
  let nu = needle.code_units()
  let mut index = from
  while index + m <= n {
    let mut offset = 0
    let mut same = true
    while offset < m {
      if cu[index + offset] != nu[offset] {
        same = false
        break
      }
      offset += 1
    }
    if same {
      return Some(index)
    }
    index += 1
  }
  None
}

///|
/// Applies a compiled pattern to one line. Returns `None` when a literal of the
/// pattern is missing or the line does not end where the pattern ends.
pub fn Pattern::capture(self : Pattern, line : String) -> @moonloom.Record? {
  let record = @moonloom.Record::empty(0, line)
  let parts = self.parts
  let mut position = 0
  let mut index = 0
  while index < parts.length() {
    match parts[index] {
      Literal(text) => {
        match find_from(line, text, position) {
          Some(at) => position = at + text.code_units().length()
          None => return None
        }
      }
      Field(name) => {
        let rest_is_field = index + 1 < parts.length() &&
          (match parts[index + 1] {
            Field(_) => true
            Literal(_) => false
          })
        if rest_is_field {
          return None
        }
        if index + 1 == parts.length() {
          let captured = line[position:].to_owned()
          record.set(name, @moonloom.Value::from_text(captured))
          position = line.code_units().length()
        } else {
          match parts[index + 1] {
            Literal(next) => {
              match find_from(line, next, position) {
                Some(at) => {
                  let captured = line[position:at].to_owned()
                  record.set(name, @moonloom.Value::from_text(captured))
                  // Leave the position on the literal itself; the literal part
                  // consumes it on the next iteration.
                  position = at
                }
                None => return None
              }
            }
            Field(_) => return None
          }
        }
      }
    }
    index += 1
  }
  if position != line.code_units().length() {
    return None
  }
  Some(record)
}

///|
/// Reads text with a pattern, one record per line.
pub fn parse_pattern(
  text : String,
  pattern : String,
  max_records? : Int,
) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("pattern")
  let limit = max_records.unwrap_or(0)
  let compiled = match Pattern::compile(pattern) {
    Some(p) => p
    None => {
      dataset.skip(
        @moonloom.Diagnostic::new("bad-pattern", 0, "pattern '" + pattern + "' is not valid"),
      )
      return dataset
    }
  }
  let mut line_number = 0
  for line in split_lines(strip_bom(text)) {
    line_number += 1
    if is_blank(line) {
      continue
    }
    if limit > 0 && dataset.rows() >= limit {
      break
    }
    match compiled.capture(line) {
      Some(record) => {
        let named = @moonloom.Record::empty(line_number, line)
        for name in record.order {
          named.set(name, record.field(name))
        }
        dataset.add(named)
        dataset.lines_read += 1
      }
      None =>
        dataset.skip(
          @moonloom.Diagnostic::new(
            "no-match",
            line_number,
            "line does not match the pattern",
          ),
        )
    }
  }
  dataset
}
