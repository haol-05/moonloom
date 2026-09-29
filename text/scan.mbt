// Small scanning helpers shared by the record parsers.
//
// They all work on the code units of one line and return the index just past
// what they consumed, so a parser can walk a line without allocating.

///|
/// Index of the first code unit that is not a space or tab.
pub fn skip_spaces(cu : ArrayView[UInt16], start : Int) -> Int {
  let mut index = start
  while index < cu.length() {
    let c = cu[index]
    if !@ascii.code_unit_is(c, ' ') && !@ascii.code_unit_is(c, '\t') {
      return index
    }
    index += 1
  }
  index
}

///|
/// Index just past the next delimiter, skipping the delimiter itself.
/// The delimiter is not consumed, so the caller decides what to skip.
pub fn until_char(cu : ArrayView[UInt16], start : Int, delimiter : Char) -> Int {
  let mut index = start
  while index < cu.length() && !@ascii.code_unit_is(cu[index], delimiter) {
    index += 1
  }
  index
}

///|
/// Reads a double-quoted run and returns the content between the quotes
/// together with the index just past the closing quote. A backslash escapes the
/// next character.
pub fn read_quoted(cu : ArrayView[UInt16], start : Int) -> (String, Int)? {
  if start >= cu.length() || !@ascii.code_unit_is(cu[start], '"') {
    return None
  }
  let out = StringBuilder()
  let mut index = start + 1
  while index < cu.length() {
    let c = cu[index]
    if @ascii.code_unit_is(c, '\\') && index + 1 < cu.length() {
      let next = cu[index + 1].to_int()
      match next.to_char() {
        Some(ch) => out.write_char(ch)
        None => ()
      }
      index += 2
      continue
    }
    if @ascii.code_unit_is(c, '"') {
      return Some((out.to_string(), index + 1))
    }
    match c.to_int().to_char() {
      Some(ch) => out.write_char(ch)
      None => ()
    }
    index += 1
  }
  None
}

///|
/// Reads a bracketed run and returns the content between the brackets together
/// with the index just past the closing bracket.
pub fn read_bracketed(
  line : String,
  cu : ArrayView[UInt16],
  start : Int,
) -> (String, Int)? {
  if start >= cu.length() || !@ascii.code_unit_is(cu[start], '[') {
    return None
  }
  let mut index = start + 1
  while index < cu.length() {
    if @ascii.code_unit_is(cu[index], ']') {
      return Some((line[start + 1:index].to_owned(), index + 1))
    }
    index += 1
  }
  None
}
