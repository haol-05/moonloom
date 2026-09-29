// Result rendering: an aligned table, and machine readable exports.

///|
/// True for the code points that occupy two terminal columns.
fn is_wide(codepoint : Int) -> Bool {
  (codepoint >= 0x1100 && codepoint <= 0x115F) ||
  (codepoint >= 0x2E80 && codepoint <= 0x303E) ||
  (codepoint >= 0x3041 && codepoint <= 0x33FF) ||
  (codepoint >= 0x3400 && codepoint <= 0x4DBF) ||
  (codepoint >= 0x4E00 && codepoint <= 0x9FFF) ||
  (codepoint >= 0xA000 && codepoint <= 0xA4CF) ||
  (codepoint >= 0xAC00 && codepoint <= 0xD7A3) ||
  (codepoint >= 0xF900 && codepoint <= 0xFAFF) ||
  (codepoint >= 0xFE30 && codepoint <= 0xFE6F) ||
  (codepoint >= 0xFF00 && codepoint <= 0xFF60) ||
  (codepoint >= 0xFFE0 && codepoint <= 0xFFE6) ||
  (codepoint >= 0x1F300 && codepoint <= 0x1FAFF) ||
  (codepoint >= 0x20000 && codepoint <= 0x3FFFD)
}

///|
/// Terminal columns one character occupies: zero for a control or combining
/// mark, two for a wide character, one otherwise.
pub fn char_width(character : Char) -> Int {
  let codepoint = character.to_int()
  if codepoint < 32 {
    return 0
  }
  if codepoint >= 0x0300 && codepoint <= 0x036F {
    return 0
  }
  if codepoint == 0x200B || codepoint == 0xFEFF {
    return 0
  }
  if is_wide(codepoint) {
    2
  } else {
    1
  }
}

///|
/// Display width of a string, in terminal columns.
pub fn display_width(text : String) -> Int {
  let mut width = 0
  for character in text {
    width += char_width(character)
  }
  width
}

///|
/// Cuts a string to a display width, marking the cut with an ellipsis.
pub fn truncate_width(text : String, limit : Int) -> String {
  if display_width(text) <= limit {
    return text
  }
  let out = StringBuilder()
  let mut width = 0
  let mut used = 0
  for character in text {
    let size = char_width(character)
    if width + size > limit - 1 {
      break
    }
    out.write_char(character)
    width += size
    used += 1
  }
  let _ = used
  out.write_string("\u{2026}")
  out.to_string()
}

///|
fn pad_right(text : String, width : Int) -> String {
  let out = StringBuilder()
  out.write_string(text)
  let mut missing = width - display_width(text)
  while missing > 0 {
    out.write_string(" ")
    missing -= 1
  }
  out.to_string()
}

///|
/// The options a table renderer honours.
pub(all) struct TableOptions {
  max_cell_width : Int
  row_numbers : Bool
  float_digits : Int
} derive(Eq, Debug)

///|
pub extend TableOptions with Eq::{not_equal, equal}

///|
pub extend TableOptions with @debug.Debug::{to_repr}

///|
pub fn TableOptions::new(
  max_cell_width? : Int,
  row_numbers? : Bool,
  float_digits? : Int,
) -> TableOptions {
  {
    max_cell_width: max_cell_width.unwrap_or(40),
    row_numbers: row_numbers.unwrap_or(false),
    float_digits: float_digits.unwrap_or(6),
  }
}

///|
/// Rounds a fractional value for display. The table is meant to be read, and a
/// mean of `76.66666666666667` costs more width than it is worth; the JSON and
/// CSV exports keep the value as it is.
fn round_for_display(value : Double, digits : Int) -> Double {
  if value.is_nan() || value.is_inf() || digits <= 0 {
    return value
  }
  let scale = @math.pow(10.0, digits.to_double())
  @math.round(value * scale) / scale
}

///|
fn cell_text(value : @moonloom.Value, options : TableOptions) -> String {
  let text = match value {
    @moonloom.Num(number) =>
      @moonloom.format_double(round_for_display(number, options.float_digits))
    _ => value.display()
  }
  truncate_width(text, options.max_cell_width)
}

///|
/// Renders a result as an aligned ASCII table.
///
/// An empty result still prints its header, so a query that matched nothing is
/// distinguishable from a query that failed.
pub fn render_table(
  result : @exec.ResultSet,
  options? : TableOptions,
) -> String {
  let settings = match options {
    Some(given) => given
    None => TableOptions::new()
  }
  let headers : Array[String] = []
  if settings.row_numbers {
    headers.push("#")
  }
  for column in result.columns {
    headers.push(column)
  }
  let widths : Array[Int] = headers.map(fn(header) { display_width(header) })
  let body : Array[Array[String]] = []
  let mut number = 0
  for row in result.rows {
    let cells : Array[String] = []
    if settings.row_numbers {
      cells.push((number + 1).to_string())
    }
    for value in row {
      cells.push(cell_text(value, settings))
    }
    let mut index = 0
    for cell in cells {
      if index < widths.length() {
        let width = display_width(cell)
        if width > widths[index] {
          widths[index] = width
        }
      }
      index += 1
    }
    body.push(cells)
    number += 1
  }
  let out = StringBuilder()
  write_rule(out, widths)
  write_row(out, headers, widths)
  write_rule(out, widths)
  for cells in body {
    write_row(out, cells, widths)
  }
  write_rule(out, widths)
  out.to_string()
}

///|
fn write_rule(out : StringBuilder, widths : Array[Int]) -> Unit {
  out.write_string("+")
  for width in widths {
    let mut count = width + 2
    while count > 0 {
      out.write_string("-")
      count -= 1
    }
    out.write_string("+")
  }
  out.write_string("\n")
}

///|
fn write_row(
  out : StringBuilder,
  cells : Array[String],
  widths : Array[Int],
) -> Unit {
  out.write_string("|")
  let mut index = 0
  for width in widths {
    let text = if index < cells.length() { cells[index] } else { "" }
    out.write_string(" " + pad_right(text, width) + " |")
    index += 1
  }
  out.write_string("\n")
}

///|
/// One JSON value, typed as the result carries it.
fn json_value(value : @moonloom.Value) -> String {
  value.json_text()
}

///|
/// Renders a result as a JSON array of objects.
pub fn render_json(result : @exec.ResultSet) -> String {
  let out = StringBuilder()
  out.write_string("[\n")
  let mut row_index = 0
  for row in result.rows {
    out.write_string("  {")
    let mut column_index = 0
    for column in result.columns {
      if column_index > 0 {
        out.write_string(",")
      }
      let value = if column_index < row.length() {
        row[column_index]
      } else {
        @moonloom.Null
      }
      out.write_string(
        "\"" + @moonloom.escape_json(column) + "\":" + json_value(value),
      )
      column_index += 1
    }
    out.write_string("}")
    if row_index + 1 < result.rows.length() {
      out.write_string(",")
    }
    out.write_string("\n")
    row_index += 1
  }
  out.write_string("]\n")
  out.to_string()
}

///|
/// Renders a result as one JSON object per line, which is the shape a reader
/// can stream back in.
pub fn render_jsonl(result : @exec.ResultSet) -> String {
  let out = StringBuilder()
  for row in result.rows {
    out.write_string("{")
    let mut index = 0
    for column in result.columns {
      if index > 0 {
        out.write_string(",")
      }
      let value = if index < row.length() { row[index] } else { @moonloom.Null }
      out.write_string(
        "\"" + @moonloom.escape_json(column) + "\":" + json_value(value),
      )
      index += 1
    }
    out.write_string("}\n")
  }
  out.to_string()
}

///|
fn csv_cell(text : String, delimiter : Char) -> String {
  let needs_quotes = text.contains(delimiter.to_string()) ||
    text.contains("\"") ||
    text.contains("\n") ||
    text.contains("\r")
  if needs_quotes {
    "\"" + text.replace_all(old="\"", new="\"\"") + "\""
  } else {
    text
  }
}

///|
/// Renders a result as delimited text, quoting what has to be quoted so the
/// output reads back through `parse_csv`.
pub fn render_csv(result : @exec.ResultSet, delimiter? : Char) -> String {
  let separator = delimiter.unwrap_or(',')
  let out = StringBuilder()
  let mut first = true
  for column in result.columns {
    if !first {
      out.write_char(separator)
    }
    out.write_string(csv_cell(column, separator))
    first = false
  }
  out.write_string("\n")
  for row in result.rows {
    let mut index = 0
    for value in row {
      if index > 0 {
        out.write_char(separator)
      }
      out.write_string(csv_cell(value.display(), separator))
      index += 1
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
/// Renders a result as a Markdown table.
pub fn render_markdown(result : @exec.ResultSet) -> String {
  let out = StringBuilder()
  out.write_string("|")
  for column in result.columns {
    out.write_string(" " + escape_markdown(column) + " |")
  }
  out.write_string("\n|")
  for _ in result.columns {
    out.write_string(" --- |")
  }
  out.write_string("\n")
  for row in result.rows {
    out.write_string("|")
    let mut index = 0
    for _ in result.columns {
      let value = if index < row.length() { row[index] } else { @moonloom.Null }
      out.write_string(" " + escape_markdown(value.display()) + " |")
      index += 1
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn escape_markdown(text : String) -> String {
  text.replace_all(old="|", new="\\|").replace_all(old="\n", new=" ")
}

///|
/// The names a caller can pass as an output format.
pub fn known_formats() -> Array[String] {
  ["table", "json", "jsonl", "csv", "markdown", "md"]
}

///|
/// Renders a result in a named format. An unknown name falls back to the table,
/// because showing the rows is always better than showing nothing.
pub fn render(result : @exec.ResultSet, format : String) -> String {
  match format {
    "json" => render_json(result)
    "jsonl" | "ndjson" => render_jsonl(result)
    "csv" => render_csv(result)
    "markdown" | "md" => render_markdown(result)
    _ => render_table(result)
  }
}

///|
/// A one line summary of what a query cost.
pub fn render_stats(stats : @exec.ExecStats) -> String {
  let out = StringBuilder()
  out.write_string("rows in " + stats.rows_in.to_string())
  if stats.index_used {
    out.write_string(", index pruned " + stats.pruned.to_string())
  }
  out.write_string(", scanned " + stats.scanned.to_string())
  out.write_string(", filtered " + stats.filtered_out.to_string())
  if stats.groups > 0 {
    out.write_string(", groups " + stats.groups.to_string())
  }
  out.write_string(", out " + stats.rows_out.to_string())
  out.to_string()
}

///|
/// Renders inferred field information as a table sized to its content.
pub fn render_schema(fields : Array[@moonloom.FieldInfo]) -> String {
  let out = StringBuilder()
  let headers : Array[String] = [
    "name", "kind", "present", "missing", "distinct",
  ]
  let widths : Array[Int] = headers.map(fn(header) { display_width(header) })
  let rows : Array[Array[String]] = []
  for field in fields {
    let cells : Array[String] = [
      field.name,
      field.kind.label(),
      field.present.to_string(),
      field.missing.to_string(),
      field.distinct.to_string(),
    ]
    let mut index = 0
    for cell in cells {
      let width = display_width(cell)
      if width > widths[index] {
        widths[index] = width
      }
      index += 1
    }
    rows.push(cells)
  }
  write_rule(out, widths)
  write_row(out, headers, widths)
  write_rule(out, widths)
  for cells in rows {
    write_row(out, cells, widths)
  }
  write_rule(out, widths)
  out.to_string()
}
