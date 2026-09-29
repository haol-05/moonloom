// JSON records: one object per line (`jsonl`) or one array per document.
//
// Nested objects become dotted field names (`http.status`), and array elements
// become indexed names (`tags.0`), which keeps every value reachable from the
// query language without a separate path syntax.

///|
fn join_name(prefix : String, key : String) -> String {
  if prefix == "" {
    key
  } else {
    prefix + "." + key
  }
}

///|
fn number_value(d : Double) -> @moonloom.Value {
  if d.is_nan() || d.is_inf() {
    return @moonloom.Str(@moonloom.format_double(d))
  }
  let rounded = d.to_int64()
  if rounded.to_double() == d && d.abs() < 1.0e15 {
    @moonloom.Int(rounded)
  } else {
    @moonloom.Num(d)
  }
}

///|
fn json_into_record(
  value : Json,
  prefix : String,
  record : @moonloom.Record,
  flatten : Bool,
) -> Unit {
  if value is Object(map) {
    if !flatten && prefix != "" {
      record.set(prefix, @moonloom.Str(value.stringify()))
      return
    }
    for key, sub in map {
      json_into_record(sub, join_name(prefix, key), record, flatten)
    }
  } else if value is Array(items) {
    if !flatten && prefix != "" {
      record.set(prefix, @moonloom.Str(value.stringify()))
      return
    }
    let mut index = 0
    for item in items {
      json_into_record(
        item,
        join_name(prefix, index.to_string()),
        record,
        flatten,
      )
      index += 1
    }
  } else if value is String(s) {
    record.set(prefix, @moonloom.Str(s))
  } else if value is Number(d, ..) {
    record.set(prefix, number_value(d))
  } else if value is True {
    record.set(prefix, @moonloom.Bool(true))
  } else if value is False {
    record.set(prefix, @moonloom.Bool(false))
  } else {
    record.set(prefix, @moonloom.Null)
  }
}

///|
fn parse_json_value(text : String) -> Json? {
  Some(@json.parse(text)) catch {
    @json.InvalidChar(_, _) => None
    @json.InvalidEof => None
    @json.InvalidNumber(_, _) => None
    @json.InvalidIdentEscape(_) => None
    @json.DepthLimitExceeded => None
  }
}

///|
/// Reads JSON Lines: one complete JSON value per line, usually an object.
///
/// A line that is not valid JSON becomes an `invalid-json` diagnostic and the
/// reader moves on, so a truncated last line never loses the records before it.
pub fn parse_jsonl(
  text : String,
  flatten? : Bool,
  max_records? : Int,
) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("jsonl")
  let limit = max_records.unwrap_or(0)
  let flat = flatten.unwrap_or(true)
  let mut line_number = 0
  for line in split_lines(strip_bom(text)) {
    line_number += 1
    if is_blank(line) {
      continue
    }
    if limit > 0 && dataset.rows() >= limit {
      break
    }
    match parse_json_value(line) {
      Some(parsed) => {
        let record = @moonloom.Record::empty(line_number, line)
        json_into_record(parsed, "", record, flat)
        if record.size() == 0 {
          dataset.skip(
            @moonloom.Diagnostic::new(
              "not-an-object", line_number, "line holds no fields",
            ),
          )
        } else {
          dataset.add(record)
          dataset.lines_read += 1
        }
      }
      None =>
        dataset.skip(
          @moonloom.Diagnostic::new(
            "invalid-json", line_number, "line is not valid JSON",
          ),
        )
    }
  }
  dataset
}

///|
/// Reads one JSON document: an array of objects becomes one record per element,
/// and a single object becomes one record.
pub fn parse_json(
  text : String,
  flatten? : Bool,
  max_records? : Int,
) -> @moonloom.Dataset {
  let flat = flatten.unwrap_or(true)
  let limit = max_records.unwrap_or(0)
  let dataset = @moonloom.Dataset::empty("json")
  match parse_json_value(strip_bom(text)) {
    None =>
      dataset.skip(
        @moonloom.Diagnostic::new(
          "invalid-json", 1, "document is not valid JSON",
        ),
      )
    Some(parsed) =>
      if parsed is Array(items) {
        let mut index = 0
        for item in items {
          if limit > 0 && dataset.rows() >= limit {
            break
          }
          index += 1
          let record = @moonloom.Record::empty(index, "")
          json_into_record(item, "", record, flat)
          if record.size() == 0 {
            dataset.skip(
              @moonloom.Diagnostic::new(
                "not-an-object", index, "array element holds no fields",
              ),
            )
          } else {
            dataset.add(record)
            dataset.lines_read += 1
          }
        }
      } else {
        let record = @moonloom.Record::empty(1, "")
        json_into_record(parsed, "", record, flat)
        dataset.add(record)
        dataset.lines_read += 1
      }
  }
  dataset
}
