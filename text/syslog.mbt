// Syslog lines.
//
// Both shapes start with a priority in angle brackets. The old shape (RFC 3164)
// follows with `MMM dd HH:MM:SS host tag: message`; the new one (RFC 5424)
// follows with a version, an RFC 3339 timestamp, host, application, process id,
// message id and structured data.
//
// An RFC 3164 stamp has no year, so it is kept as text rather than invented.

///|
fn severity_name(severity : Int) -> String {
  match severity {
    0 => "emerg"
    1 => "alert"
    2 => "crit"
    3 => "err"
    4 => "warning"
    5 => "notice"
    6 => "info"
    7 => "debug"
    _ => "unknown"
  }
}

///|
fn facility_name(facility : Int) -> String {
  match facility {
    0 => "kern"
    1 => "user"
    2 => "mail"
    3 => "daemon"
    4 => "auth"
    5 => "syslog"
    6 => "lpr"
    7 => "news"
    8 => "uucp"
    9 => "cron"
    10 => "authpriv"
    11 => "ftp"
    16 => "local0"
    17 => "local1"
    18 => "local2"
    19 => "local3"
    20 => "local4"
    21 => "local5"
    22 => "local6"
    23 => "local7"
    _ => "other"
  }
}

///|
/// Reads one syslog line, returning `None` when it does not start with a
/// priority.
pub fn parse_syslog_line(line : String, source_line? : Int) -> @moonloom.Record? {
  let cu = line.code_units()
  let n = cu.length()
  if n < 3 || !@ascii.code_unit_is(cu[0], '<') {
    return None
  }
  let mut index = 1
  let mut priority = 0
  let mut digits = 0
  while index < n && @ascii.ascii_is_digit(cu[index]) {
    priority = priority * 10 + (cu[index].to_int() - 48)
    digits += 1
    index += 1
  }
  if digits == 0 || index >= n || !@ascii.code_unit_is(cu[index], '>') {
    return None
  }
  index += 1
  let record = @moonloom.Record::empty(source_line.unwrap_or(0), line)
  record.set("priority", @moonloom.Int(priority.to_int64()))
  record.set("facility", @moonloom.Str(facility_name(priority / 8)))
  record.set("severity", @moonloom.Str(severity_name(priority % 8)))
  index = skip_spaces(cu, index)
  if index >= n {
    return Some(record)
  }
  // A version digit followed by a space means RFC 5424.
  if @ascii.ascii_is_digit(cu[index]) {
    let mut scan = index
    while scan < n && @ascii.ascii_is_digit(cu[scan]) {
      scan += 1
    }
    if scan < n && @ascii.code_unit_is(cu[scan], ' ') {
      return Some(parse_rfc5424(line, cu, index, record))
    }
  }
  Some(parse_rfc3164(line, cu, index, record))
}

///|
fn parse_rfc5424(
  line : String,
  cu : ArrayView[UInt16],
  start : Int,
  record : @moonloom.Record,
) -> @moonloom.Record {
  let n = cu.length()
  let mut index = start
  let (version, after_version) = token_at(line, cu, index)
  record.set("version", @moonloom.Value::from_text(version))
  index = skip_spaces(cu, after_version)
  let (stamp, after_stamp) = token_at(line, cu, index)
  record.set("time_text", @moonloom.Str(stamp))
  record.set("time", timestamp_value(stamp))
  index = skip_spaces(cu, after_stamp)
  let (host, after_host) = token_at(line, cu, index)
  record.set("host", @moonloom.Value::from_text(host))
  index = skip_spaces(cu, after_host)
  let (app, after_app) = token_at(line, cu, index)
  record.set("app", @moonloom.Value::from_text(app))
  index = skip_spaces(cu, after_app)
  let (procid, after_procid) = token_at(line, cu, index)
  record.set("procid", @moonloom.Value::from_text(procid))
  index = skip_spaces(cu, after_procid)
  let (msgid, after_msgid) = token_at(line, cu, index)
  record.set("msgid", @moonloom.Value::from_text(msgid))
  index = skip_spaces(cu, after_msgid)
  if index < n && @ascii.code_unit_is(cu[index], '[') {
    let structured = StringBuilder()
    while index < n && @ascii.code_unit_is(cu[index], '[') {
      match read_bracketed(line, cu, index) {
        Some(pair) => {
          if !structured.is_empty() {
            structured.write_string(" ")
          }
          structured.write_string("[" + pair.0 + "]")
          index = skip_spaces(cu, pair.1)
        }
        None => {
          index = n
        }
      }
    }
    record.set("structured_data", @moonloom.Str(structured.to_string()))
  } else {
    let (dash, after_dash) = token_at(line, cu, index)
    record.set("structured_data", @moonloom.Str(dash))
    index = skip_spaces(cu, after_dash)
  }
  if index < n {
    record.set("message", @moonloom.Str(line[index:].to_owned()))
  }
  record
}

///|
fn parse_rfc3164(
  line : String,
  cu : ArrayView[UInt16],
  start : Int,
  record : @moonloom.Record,
) -> @moonloom.Record {
  let n = cu.length()
  let mut index = start
  if index + 15 <= n {
    let stamp = line[index:index + 15].to_owned()
    record.set("time_text", @moonloom.Str(stamp))
    record.set("time", @moonloom.Str(stamp))
    index = index + 15
  }
  index = skip_spaces(cu, index)
  let (host, after_host) = token_at(line, cu, index)
  record.set("host", @moonloom.Value::from_text(host))
  index = skip_spaces(cu, after_host)
  let rest = line[index:].to_owned()
  let cu2 = rest.code_units()
  let mut split = -1
  let mut scan = 0
  while scan < cu2.length() {
    if @ascii.code_unit_is(cu2[scan], ':') {
      split = scan
      break
    }
    scan += 1
  }
  if split < 0 {
    record.set("message", @moonloom.Str(rest))
    return record
  }
  let tag = rest[:split].to_owned()
  let message = rest[split + 1:].to_owned().trim().to_owned()
  let open = tag.find("[")
  match open {
    Some(at) => {
      let name = tag[:at].to_owned()
      let tail = tag[at + 1:].to_owned()
      let closing = tail.find("]")
      record.set("app", @moonloom.Str(name))
      match closing {
        Some(end) => record.set("procid", @moonloom.Value::from_text(tail[:end].to_owned()))
        None => record.set("procid", @moonloom.Str(tail))
      }
    }
    None => record.set("app", @moonloom.Str(tag))
  }
  record.set("message", @moonloom.Str(message))
  record
}

///|
/// Reads a whole syslog file, one record per line.
pub fn parse_syslog(text : String, max_records? : Int) -> @moonloom.Dataset {
  let dataset = @moonloom.Dataset::empty("syslog")
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
    match parse_syslog_line(line, source_line=line_number) {
      Some(record) => {
        dataset.add(record)
        dataset.lines_read += 1
      }
      None =>
        dataset.skip(
          @moonloom.Diagnostic::new(
            "not-syslog",
            line_number,
            "line does not start with a priority",
          ),
        )
    }
  }
  dataset
}
