// Web server access logs in the Common and Combined Log Format.
//
//   host ident user [10/Oct/2000:13:55:36 -0700] "GET /a.gif HTTP/1.0" 200 2326
//
// The combined form appends the referer and the user agent, and many servers
// append a request time. Every part after the timestamp is optional, so the
// reader accepts a short line instead of dropping it.

///|
fn token_at(
  line : String,
  cu : ArrayView[UInt16],
  start : Int,
) -> (String, Int) {
  let mut index = start
  while index < cu.length() &&
        !@ascii.code_unit_is(cu[index], ' ') &&
        !@ascii.code_unit_is(cu[index], '\t') {
    index += 1
  }
  (line[start:index].to_owned(), index)
}

///|
/// A timestamp field becomes an integer of epoch milliseconds when the text
/// carries a complete date, and the original text otherwise, so a query can
/// still sort and filter on it.
pub fn timestamp_value(raw : String) -> @moonloom.Value {
  match parse_timestamp(raw) {
    Some(ms) => @moonloom.Int(ms)
    None => @moonloom.Str(raw)
  }
}

///|
/// Reads one access log line. Returns `None` when the line does not have the
/// `host ident user [time]` shape.
pub fn parse_access_line(
  line : String,
  source_line? : Int,
) -> @moonloom.Record? {
  let cu = line.code_units()
  let n = cu.length()
  let record = @moonloom.Record::empty(source_line.unwrap_or(0), line)
  let mut index = skip_spaces(cu, 0)
  if index >= n {
    return None
  }
  let (host, after_host) = token_at(line, cu, index)
  record.set("remote_host", @moonloom.Value::from_text(host))
  index = skip_spaces(cu, after_host)
  let (ident, after_ident) = token_at(line, cu, index)
  record.set("ident", @moonloom.Value::from_text(ident))
  index = skip_spaces(cu, after_ident)
  let (user, after_user) = token_at(line, cu, index)
  record.set("user", @moonloom.Value::from_text(user))
  index = skip_spaces(cu, after_user)
  if index >= n || !@ascii.code_unit_is(cu[index], '[') {
    return None
  }
  match read_bracketed(line, cu, index) {
    Some(pair) => {
      record.set("time_text", @moonloom.Str(pair.0))
      record.set("time", timestamp_value(pair.0))
      index = skip_spaces(cu, pair.1)
    }
    None => return None
  }
  if index < n && @ascii.code_unit_is(cu[index], '"') {
    match read_quoted(cu, index) {
      Some(pair) => {
        let request = pair.0
        record.set("request", @moonloom.Str(request))
        let parts = split_plain(request, ' ')
        if parts.length() >= 1 {
          record.set("method", @moonloom.Str(parts[0]))
        }
        if parts.length() >= 2 {
          record.set("path", @moonloom.Str(parts[1]))
        }
        if parts.length() >= 3 {
          record.set("protocol", @moonloom.Str(parts[2]))
        }
        index = skip_spaces(cu, pair.1)
      }
      None => ()
    }
  }
  let (status, after_status) = token_at(line, cu, index)
  if status != "" {
    record.set("status", @moonloom.Value::from_text(status))
  }
  index = skip_spaces(cu, after_status)
  let (bytes, after_bytes) = token_at(line, cu, index)
  if bytes != "" {
    record.set("bytes", @moonloom.Value::from_text(bytes))
  }
  index = skip_spaces(cu, after_bytes)
  if index < n && @ascii.code_unit_is(cu[index], '"') {
    match read_quoted(cu, index) {
      Some(pair) => {
        record.set("referer", @moonloom.Str(pair.0))
        index = skip_spaces(cu, pair.1)
      }
      None => ()
    }
  }
  if index < n && @ascii.code_unit_is(cu[index], '"') {
    match read_quoted(cu, index) {
      Some(pair) => {
        record.set("user_agent", @moonloom.Str(pair.0))
        index = skip_spaces(cu, pair.1)
      }
      None => ()
    }
  }
  if index < n && @ascii.ascii_is_digit(cu[index]) {
    let (elapsed, _) = token_at(line, cu, index)
    record.set("request_time", @moonloom.Value::from_text(elapsed))
  }
  Some(record)
}

///|
/// Reads a whole access log, one record per line.
pub fn parse_access_log(text : String, max_records? : Int) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("access")
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
    match parse_access_line(line, source_line=line_number) {
      Some(record) => {
        dataset.add(record)
        dataset.lines_read += 1
      }
      None =>
        dataset.skip(
          @moonloom.Diagnostic::new(
            "not-access-log", line_number, "line does not match the access log shape",
          ),
        )
    }
  }
  dataset
}
