// ASCII level helpers.
//
// MoonBit strings are sequences of UTF-16 code units, so a scanner that only
// walks structure (`{`, `,`, `"`, digits) can index them directly. These
// predicates work on one code unit and never allocate, which is what the
// parsers and the query lexer build on.

///|
/// True when a code unit is exactly the given ASCII character.
pub fn code_unit_is(cu : UInt16, ch : Char) -> Bool {
  cu.to_int() == ch.to_int()
}

///|
pub fn ascii_is_digit(cu : UInt16) -> Bool {
  let v = cu.to_int()
  v >= 48 && v <= 57
}

///|
pub fn ascii_is_lower(cu : UInt16) -> Bool {
  let v = cu.to_int()
  v >= 97 && v <= 122
}

///|
pub fn ascii_is_upper(cu : UInt16) -> Bool {
  let v = cu.to_int()
  v >= 65 && v <= 90
}

///|
pub fn ascii_is_alpha(cu : UInt16) -> Bool {
  ascii_is_lower(cu) || ascii_is_upper(cu)
}

///|
pub fn ascii_is_alnum(cu : UInt16) -> Bool {
  ascii_is_alpha(cu) || ascii_is_digit(cu)
}

///|
/// Whitespace as a text format understands it: space, tab, carriage return and
/// line feed. Vertical tab and form feed are deliberately excluded.
pub fn ascii_is_space(cu : UInt16) -> Bool {
  code_unit_is(cu, ' ') || code_unit_is(cu, '\t') || code_unit_is(cu, '\r') || code_unit_is(cu, '\n')
}

///|
pub fn ascii_is_sign(cu : UInt16) -> Bool {
  code_unit_is(cu, '-') || code_unit_is(cu, '+')
}

///|
/// Lower-cases one ASCII code unit; every other code unit is returned as is.
pub fn ascii_lower(cu : UInt16) -> UInt16 {
  if ascii_is_upper(cu) {
    (cu.to_int() + 32).to_uint16()
  } else {
    cu
  }
}

///|
/// Lower-cases one ASCII character; every other character is returned as is.
pub fn ascii_lower_char(c : Char) -> Char {
  let v = c.to_int()
  if v >= 65 && v <= 90 {
    match (v + 32).to_char() {
      Some(lower) => lower
      None => c
    }
  } else {
    c
  }
}

///|
/// Lower-cases the ASCII letters of a string and leaves every other code unit
/// untouched, so code unit offsets stay valid.
pub fn ascii_lower_string(s : StringView) -> String {
  let out = StringBuilder()
  for c in s {
    out.write_char(ascii_lower_char(c))
  }
  out.to_string()
}

///|
/// Case-insensitive ASCII comparison, used by keywords and by the folded
/// equality mode of the query evaluator.
pub fn ascii_eq_ignore_case(a : StringView, b : StringView) -> Bool {
  let left = a.code_units()
  let right = b.code_units()
  if left.length() != right.length() {
    return false
  }
  let mut index = 0
  while index < left.length() {
    if ascii_lower(left[index]) != ascii_lower(right[index]) {
      return false
    }
    index += 1
  }
  true
}
