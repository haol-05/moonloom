// Timestamp and duration handling.
//
// Time is normalised to milliseconds since the Unix epoch in UTC. Parsing only
// accepts forms that carry enough information to be exact, so a syslog line
// without a year stays a string instead of being silently pinned to some year.

///|
fn idiv_floor(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  let y = if month <= 2L { year - 1L } else { year }
  let era = idiv_floor(y, 400L)
  let yoe = y - era * 400L
  let mp = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * mp + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let z = days + 719468L
  let era = idiv_floor(z, 146097L)
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  (if month <= 2L { y + 1L } else { y }, month, day)
}

///|
fn digits_at(cu : ArrayView[UInt16], start : Int, len : Int) -> Int64? {
  if start < 0 || start + len > cu.length() {
    return None
  }
  let mut value = 0L
  let mut index = start
  while index < start + len {
    if !@ascii.ascii_is_digit(cu[index]) {
      return None
    }
    value = value * 10L + (cu[index].to_int() - 48).to_int64()
    index += 1
  }
  Some(value)
}

///|
fn month_of(name : StringView) -> Int64? {
  let lower = name.to_lower()
  let table : Array[(StringView, Int64)] = [
    ("jan", 1L),
    ("feb", 2L),
    ("mar", 3L),
    ("apr", 4L),
    ("may", 5L),
    ("jun", 6L),
    ("jul", 7L),
    ("aug", 8L),
    ("sep", 9L),
    ("oct", 10L),
    ("nov", 11L),
    ("dec", 12L),
  ]
  for entry in table {
    if lower == entry.0 {
      return Some(entry.1)
    }
  }
  None
}

///|
fn is_all_digits(cu : ArrayView[UInt16]) -> Bool {
  if cu.length() == 0 {
    return false
  }
  let mut index = 0
  if @ascii.code_unit_is(cu[0], '-') || @ascii.code_unit_is(cu[0], '+') {
    index = 1
  }
  if index >= cu.length() {
    return false
  }
  while index < cu.length() {
    if !@ascii.ascii_is_digit(cu[index]) {
      return false
    }
    index += 1
  }
  true
}

///|
fn parse_offset_minutes(cu : ArrayView[UInt16], start : Int) -> Int64? {
  if start >= cu.length() {
    return None
  }
  let sign = cu[start]
  if !@ascii.code_unit_is(sign, '+') && !@ascii.code_unit_is(sign, '-') {
    return None
  }
  let rest = cu.length() - start - 1
  let hours = if rest >= 2 { digits_at(cu, start + 1, 2) } else { None }
  match hours {
    None => None
    Some(h) => {
      let mut minutes = 0L
      if rest == 4 {
        match digits_at(cu, start + 3, 2) {
          Some(m) => minutes = m
          None => return None
        }
      } else if rest == 5 {
        if !@ascii.code_unit_is(cu[start + 3], ':') {
          return None
        }
        match digits_at(cu, start + 4, 2) {
          Some(m) => minutes = m
          None => return None
        }
      } else if rest != 2 {
        return None
      }
      let total = h * 60L + minutes
      Some(if @ascii.code_unit_is(sign, '-') { -total } else { total })
    }
  }
}

///|
fn build_millis(
  year : Int64,
  month : Int64,
  day : Int64,
  hour : Int64,
  minute : Int64,
  second : Int64,
  milli : Int64,
  offset_minutes : Int64,
) -> Int64 {
  let days = days_from_civil(year, month, day)
  let seconds = days * 86400L + hour * 3600L + minute * 60L + second
  (seconds - offset_minutes * 60L) * 1000L + milli
}

///|
fn is_valid_date(year : Int64, month : Int64, day : Int64) -> Bool {
  if month < 1L || month > 12L || day < 1L || day > 31L {
    return false
  }
  let leap = (year % 4L == 0L && year % 100L != 0L) || year % 400L == 0L
  let limit = if month == 2L {
    if leap {
      29L
    } else {
      28L
    }
  } else if month == 4L || month == 6L || month == 9L || month == 11L {
    30L
  } else {
    31L
  }
  day <= limit
}

///|
fn is_valid_clock(hour : Int64, minute : Int64, second : Int64) -> Bool {
  hour <= 23L && minute <= 59L && second <= 60L
}

///|
fn parse_epoch(cu : ArrayView[UInt16], t : StringView, n : Int) -> Int64? {
  let mut digits = n
  if @ascii.code_unit_is(cu[0], '-') || @ascii.code_unit_is(cu[0], '+') {
    digits -= 1
  }
  let mut value = 0L
  try {
    value = @string.parse_int64(t)
  } catch {
    _ => return None
  }
  match digits {
    10 => Some(value * 1000L)
    13 => Some(value)
    16 => Some(value / 1000L)
    19 => Some(value / 1000000L)
    _ => None
  }
}

///|
fn parse_iso_like(cu : ArrayView[UInt16], n : Int) -> Int64? {
  if n < 10 {
    return None
  }
  let sep = cu[4]
  let iso_dash = @ascii.code_unit_is(sep, '-')
  let iso_slash = @ascii.code_unit_is(sep, '/')
  if !(iso_dash || iso_slash) || cu[7] != sep {
    return None
  }
  let year = digits_at(cu, 0, 4)
  let month = digits_at(cu, 5, 2)
  let day = digits_at(cu, 8, 2)
  match (year, month, day) {
    (Some(y), Some(mo), Some(d)) => {
      if !is_valid_date(y, mo, d) {
        return None
      }
      if n == 10 {
        return Some(build_millis(y, mo, d, 0L, 0L, 0L, 0L, 0L))
      }
      let time_sep = cu[10]
      if !@ascii.code_unit_is(time_sep, 'T') &&
        !@ascii.code_unit_is(time_sep, 't') &&
        !@ascii.code_unit_is(time_sep, ' ') {
        return None
      }
      match parse_clock(cu, 11) {
        Some(clock) => {
          let (hour, minute, second, milli, next) = clock
          let mut offset = 0L
          if next < n {
            if @ascii.code_unit_is(cu[next], 'Z') ||
              @ascii.code_unit_is(cu[next], 'z') {
              offset = 0L
            } else {
              match parse_offset_minutes(cu, next) {
                Some(o) => offset = o
                None => return None
              }
            }
          }
          Some(build_millis(y, mo, d, hour, minute, second, milli, offset))
        }
        None => None
      }
    }
    _ => None
  }
}

///|
fn parse_clf_like(cu : ArrayView[UInt16], t : StringView, n : Int) -> Int64? {
  if n < 19 ||
    !@ascii.code_unit_is(cu[2], '/') ||
    !@ascii.code_unit_is(cu[6], '/') {
    return None
  }
  let day = digits_at(cu, 0, 2)
  let month = month_of(t[3:6])
  let year = digits_at(cu, 7, 4)
  match (day, month, year) {
    (Some(d), Some(mo), Some(y)) => {
      if !is_valid_date(y, mo, d) {
        return None
      }
      if !@ascii.code_unit_is(cu[11], ':') {
        return None
      }
      match parse_clock(cu, 12) {
        Some(clock) => {
          let (hour, minute, second, _, next) = clock
          let mut offset = 0L
          if next + 1 < n {
            match parse_offset_minutes(cu, next + 1) {
              Some(o) => offset = o
              None => ()
            }
          }
          Some(build_millis(y, mo, d, hour, minute, second, 0L, offset))
        }
        None => None
      }
    }
    _ => None
  }
}

///|
/// Parses the timestamp forms that appear in real logs and data exports:
/// RFC 3339, `YYYY-MM-DD HH:MM:SS`, `YYYY/MM/DD HH:MM:SS`, the CLF form
/// `10/Oct/2000:13:55:36 -0700`, and bare epoch seconds, milliseconds,
/// microseconds or nanoseconds.
///
/// Returns milliseconds since the Unix epoch, or `None` when the text does not
/// carry a complete date. A date without a time is taken as midnight UTC.
pub fn parse_timestamp(text : StringView) -> Int64? {
  let t = text.trim()
  let cu = t.code_units()
  let n = cu.length()
  if n == 0 {
    return None
  }
  if is_all_digits(cu) {
    return parse_epoch(cu, t, n)
  }
  match parse_iso_like(cu, n) {
    Some(value) => Some(value)
    None => parse_clf_like(cu, t, n)
  }
}

///|
/// Reads `HH:MM:SS` with an optional `.fff` fraction starting at `start`, and
/// reports the index just past the time.
fn parse_clock(
  cu : ArrayView[UInt16],
  start : Int,
) -> (Int64, Int64, Int64, Int64, Int)? {
  if start + 8 > cu.length() {
    return None
  }
  let hour = digits_at(cu, start, 2)
  let minute = digits_at(cu, start + 3, 2)
  let second = digits_at(cu, start + 6, 2)
  if !@ascii.code_unit_is(cu[start + 2], ':') ||
    !@ascii.code_unit_is(cu[start + 5], ':') {
    return None
  }
  match (hour, minute, second) {
    (Some(h), Some(mi), Some(s)) => {
      if !is_valid_clock(h, mi, s) {
        return None
      }
      let mut milli = 0L
      let mut next = start + 8
      if next < cu.length() && @ascii.code_unit_is(cu[next], '.') {
        let mut digits = 0
        let mut value = 0L
        let mut index = next + 1
        while index < cu.length() &&
              @ascii.ascii_is_digit(cu[index]) &&
              digits < 3 {
          value = value * 10L + (cu[index].to_int() - 48).to_int64()
          digits += 1
          index += 1
        }
        while index < cu.length() && @ascii.ascii_is_digit(cu[index]) {
          index += 1
        }
        while digits < 3 {
          value = value * 10L
          digits += 1
        }
        milli = value
        next = index
      }
      Some((h, mi, s, milli, next))
    }
    _ => None
  }
}

///|
fn pad(value : Int64, width : Int) -> String {
  let text = value.to_string()
  let out = StringBuilder()
  let mut missing = width - text.length()
  while missing > 0 {
    out.write_string("0")
    missing -= 1
  }
  out.write_string(text)
  out.to_string()
}

///|
/// Formats milliseconds since the epoch as an RFC 3339 timestamp in UTC.
pub fn format_timestamp(ms : Int64) -> String {
  let days = idiv_floor(ms, 86400000L)
  let remainder = ms - days * 86400000L
  let (year, month, day) = civil_from_days(days)
  let hour = remainder / 3600000L
  let minute = remainder % 3600000L / 60000L
  let second = remainder % 60000L / 1000L
  let milli = remainder % 1000L
  let out = StringBuilder()
  out.write_string(pad(year, 4))
  out.write_string("-")
  out.write_string(pad(month, 2))
  out.write_string("-")
  out.write_string(pad(day, 2))
  out.write_string("T")
  out.write_string(pad(hour, 2))
  out.write_string(":")
  out.write_string(pad(minute, 2))
  out.write_string(":")
  out.write_string(pad(second, 2))
  if milli != 0L {
    out.write_string(".")
    out.write_string(pad(milli, 3))
  }
  out.write_string("Z")
  out.to_string()
}

///|
/// Parses a duration such as `250ms`, `30s`, `5m`, `2h`, `7d`, or a sum of
/// those (`1h30m`). Returns milliseconds.
pub fn parse_duration(text : StringView) -> Int64? {
  let t = text.trim()
  let cu = t.code_units()
  let n = cu.length()
  if n == 0 {
    return None
  }
  let mut total = 0L
  let mut index = 0
  let mut saw_unit = false
  while index < n {
    let start = index
    while index < n && @ascii.ascii_is_digit(cu[index]) {
      index += 1
    }
    if index == start {
      return None
    }
    match digits_at(cu, start, index - start) {
      Some(value) => {
        let unit_start = index
        while index < n && @ascii.ascii_is_alpha(cu[index]) {
          index += 1
        }
        if index == unit_start {
          return None
        }
        let unit = t[unit_start:index].to_lower()
        let scale = if unit == "ms" {
          1L
        } else if unit == "s" || unit == "sec" || unit == "secs" {
          1000L
        } else if unit == "m" || unit == "min" || unit == "mins" {
          60000L
        } else if unit == "h" || unit == "hr" || unit == "hrs" {
          3600000L
        } else if unit == "d" || unit == "day" || unit == "days" {
          86400000L
        } else if unit == "w" || unit == "week" || unit == "weeks" {
          604800000L
        } else {
          0L
        }
        if scale == 0L {
          return None
        }
        total += value * scale
        saw_unit = true
      }
      None => return None
    }
  }
  if saw_unit {
    Some(total)
  } else {
    None
  }
}

///|
/// Renders a duration in the largest units that keep it readable.
pub fn format_duration(ms : Int64) -> String {
  if ms == 0L {
    return "0s"
  }
  let negative = ms < 0L
  let value = if negative { -ms } else { ms }
  let out = StringBuilder()
  if negative {
    out.write_string("-")
  }
  let days = value / 86400000L
  let hours = value % 86400000L / 3600000L
  let minutes = value % 3600000L / 60000L
  let seconds = value % 60000L / 1000L
  let millis = value % 1000L
  let mut wrote = false
  if days > 0L {
    out.write_string(days.to_string() + "d")
    wrote = true
  }
  if hours > 0L {
    if wrote {
      out.write_string(" ")
    }
    out.write_string(hours.to_string() + "h")
    wrote = true
  }
  if minutes > 0L {
    if wrote {
      out.write_string(" ")
    }
    out.write_string(minutes.to_string() + "m")
    wrote = true
  }
  if seconds > 0L {
    if wrote {
      out.write_string(" ")
    }
    out.write_string(seconds.to_string() + "s")
    wrote = true
  }
  if millis > 0L {
    if wrote {
      out.write_string(" ")
    }
    out.write_string(millis.to_string() + "ms")
  }
  out.to_string()
}
