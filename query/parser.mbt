// Recursive descent parser for the query language.
//
// The parser only builds a tree. It never looks at data, which is what lets the
// same query text be checked, explained and executed separately.

///|
priv struct Parser {
  tokens : Array[Token]
  mut pos : Int
}

///|
fn Parser::peek(self : Parser) -> Token {
  self.tokens[self.pos]
}

///|
fn Parser::at_end(self : Parser) -> Bool {
  self.tokens[self.pos].kind == TkEnd
}

///|
fn Parser::advance(self : Parser) -> Unit {
  if !self.at_end() {
    self.pos += 1
  }
}

///|
fn Parser::position(self : Parser) -> String {
  let token = self.peek()
  "line " + token.line.to_string() + ", column " + token.column.to_string()
}

///|
fn Parser::peek_is_symbol(self : Parser, symbol : String) -> Bool {
  let token = self.peek()
  token.kind == TkSymbol && token.text == symbol
}

///|
fn Parser::peek_keyword(self : Parser, word : String) -> Bool {
  let token = self.peek()
  token.kind == TkIdent && @ascii.ascii_eq_ignore_case(token.text, word)
}

///|
fn Parser::expect_symbol(self : Parser, symbol : String) -> Unit raise QueryError {
  if self.peek_is_symbol(symbol) {
    self.advance()
  } else {
    raise QueryError(self.position() + ": expected '" + symbol + "'")
  }
}

///|
fn Parser::next_ident(self : Parser, what : String) -> String raise QueryError {
  let token = self.peek()
  if token.kind == TkIdent || token.kind == TkText {
    self.advance()
    token.text
  } else {
    raise QueryError(self.position() + ": expected " + what)
  }
}

///|
fn Parser::next_int(self : Parser, what : String) -> Int raise QueryError {
  let token = self.peek()
  if token.kind != TkNumber {
    raise QueryError(self.position() + ": expected " + what)
  }
  self.advance()
  match @moonloom.parse_int_opt(token.text) {
    Some(value) => value
    None => raise QueryError(self.position() + ": expected " + what + ", found " + token.text)
  }
}

///|
/// Parses a query.
pub fn parse_query(text : String) -> Query raise QueryError {
  let tokens = tokenize(text)
  let parser : Parser = { tokens, pos: 0 }
  let mut source : String? = None
  if parser.peek_keyword("from") {
    parser.advance()
    let token = parser.peek()
    if token.kind == TkIdent || token.kind == TkText {
      source = Some(token.text)
      parser.advance()
    } else {
      raise QueryError(parser.position() + ": expected a source name after 'from'")
    }
  }
  let stages : Array[Stage] = []
  let mut expect_pipe = source is Some(_)
  while !parser.at_end() {
    if parser.peek_is_symbol("|") {
      parser.advance()
    } else if expect_pipe {
      raise QueryError(parser.position() + ": expected '|' before the next stage")
    }
    expect_pipe = true
    stages.push(parse_stage(parser))
  }
  Query::new(source, stages, text)
}

///|
/// Parses a query and reports a mistake as a message instead of raising, which
/// is what a command line or a UI wants.
pub fn Query::parse(text : String) -> Result[Query, String] {
  try {
    Ok(parse_query(text))
  } catch {
    QueryError(message) => Err(message)
  }
}

///|
fn parse_stage(parser : Parser) -> Stage raise QueryError {
  let keyword = parser.next_ident("a stage keyword such as where or stats")
  let lower = keyword.to_lower()
  match lower {
    "where" | "filter" => Where(parse_expr(parser))
    "fields" | "select" => Fields(parse_path_list(parser))
    "eval" => {
      let name = parser.next_ident("a new field name")
      parser.expect_symbol("=")
      Eval(name, parse_expr(parser))
    }
    "parse" => {
      let pattern = parser.next_ident("a pattern in braces")
      Parse(pattern)
    }
    "stats" => parse_stats(parser)
    "sort" | "order" => Sort(parse_sort_keys(parser))
    "limit" | "head" => Limit(parser.next_int("a row count"))
    "top" => parse_top(parser)
    "dedup" | "distinct" => Dedup(parse_path_list(parser))
    _ => raise QueryError(parser.position() + ": unknown stage '" + keyword + "'")
  }
}

///|
fn parse_top(parser : Parser) -> Stage raise QueryError {
  let count = parser.next_int("a row count")
  if !parser.peek_keyword("by") {
    raise QueryError(parser.position() + ": 'top' needs 'by' followed by an ordering")
  }
  parser.advance()
  Top(count, parse_sort_keys(parser))
}

///|
fn parse_stats(parser : Parser) -> Stage raise QueryError {
  let specs : Array[AggSpec] = []
  specs.push(parse_agg_spec(parser))
  while parser.peek_is_symbol(",") {
    parser.advance()
    specs.push(parse_agg_spec(parser))
  }
  let groups : Array[String] = []
  if parser.peek_keyword("by") {
    parser.advance()
    groups.push(parser.next_ident("a field name"))
    while parser.peek_is_symbol(",") {
      parser.advance()
      groups.push(parser.next_ident("a field name"))
    }
  }
  Stats(specs, groups)
}

///|
fn parse_agg_spec(parser : Parser) -> AggSpec raise QueryError {
  let name = parser.next_ident("an aggregate such as count or sum")
  let lower = name.to_lower()
  let func = match AggFunc::from_name(lower) {
    Some(f) => f
    None => raise QueryError(parser.position() + ": unknown aggregate '" + name + "'")
  }
  let mut arg : Expr? = None
  let mut extra : Expr? = None
  if parser.peek_is_symbol("(") {
    parser.advance()
    if !parser.peek_is_symbol(")") {
      arg = Some(parse_expr(parser))
      if parser.peek_is_symbol(",") {
        parser.advance()
        extra = Some(parse_expr(parser))
      }
    }
    parser.expect_symbol(")")
  }
  if func == Percentile && extra is None {
    raise QueryError(parser.position() + ": percentile needs a value and a rank, as percentile(x, 95)")
  }
  let mut label = default_alias(func, arg, extra)
  if parser.peek_keyword("as") {
    parser.advance()
    label = parser.next_ident("an alias")
  }
  { func, arg, extra, label }
}

///|
fn last_segment(path : String) -> String {
  match path.rev_find(".") {
    Some(at) => path[at + 1:].to_owned()
    None => path
  }
}

///|
fn expr_label(expr : Expr?) -> String {
  match expr {
    Some(Field(name)) => last_segment(name)
    Some(LitStr(text)) => text
    Some(_) => "value"
    None => "value"
  }
}

///|
fn expr_number_label(expr : Expr?) -> String {
  match expr {
    Some(LitInt(value)) => value.to_string()
    Some(LitNum(value)) => @moonloom.format_double(value)
    _ => ""
  }
}

///|
/// The name a `stats` output column gets when the query does not supply one.
pub fn default_alias(func : AggFunc, arg : Expr?, extra : Expr?) -> String {
  if func == Count {
    return "count"
  }
  if func == Percentile {
    return "p" + expr_number_label(extra) + "_" + expr_label(arg)
  }
  func.name() + "_" + expr_label(arg)
}

///|
fn parse_path_list(parser : Parser) -> Array[String] raise QueryError {
  let names : Array[String] = []
  names.push(parser.next_ident("a field name"))
  while parser.peek_is_symbol(",") {
    parser.advance()
    names.push(parser.next_ident("a field name"))
  }
  names
}

///|
fn parse_sort_keys(parser : Parser) -> Array[SortKey] raise QueryError {
  let keys : Array[SortKey] = []
  let mut more = true
  while more {
    let expr = parse_expr(parser)
    let mut desc = false
    if parser.peek_keyword("desc") || parser.peek_keyword("descending") {
      parser.advance()
      desc = true
    } else if parser.peek_keyword("asc") || parser.peek_keyword("ascending") {
      parser.advance()
    }
    keys.push({ expr, desc })
    if parser.peek_is_symbol(",") {
      parser.advance()
    } else {
      more = false
    }
  }
  keys
}

///|
fn parse_expr(parser : Parser) -> Expr raise QueryError {
  parse_or(parser)
}

///|
fn parse_or(parser : Parser) -> Expr raise QueryError {
  let mut left = parse_and(parser)
  while parser.peek_keyword("or") || parser.peek_is_symbol("||") {
    parser.advance()
    left = Binary(Or, left, parse_and(parser))
  }
  left
}

///|
fn parse_and(parser : Parser) -> Expr raise QueryError {
  let mut left = parse_comparison(parser)
  while parser.peek_keyword("and") || parser.peek_is_symbol("&&") {
    parser.advance()
    left = Binary(And, left, parse_comparison(parser))
  }
  left
}

///|
fn comparison_op(parser : Parser) -> BinOp? {
  let token = parser.peek()
  if token.kind == TkSymbol {
    let op = match token.text {
      "==" | "=" => Some(Eq)
      "!=" | "<>" => Some(Ne)
      "<" => Some(Lt)
      "<=" => Some(Le)
      ">" => Some(Gt)
      ">=" => Some(Ge)
      "=~" => Some(Match)
      "!~" => Some(NotMatch)
      _ => None
    }
    match op {
      Some(found) => {
        parser.advance()
        Some(found)
      }
      None => None
    }
  } else if token.kind == TkIdent {
    let lower = token.text.to_lower()
    let op = match lower {
      "contains" => Some(Contains)
      "startswith" => Some(StartsWith)
      "endswith" => Some(EndsWith)
      "in" => Some(In)
      "matches" => Some(Match)
      _ => None
    }
    match op {
      Some(found) => {
        parser.advance()
        Some(found)
      }
      None => None
    }
  } else {
    None
  }
}

///|
fn parse_comparison(parser : Parser) -> Expr raise QueryError {
  let left = parse_additive(parser)
  if parser.peek_keyword("is") {
    parser.advance()
    let mut negated = false
    if parser.peek_keyword("not") {
      parser.advance()
      negated = true
    }
    let word = parser.next_ident("null")
    if !@ascii.ascii_eq_ignore_case(word, "null") {
      raise QueryError(parser.position() + ": expected 'null' after 'is'")
    }
    return if negated { Binary(Ne, left, LitNull) } else { Binary(Eq, left, LitNull) }
  }
  match comparison_op(parser) {
    Some(op) => Binary(op, left, parse_additive(parser))
    None => left
  }
}

///|
fn parse_additive(parser : Parser) -> Expr raise QueryError {
  let mut left = parse_multiplicative(parser)
  while parser.peek_is_symbol("+") || parser.peek_is_symbol("-") {
    let plus = parser.peek_is_symbol("+")
    parser.advance()
    let right = parse_multiplicative(parser)
    left = if plus { Binary(Add, left, right) } else { Binary(Sub, left, right) }
  }
  left
}

///|
fn parse_multiplicative(parser : Parser) -> Expr raise QueryError {
  let mut left = parse_unary(parser)
  let mut more = true
  while more {
    let op = if parser.peek_is_symbol("*") {
      Some(Mul)
    } else if parser.peek_is_symbol("/") {
      Some(Div)
    } else if parser.peek_is_symbol("%") {
      Some(Mod)
    } else {
      None
    }
    match op {
      Some(found) => {
        parser.advance()
        left = Binary(found, left, parse_unary(parser))
      }
      None => more = false
    }
  }
  left
}

///|
fn parse_unary(parser : Parser) -> Expr raise QueryError {
  if parser.peek_is_symbol("-") {
    parser.advance()
    Unary(Neg, parse_unary(parser))
  } else if parser.peek_is_symbol("!") || parser.peek_keyword("not") {
    parser.advance()
    Unary(Not, parse_unary(parser))
  } else {
    parse_primary(parser)
  }
}

///|
fn parse_primary(parser : Parser) -> Expr raise QueryError {
  let token = parser.peek()
  match token.kind {
    TkNumber => {
      parser.advance()
      let text = token.text
      if text.contains(".") || text.contains("e") || text.contains("E") {
        match @moonloom.parse_double_opt(text) {
          Some(value) => LitNum(value)
          None => raise QueryError(parser.position() + ": '" + text + "' is not a number")
        }
      } else {
        match @moonloom.parse_int64_opt(text) {
          Some(value) => LitInt(value)
          None =>
            match @moonloom.parse_double_opt(text) {
              Some(value) => LitNum(value)
              None => raise QueryError(parser.position() + ": '" + text + "' is not a number")
            }
        }
      }
    }
    TkText => {
      parser.advance()
      LitStr(token.text)
    }
    TkIdent => {
      let lower = token.text.to_lower()
      if lower == "true" {
        parser.advance()
        LitBool(true)
      } else if lower == "false" {
        parser.advance()
        LitBool(false)
      } else if lower == "null" || lower == "nil" {
        parser.advance()
        LitNull
      } else if parser.tokens[parser.pos + 1].kind == TkSymbol &&
        parser.tokens[parser.pos + 1].text == "(" {
        parser.advance()
        parser.advance()
        let args : Array[Expr] = []
        if !parser.peek_is_symbol(")") {
          args.push(parse_expr(parser))
          while parser.peek_is_symbol(",") {
            parser.advance()
            args.push(parse_expr(parser))
          }
        }
        parser.expect_symbol(")")
        Call(token.text, args)
      } else {
        parser.advance()
        Field(token.text)
      }
    }
    TkSymbol =>
      if token.text == "(" {
        parser.advance()
        let inner = parse_expr(parser)
        parser.expect_symbol(")")
        inner
      } else if token.text == "[" {
        parser.advance()
        let items : Array[Expr] = []
        if !parser.peek_is_symbol("]") {
          items.push(parse_expr(parser))
          while parser.peek_is_symbol(",") {
            parser.advance()
            items.push(parse_expr(parser))
          }
        }
        parser.expect_symbol("]")
        List(items)
      } else {
        raise QueryError(parser.position() + ": expected a value, found '" + token.text + "'")
      }
    TkEnd => raise QueryError(parser.position() + ": unexpected end of query")
  }
}
