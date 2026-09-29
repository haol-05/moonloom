// Delimited text: CSV, TSV and anything else with a repeated separator.
//
// The reader follows RFC 4180: a quoted field may contain the delimiter, the
// line break and a doubled quote. A file without a header row still produces a
// usable table, with generated `c1`, `c2`, ... column names.

///|
/// Guesses the delimiter of a delimited file by counting candidates outside
/// quotes on the first few lines and preferring the one that splits every line
/// into the same number of fields.
pub fn detect_delimiter(text : String) -> Char {
  let candidates : Array[Char] = [',', '\t', ';', '|']
  let lines = split_lines(text)
  let sample : Array[String] = []
  for line in lines {
    if !is_blank(line) && sample.length() < 10 {
      sample.push(line)
    }
  }
  if sample.length() == 0 {
    return ','
  }
  let mut best = ','
  let mut best_score = -1
  for candidate in candidates {
    let counts : Array[Int] = []
    for line in sample {
      counts.push(count_outside_quotes(line, candidate))
    }
    let first = counts[0]
    if first == 0 {
      continue
    }
    let mut consistent = true
    for count in counts {
      if count != first {
        consistent = false
      }
    }
    let score = if consistent { first * 10 } else { first }
    if score > best_score {
      best_score = score
      best = candidate
    }
  }
  best
}

///|
fn count_outside_quotes(line : String, needle : Char) -> Int {
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
/// Splits delimited text into rows of fields.
fn scan_rows(
  text : String,
  delimiter : Char,
  quote : Char,
  max_rows : Int,
) -> Array[Array[String]] {
  let rows : Array[Array[String]] = []
  let mut row : Array[String] = []
  let field = StringBuilder()
  let mut in_quotes = false
  let mut at_field_start = true
  let mut row_started = false
  let mut pending : Char? = None
  let iter = text.iter()
  let mut finished = false
  while !finished {
    let next = match pending {
      Some(ch) => {
        pending = None
        Some(ch)
      }
      None => iter.next()
    }
    match next {
      None => finished = true
      Some(ch) => {
        if in_quotes {
          if ch == quote {
            match iter.next() {
              Some(after) =>
                if after == quote {
                  field.write_char(quote)
                } else {
                  in_quotes = false
                  pending = Some(after)
                }
              None => in_quotes = false
            }
          } else {
            field.write_char(ch)
          }
        } else if at_field_start && ch == quote {
          in_quotes = true
          at_field_start = false
          row_started = true
        } else if ch == delimiter {
          row.push(field.to_string())
          field.reset()
          at_field_start = true
          row_started = true
        } else if ch == '\n' || ch == '\r' {
          if ch == '\r' {
            match iter.next() {
              Some(after) =>
                if after != '\n' {
                  pending = Some(after)
                }
              None => ()
            }
          }
          row.push(field.to_string())
          field.reset()
          rows.push(row)
          row = []
          at_field_start = true
          row_started = false
          if max_rows > 0 && rows.length() >= max_rows {
            finished = true
          }
        } else {
          field.write_char(ch)
          at_field_start = false
          row_started = true
        }
      }
    }
  }
  if row_started || !field.is_empty() || row.length() > 0 {
    row.push(field.to_string())
    rows.push(row)
  }
  rows
}

///|
/// Reads delimited text into a table.
///
/// `delimiter` defaults to a guess from the content, `header` to `true`, and
/// `max_records` to `0`, which means every row. Rows with more fields than the
/// header produce an `extra-fields` diagnostic; missing fields become null.
pub fn parse_csv(
  text : String,
  delimiter? : Char,
  header? : Bool,
  max_records? : Int,
) -> @moonloom.Dataset {
  let body = strip_bom(text)
  let limit = max_records.unwrap_or(0)
  let with_header = header.unwrap_or(true)
  let delim = match delimiter {
    Some(d) => d
    None => detect_delimiter(body)
  }
  let scan_limit = if with_header && limit > 0 { limit + 1 } else { limit }
  let rows = scan_rows(body, delim, '"', scan_limit)
  let dataset = @moonloom.Dataset::empty("csv")
  if rows.length() == 0 {
    dataset.table.add_diagnostic(
      @moonloom.Diagnostic::new("empty-input", 0, "no rows found"),
    )
    return dataset
  }
  let columns : Array[String] = []
  let mut start = 0
  if with_header {
    for cell in rows[0] {
      let name = cell.trim().to_owned()
      columns.push(if name == "" { "c" + (columns.length() + 1).to_string() } else { name })
    }
    start = 1
  } else {
    let width = widest_row(rows)
    for index = 0; index < width; index = index + 1 {
      columns.push("c" + (index + 1).to_string())
    }
  }
  for row_index = start; row_index < rows.length(); row_index = row_index + 1 {
    let cells = rows[row_index]
    if cells.length() == 1 && cells[0].trim().length() == 0 {
      continue
    }
    let record = @moonloom.Record::empty(row_index + 1, cells.join(delim.to_string()))
    for index = 0; index < cells.length(); index = index + 1 {
      let name = if index < columns.length() {
        columns[index]
      } else {
        "c" + (index + 1).to_string()
      }
      if index >= columns.length() {
        dataset.table.add_diagnostic(
          @moonloom.Diagnostic::new(
            "extra-fields",
            row_index + 1,
            "row has more fields than the header",
          ),
        )
      }
      record.set(name, @moonloom.Value::from_text(cells[index]))
    }
    dataset.add(record)
    dataset.lines_read += 1
  }
  dataset
}

///|
fn widest_row(rows : Array[Array[String]]) -> Int {
  let mut width = 0
  for row in rows {
    if row.length() > width {
      width = row.length()
    }
  }
  width
}

///|
/// Tab separated text is the same reader with a fixed delimiter.
pub fn parse_tsv(text : String, header? : Bool, max_records? : Int) -> @moonloom.Dataset {
  parse_csv(text, delimiter='\t', header?=header, max_records?=max_records)
}
