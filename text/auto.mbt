// Format detection and one entry point that dispatches on it.
//
// Detection reads only what it needs: the first non-blank line, plus a whole
// document parse when the line looks like JSON. It is a guess and it is
// reported, never hidden, so a caller can always name the format explicitly.

///|
/// Reads plain text as one record per line with a single `line` field. This is
/// the fallback that still lets a query count and filter over unparsed text.
pub fn parse_lines(text : String, max_records? : Int) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("lines")
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
    let record = @moonloom.Record::empty(line_number, line)
    record.set("line", @moonloom.Str(line))
    dataset.add(record)
    dataset.lines_read += 1
  }
  dataset
}

///|
fn first_content_line(text : String) -> String {
  for line in split_lines(text) {
    if !is_blank(line) {
      return line
    }
  }
  ""
}

///|
/// Guesses the format of a text: `json`, `jsonl`, `syslog`, `access`, `logfmt`,
/// `csv`, `keyvalue` or `lines`.
pub fn detect_format(text : String) -> String {
  let body = strip_bom(text)
  let first = first_content_line(body)
  if first == "" {
    return "lines"
  }
  let trimmed = first.trim().to_owned()
  // Syslog always opens with a priority in angle brackets.
  if trimmed.length() >= 3 && trimmed.has_prefix("<") {
    let close = trimmed.find(">")
    match close {
      Some(at) =>
        if at > 1 && trimmed[1:at].to_owned().trim().length() > 0 {
          return "syslog"
        }
      None => ()
    }
  }
  if trimmed.has_prefix("{") {
    if @json.valid(first) {
      return "jsonl"
    }
    return "lines"
  }
  if trimmed.has_prefix("[") {
    if @json.valid(body) {
      return "json"
    }
  }
  // Access logs put a bracketed timestamp after two short tokens.
  if trimmed.contains("[") && trimmed.contains("\"") && trimmed.contains("]") {
    let open = trimmed.find("[")
    match open {
      Some(at) =>
        if at > 0 && (trimmed[at:].to_owned().contains("]")) {
          let inside = trimmed[at + 1:].to_owned()
          match inside.find("]") {
            Some(end) =>
              if parse_timestamp(inside[:end]) is Some(_) {
                return "access"
              }
            None => ()
          }
        }
      None => ()
    }
  }
  if trimmed.contains("=") && looks_like_logfmt(trimmed) {
    return "logfmt"
  }
  let delimiter = detect_delimiter(body)
  let columns = count_outside_quotes_for_detection(first, delimiter)
  if columns > 0 {
    return "csv"
  }
  if trimmed.contains(":") || trimmed.contains("=") {
    return "keyvalue"
  }
  "lines"
}

///|
fn count_outside_quotes_for_detection(line : String, needle : Char) -> Int {
  let cu = line.code_units()
  let mut count = 0
  let mut in_quotes = false
  let mut index = 0
  while index < cu.length() {
    let c = cu[index]
    if @ascii.code_unit_is(c, '"') {
      in_quotes = !in_quotes
    } else if !in_quotes && @ascii.code_unit_is(c, needle) {
      count += 1
    }
    index += 1
  }
  count
}

///|
fn looks_like_logfmt(line : String) -> Bool {
  let parts = split_plain(line, ' ')
  let mut pairs = 0
  let mut tokens = 0
  for part in parts {
    if part.trim().length() == 0 {
      continue
    }
    tokens += 1
    let cu = part.code_units()
    let mut index = 0
    let mut has_equals = false
    while index < cu.length() {
      if @ascii.code_unit_is(cu[index], '=') {
        has_equals = true
        break
      }
      index += 1
    }
    if has_equals {
      pairs += 1
    }
  }
  tokens > 0 && pairs * 2 >= tokens
}

///|
/// Reads text, choosing the reader from `format` or from `detect_format` when
/// the name is `auto`.
pub fn parse_auto(
  text : String,
  format? : String,
  max_records? : Int,
) -> @moonloom.Dataset {
  let limit = max_records.unwrap_or(0)
  let name = match format {
    Some(f) => f
    None => "auto"
  }
  let resolved = if name == "" || name == "auto" {
    detect_format(text)
  } else {
    name
  }
  let dataset = match resolved {
    "csv" => parse_csv(text, max_records=limit)
    "tsv" => parse_tsv(text, max_records=limit)
    "json" => parse_json(text, max_records=limit)
    "jsonl" => parse_jsonl(text, max_records=limit)
    "logfmt" => parse_logfmt(text, max_records=limit)
    "keyvalue" => parse_keyvalue(text, max_records=limit)
    "kv" => parse_keyvalue(text, max_records=limit)
    "access" => parse_access_log(text, max_records=limit)
    "syslog" => parse_syslog(text, max_records=limit)
    "lines" => parse_lines(text, max_records=limit)
    _ => parse_lines(text, max_records=limit)
  }
  dataset
}
