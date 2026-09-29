// `key=value` and `key: value` text.
//
// Logfmt is the shape most application loggers emit: bare `key=value` pairs
// separated by spaces, with double quotes around values that contain spaces.
// The key/value reader covers the other common shape, one pair per line, with
// an optional `[section]` header that prefixes later keys.

///|
/// Reads one logfmt line into a record. Returns `None` when the line carries no
/// pair at all.
pub fn parse_pairs_line(line : String, source_line? : Int) -> @moonloom.Record? {
  let cu = line.code_units()
  let n = cu.length()
  let record = @moonloom.Record::empty(source_line.unwrap_or(0), line)
  let mut index = 0
  let mut pairs = 0
  while index < n {
    index = skip_spaces(cu, index)
    if index >= n {
      break
    }
    let key_start = index
    while index < n &&
          !@ascii.code_unit_is(cu[index], '=') &&
          !@ascii.code_unit_is(cu[index], ' ') &&
          !@ascii.code_unit_is(cu[index], '\t') {
      index += 1
    }
    if index == key_start {
      // A stray separator: skip it and keep scanning.
      index += 1
      continue
    }
    let key = line[key_start:index].to_owned()
    index = skip_spaces(cu, index)
    if index < n && @ascii.code_unit_is(cu[index], '=') {
      index += 1
      index = skip_spaces(cu, index)
      let value = if index < n && @ascii.code_unit_is(cu[index], '"') {
        match read_quoted(cu, index) {
          Some(pair) => {
            index = pair.1
            pair.0
          }
          None => {
            index = n
            line[key_start:].to_owned()
          }
        }
      } else {
        let value_start = index
        while index < n &&
              !@ascii.code_unit_is(cu[index], ' ') &&
              !@ascii.code_unit_is(cu[index], '\t') {
          index += 1
        }
        line[value_start:index].to_owned()
      }
      record.set(key, @moonloom.Value::from_text(value))
      pairs += 1
    } else {
      // A bare flag such as `--verbose` carries no value of its own.
      record.set(key, @moonloom.Bool(true))
      pairs += 1
    }
  }
  if pairs == 0 {
    None
  } else {
    Some(record)
  }
}

///|
/// Reads logfmt text, one record per line.
pub fn parse_logfmt(text : String, max_records? : Int) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("logfmt")
  let limit = max_records.unwrap_or(0)
  let mut line_number = 0
  for line in split_lines(strip_bom(text)) {
    line_number += 1
    if is_blank(line) {
      continue
    }
    if limit > 0 && dataset.rows() >= limit {
      break
    }
    match parse_pairs_line(line, source_line=line_number) {
      Some(record) => {
        dataset.add(record)
        dataset.lines_read += 1
      }
      None =>
        dataset.skip(
          @moonloom.Diagnostic::new(
            "no-pairs", line_number, "line holds no key=value pair",
          ),
        )
    }
  }
  dataset
}

///|
/// Reads one `key: value` or `key = value` pair per line.
///
/// When `sections` is true, a `[name]` line starts a section and every later
/// key is written as `name.key`, which is what configuration files need.
pub fn parse_keyvalue(
  text : String,
  separator? : Char,
  sections? : Bool,
  max_records? : Int,
) -> @moonloom.Dataset {
  let sep = separator.unwrap_or(':')
  let use_sections = sections.unwrap_or(true)
  let limit = max_records.unwrap_or(0)
  let dataset = @moonloom.Dataset::empty("keyvalue")
  let record = @moonloom.Record::empty(1, "")
  let mut section = ""
  let mut line_number = 0
  let mut opened = false
  for line in split_lines(strip_bom(text)) {
    line_number += 1
    if is_blank(line) {
      continue
    }
    let trimmed = line.trim().to_owned()
    if use_sections &&
      trimmed.length() >= 2 &&
      trimmed.has_prefix("[") &&
      trimmed.has_suffix("]") {
      section = trimmed[1:trimmed.length() - 1].to_owned().trim().to_owned()
      continue
    }
    let cu = trimmed.code_units()
    let mut split = -1
    let mut index = 0
    while index < cu.length() {
      if @ascii.code_unit_is(cu[index], sep) {
        split = index
        break
      }
      index += 1
    }
    if split < 0 {
      dataset.skip(
        @moonloom.Diagnostic::new(
          "no-separator",
          line_number,
          "line has no '" + sep.to_string() + "' separator",
        ),
      )
      continue
    }
    let mut key = trimmed[:split].to_owned().trim().to_owned()
    if key.has_prefix("- ") {
      key = key[2:].to_owned().trim().to_owned()
    }
    let raw_value = trimmed[split + 1:].to_owned().trim().to_owned()
    let value = strip_comment(raw_value)
    if key == "" {
      dataset.skip(
        @moonloom.Diagnostic::new(
          "empty-key", line_number, "line has an empty key",
        ),
      )
      continue
    }
    let name = if section == "" { key } else { section + "." + key }
    record.set_if_absent(name, @moonloom.Value::from_text(value))
    if limit > 0 && record.size() >= limit {
      break
    }
    opened = true
  }
  if opened || record.size() > 0 {
    dataset.add(record)
    dataset.lines_read += 1
  }
  dataset
}

///|
/// Drops a trailing `#` comment from an unquoted value.
fn strip_comment(value : String) -> String {
  if value.has_prefix("\"") && value.has_suffix("\"") && value.length() >= 2 {
    return value[1:value.length() - 1].to_owned()
  }
  let cu = value.code_units()
  let mut index = 0
  let mut in_quotes = false
  while index < cu.length() {
    let c = cu[index]
    if @ascii.code_unit_is(c, '"') {
      in_quotes = !in_quotes
    } else if !in_quotes && @ascii.code_unit_is(c, '#') {
      return value[:index].to_owned().trim().to_owned()
    }
    index += 1
  }
  value
}
