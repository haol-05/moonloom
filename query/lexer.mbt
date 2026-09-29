// Tokenizer for the query language.

///|
/// What a token is, coarse enough that the parser can switch on it cheaply.
pub(all) enum TokenKind {
  TkIdent
  TkNumber
  TkText
  TkSymbol
  TkEnd
} derive(Eq, Debug)

///|
pub extend TokenKind with Eq::{not_equal, equal}

///|
pub extend TokenKind with @debug.Debug::{to_repr}

///|
/// One token together with where it started, so an error can point at it.
pub(all) struct Token {
  kind : TokenKind
  text : String
  line : Int
  column : Int
} derive(Eq, Debug)

///|
pub extend Token with Eq::{not_equal, equal}

///|
pub extend Token with @debug.Debug::{to_repr}

///|
/// A mistake in a query. The message always carries a position.
pub suberror QueryError {
  QueryError(String)
}

///|
fn is_ident_start(c : UInt16) -> Bool {
  @ascii.ascii_is_alpha(c) || @ascii.code_unit_is(c, '_')
}

///|
/// Identifiers may carry dots, which is how a nested field such as
/// `http.status` or `tags.0` is named.
fn is_ident_body(c : UInt16) -> Bool {
  @ascii.ascii_is_alnum(c) || @ascii.code_unit_is(c, '_') || @ascii.code_unit_is(c, '.')
}

///|
/// Splits a query into tokens. Raises on an unterminated string or a character
/// that cannot start a token.
pub fn tokenize(text : String) -> Array[Token] raise QueryError {
  let tokens : Array[Token] = []
  let cu = text.code_units()
  let n = cu.length()
  let mut index = 0
  let mut line = 1
  let mut line_start = 0
  while index < n {
    let c = cu[index]
    if @ascii.code_unit_is(c, '\n') {
      line += 1
      index += 1
      line_start = index
      continue
    }
    if @ascii.code_unit_is(c, ' ') || @ascii.code_unit_is(c, '\t') || @ascii.code_unit_is(c, '\r') {
      index += 1
      continue
    }
    if @ascii.code_unit_is(c, '/') && index + 1 < n && @ascii.code_unit_is(cu[index + 1], '/') {
      while index < n && !@ascii.code_unit_is(cu[index], '\n') {
        index += 1
      }
      continue
    }
    let column = index - line_start
    if is_ident_start(c) {
      let start = index
      while index < n && is_ident_body(cu[index]) {
        index += 1
      }
      tokens.push({ kind: TkIdent, text: text[start:index].to_owned(), line, column })
      continue
    }
    if @ascii.ascii_is_digit(c) {
      let start = index
      while index < n && @ascii.ascii_is_digit(cu[index]) {
        index += 1
      }
      if index < n && @ascii.code_unit_is(cu[index], '.') {
        index += 1
        while index < n && @ascii.ascii_is_digit(cu[index]) {
          index += 1
        }
      }
      if index < n &&
        (@ascii.code_unit_is(cu[index], 'e') || @ascii.code_unit_is(cu[index], 'E')) {
        let mark = index
        index += 1
        if index < n && @ascii.ascii_is_sign(cu[index]) {
          index += 1
        }
        if index < n && @ascii.ascii_is_digit(cu[index]) {
          while index < n && @ascii.ascii_is_digit(cu[index]) {
            index += 1
          }
        } else {
          index = mark
        }
      }
      tokens.push({ kind: TkNumber, text: text[start:index].to_owned(), line, column })
      continue
    }
    if @ascii.code_unit_is(c, '"') || @ascii.code_unit_is(c, '\'') {
      let quote = c
      let out = StringBuilder()
      let mut scan = index + 1
      let mut closed = false
      while scan < n {
        let inner = cu[scan]
        if @ascii.code_unit_is(inner, '\\') && scan + 1 < n {
          let escaped = cu[scan + 1]
          if @ascii.code_unit_is(escaped, 'n') {
            out.write_char('\n')
          } else if @ascii.code_unit_is(escaped, 't') {
            out.write_char('\t')
          } else if @ascii.code_unit_is(escaped, 'r') {
            out.write_char('\r')
          } else {
            match escaped.to_int().to_char() {
              Some(ch) => out.write_char(ch)
              None => ()
            }
          }
          scan += 2
          continue
        }
        if inner == quote {
          closed = true
          scan += 1
          break
        }
        match inner.to_int().to_char() {
          Some(ch) => out.write_char(ch)
          None => ()
        }
        scan += 1
      }
      if !closed {
        raise QueryError(
          "line " + line.to_string() + ", column " + column.to_string() + ": unterminated text",
        )
      }
      tokens.push({ kind: TkText, text: out.to_string(), line, column })
      index = scan
      continue
    }
    let pair = if index + 1 < n { text[index:index + 2].to_owned() } else { "" }
    if is_two_char_symbol(pair) {
      tokens.push({ kind: TkSymbol, text: pair, line, column })
      index += 2
      continue
    }
    match c.to_int().to_char() {
      Some(ch) =>
        if is_one_char_symbol(ch) {
          tokens.push({ kind: TkSymbol, text: text[index:index + 1].to_owned(), line, column })
          index += 1
          continue
        }
      None => ()
    }
    raise QueryError(
      "line " + line.to_string() + ", column " + column.to_string() + ": unexpected character",
    )
  }
  tokens.push({ kind: TkEnd, text: "", line, column: index - line_start })
  tokens
}

///|
fn is_two_char_symbol(pair : String) -> Bool {
  match pair {
    "==" | "!=" | "<=" | ">=" | "&&" | "||" | "=~" | "!~" | "<>" => true
    _ => false
  }
}

///|
fn is_one_char_symbol(c : Char) -> Bool {
  match c {
    '|' | ',' | '(' | ')' | '[' | ']' | '=' | '<' | '>' | '!' | '+' | '-' | '*' | '/' | '%' =>
      true
    _ => false
  }
}
