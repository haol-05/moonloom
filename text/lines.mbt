// Line handling shared by every text parser.

///|
/// Splits text into lines and accepts LF, CRLF and CR input.
///
/// A trailing newline does not produce a final empty line, so a file with five
/// records and a closing newline yields five lines rather than six.
pub fn split_lines(text : String) -> Array[String] {
  let cu = text.code_units()
  let n = cu.length()
  let out : Array[String] = []
  let mut start = 0
  let mut index = 0
  while index < n {
    let c = cu[index]
    if @ascii.code_unit_is(c, '\n') {
      let mut end = index
      if end > start && @ascii.code_unit_is(cu[end - 1], '\r') {
        end -= 1
      }
      out.push(text[start:end].to_owned())
      start = index + 1
    } else if @ascii.code_unit_is(c, '\r') {
      let next_is_lf = index + 1 < n && @ascii.code_unit_is(cu[index + 1], '\n')
      if !next_is_lf {
        out.push(text[start:index].to_owned())
        start = index + 1
      }
    }
    index += 1
  }
  if start < n {
    out.push(text[start:n].to_owned())
  }
  out
}

///|
/// A line that is empty or only whitespace carries no record.
pub fn is_blank(line : String) -> Bool {
  let cu = line.code_units()
  let mut index = 0
  while index < cu.length() {
    if !@ascii.ascii_is_space(cu[index]) {
      return false
    }
    index += 1
  }
  true
}

///|
/// Drops a byte order mark and surrounding whitespace, which is what the first
/// line of a file exported from a spreadsheet usually needs.
pub fn strip_bom(text : String) -> String {
  if text.has_prefix("\u{FEFF}") {
    text[1:].to_owned()
  } else {
    text
  }
}

///|
/// Splits a line on one separator without any quoting rules.
pub fn split_plain(line : String, separator : Char) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let cu = line.code_units()
  let mut index = 0
  while index < cu.length() {
    if @ascii.code_unit_is(cu[index], separator) {
      out.push(line[start:index].to_owned())
      start = index + 1
    }
    index += 1
  }
  out.push(line[start:].to_owned())
  out
}
