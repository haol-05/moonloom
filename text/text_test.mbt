// Behaviour tests for the text readers.

///|
test "lines: LF, CRLF and CR all split the same way" {
  assert_eq(@text.split_lines("a\nb\nc"), ["a", "b", "c"])
  assert_eq(@text.split_lines("a\r\nb\r\n"), ["a", "b"])
  assert_eq(@text.split_lines("a\rb"), ["a", "b"])
  assert_eq(@text.split_lines("a\n"), ["a"])
  assert_eq(@text.split_lines(""), [])
}

///|
test "lines: byte order mark is dropped" {
  assert_eq(@text.strip_bom("\u{FEFF}name,age"), "name,age")
  assert_eq(@text.strip_bom("name"), "name")
  assert_true(@text.is_blank("  \t "))
  assert_false(@text.is_blank(" x "))
}

///|
test "time: RFC 3339, space form and date only agree" {
  let expected = 1704164645000L
  assert_eq(@text.parse_timestamp("2024-01-02T03:04:05Z"), Some(expected))
  assert_eq(@text.parse_timestamp("2024-01-02 03:04:05"), Some(expected))
  assert_eq(@text.parse_timestamp("2024/01/02 03:04:05"), Some(expected))
  assert_eq(@text.parse_timestamp("2024-01-02"), Some(1704153600000L))
  assert_eq(@text.parse_timestamp("not a time"), None)
  assert_eq(@text.parse_timestamp("2024-13-99T00:00:00Z"), None)
  assert_eq(@text.parse_timestamp("2023-02-29T00:00:00Z"), None)
  assert_eq(@text.parse_timestamp("2024-02-29T00:00:00Z"), Some(1709164800000L))
  assert_eq(@text.parse_timestamp("2024-01-02T25:00:00Z"), None)
}

///|
test "time: offsets and epoch numbers" {
  let utc = @text.parse_timestamp("2000-10-10T20:55:36Z")
  assert_eq(@text.parse_timestamp("10/Oct/2000:13:55:36 -0700"), utc)
  assert_eq(@text.parse_timestamp("2000-10-10T13:55:36-07:00"), utc)
  assert_eq(@text.parse_timestamp("1704164645"), Some(1704164645000L))
  assert_eq(@text.parse_timestamp("1704164645000"), Some(1704164645000L))
}

///|
test "time: formatting round-trips" {
  let ms = 1704164645000L
  assert_eq(@text.format_timestamp(ms), "2024-01-02T03:04:05Z")
  assert_eq(@text.parse_timestamp(@text.format_timestamp(ms)), Some(ms))
  assert_eq(@text.format_timestamp(0L), "1970-01-01T00:00:00Z")
  assert_eq(@text.format_timestamp(-86400000L), "1969-12-31T00:00:00Z")
}

///|
test "time: durations" {
  assert_eq(@text.parse_duration("500ms"), Some(500L))
  assert_eq(@text.parse_duration("30s"), Some(30000L))
  assert_eq(@text.parse_duration("5m"), Some(300000L))
  assert_eq(@text.parse_duration("1h30m"), Some(5400000L))
  assert_eq(@text.parse_duration("2d"), Some(172800000L))
  assert_eq(@text.parse_duration("x"), None)
  assert_eq(@text.format_duration(5400000L), "1h 30m")
  assert_eq(@text.format_duration(0L), "0s")
}

///|
test "csv: quoted fields keep the delimiter and the line break" {
  let text = "name,note\n\"Smith, John\",\"line1\nline2\"\n"
  let dataset = @text.parse_csv(text)
  assert_eq(dataset.rows(), 1)
  let record = dataset.table.records[0]
  assert_eq(record.field("name"), @moonloom.Str("Smith, John"))
  assert_eq(record.field("note"), @moonloom.Str("line1\nline2"))
  assert_eq(dataset.table.column_names(), ["name", "note"])
}

///|
test "csv: doubled quotes become one quote" {
  let dataset = @text.parse_csv("q\n\"say \"\"hi\"\"\"\n")
  assert_eq(dataset.table.records[0].field("q"), @moonloom.Str("say \"hi\""))
}

///|
test "csv: delimiter is guessed and can be forced" {
  assert_eq(@text.detect_delimiter("a;b;c\n1;2;3"), ';')
  assert_eq(@text.detect_delimiter("a\tb\n1\t2"), '\t')
  assert_eq(@text.detect_delimiter("a,b\n1,2"), ',')
  let dataset = @text.parse_csv("a|b\n1|2\n", delimiter='|')
  assert_eq(dataset.table.records[0].field("b"), @moonloom.Int(2L))
}

///|
test "csv: values are typed and short rows stay usable" {
  let dataset = @text.parse_csv("n,f,flag,empty\n1,2.5,true,\n")
  let record = dataset.table.records[0]
  assert_eq(record.field("n"), @moonloom.Int(1L))
  assert_eq(record.field("f"), @moonloom.Num(2.5))
  assert_eq(record.field("flag"), @moonloom.Bool(true))
  assert_eq(record.field("empty"), @moonloom.Null)
}

///|
test "csv: a headerless file gets generated names" {
  let dataset = @text.parse_csv("1,2\n3,4\n", header=false)
  assert_eq(dataset.table.column_names(), ["c1", "c2"])
  assert_eq(dataset.rows(), 2)
}

///|
test "csv: leading zeros stay text" {
  let dataset = @text.parse_csv("zip\n007\n")
  assert_eq(dataset.table.records[0].field("zip"), @moonloom.Str("007"))
}

///|
test "jsonl: nested objects become dotted fields" {
  let text = "{\"a\":1,\"b\":{\"c\":\"x\"},\"d\":[1,2],\"e\":true,\"f\":null}\n"
  let dataset = @text.parse_jsonl(text)
  assert_eq(dataset.format, "jsonl")
  let record = dataset.table.records[0]
  assert_eq(record.field("a"), @moonloom.Int(1L))
  assert_eq(record.field("b.c"), @moonloom.Str("x"))
  assert_eq(record.field("d.0"), @moonloom.Int(1L))
  assert_eq(record.field("d.1"), @moonloom.Int(2L))
  assert_eq(record.field("e"), @moonloom.Bool(true))
  assert_eq(record.field("f"), @moonloom.Null)
}

///|
test "jsonl: a broken line is reported and the rest survive" {
  let dataset = @text.parse_jsonl("{\"a\":1}\nnot json\n{\"a\":2}\n")
  assert_eq(dataset.rows(), 2)
  assert_eq(dataset.skipped, 1)
  assert_eq(dataset.table.diagnostics[0].code, "invalid-json")
  assert_eq(dataset.table.diagnostics[0].line, 2)
}

///|
test "json: an array of objects becomes rows" {
  let dataset = @text.parse_json("[{\"a\":1},{\"a\":2}]")
  assert_eq(dataset.format, "json")
  assert_eq(dataset.rows(), 2)
  assert_eq(dataset.table.records[1].field("a"), @moonloom.Int(2L))
}

///|
test "logfmt: quoted values, numbers and bare flags" {
  let dataset = @text.parse_logfmt("level=info msg=\"hello world\" n=3 ok=true verbose\n")
  let record = dataset.table.records[0]
  assert_eq(record.field("level"), @moonloom.Str("info"))
  assert_eq(record.field("msg"), @moonloom.Str("hello world"))
  assert_eq(record.field("n"), @moonloom.Int(3L))
  assert_eq(record.field("ok"), @moonloom.Bool(true))
  assert_eq(record.field("verbose"), @moonloom.Bool(true))
}

///|
test "keyvalue: sections prefix later keys" {
  let text = "[server]\nport: 8080\n# a comment\nhost: localhost\n[db]\nport: 5432\n"
  let dataset = @text.parse_keyvalue(text)
  assert_eq(dataset.rows(), 1)
  let record = dataset.table.records[0]
  assert_eq(record.field("server.port"), @moonloom.Int(8080L))
  assert_eq(record.field("server.host"), @moonloom.Str("localhost"))
  assert_eq(record.field("db.port"), @moonloom.Int(5432L))
}

///|
test "keyvalue: dash list items and inline comments" {
  let dataset = @text.parse_keyvalue("- name: api\n  replicas: 3  # three\n", sections=false)
  let record = dataset.table.records[0]
  assert_eq(record.field("name"), @moonloom.Str("api"))
  assert_eq(record.field("replicas"), @moonloom.Int(3L))
}

///|
test "access: combined log line is split into fields" {
  let line = "127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] \"GET /a.gif HTTP/1.0\" 200 2326 \"http://ref\" \"Mozilla/4.08\""
  let dataset = @text.parse_access_log(line)
  assert_eq(dataset.rows(), 1)
  let record = dataset.table.records[0]
  assert_eq(record.field("remote_host"), @moonloom.Str("127.0.0.1"))
  assert_eq(record.field("user"), @moonloom.Str("frank"))
  assert_eq(record.field("method"), @moonloom.Str("GET"))
  assert_eq(record.field("path"), @moonloom.Str("/a.gif"))
  assert_eq(record.field("protocol"), @moonloom.Str("HTTP/1.0"))
  assert_eq(record.field("status"), @moonloom.Int(200L))
  assert_eq(record.field("bytes"), @moonloom.Int(2326L))
  assert_eq(record.field("referer"), @moonloom.Str("http://ref"))
  assert_eq(record.field("user_agent"), @moonloom.Str("Mozilla/4.08"))
  assert_eq(
    record.field("time"),
    @moonloom.Int(@text.parse_timestamp("2000-10-10T20:55:36Z").unwrap()),
  )
}

///|
test "access: a short line still yields the readable fields" {
  let dataset = @text.parse_access_log("10.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.1\" 304 -\n")
  let record = dataset.table.records[0]
  assert_eq(record.field("status"), @moonloom.Int(304L))
  assert_eq(record.field("bytes"), @moonloom.Str("-"))
}

///|
test "syslog: RFC 3164 line" {
  let line = "<34>Oct 11 22:14:15 mymachine su[123]: 'su root' failed"
  let dataset = @text.parse_syslog(line)
  assert_eq(dataset.rows(), 1)
  let record = dataset.table.records[0]
  assert_eq(record.field("priority"), @moonloom.Int(34L))
  assert_eq(record.field("facility"), @moonloom.Str("auth"))
  assert_eq(record.field("severity"), @moonloom.Str("crit"))
  assert_eq(record.field("host"), @moonloom.Str("mymachine"))
  assert_eq(record.field("app"), @moonloom.Str("su"))
  assert_eq(record.field("procid"), @moonloom.Int(123L))
  assert_eq(record.field("message"), @moonloom.Str("'su root' failed"))
}

///|
test "syslog: RFC 5424 line" {
  let line = "<34>1 2003-10-11T22:14:15.003Z mymachine su 1234 ID47 - 'su root' failed"
  let dataset = @text.parse_syslog(line)
  let record = dataset.table.records[0]
  assert_eq(record.field("version"), @moonloom.Int(1L))
  assert_eq(record.field("host"), @moonloom.Str("mymachine"))
  assert_eq(record.field("app"), @moonloom.Str("su"))
  assert_eq(record.field("msgid"), @moonloom.Str("ID47"))
  assert_eq(record.field("structured_data"), @moonloom.Str("-"))
  assert_eq(record.field("message"), @moonloom.Str("'su root' failed"))
  assert_true(record.field("time") is @moonloom.Int(_))
}

///|
test "pattern: fields stop at the next literal" {
  let text = "2024-01-02T03:04:05Z info api: started ok\n"
  let dataset = @text.parse_pattern(text, "{ts} {level} {service}: {msg}")
  assert_eq(dataset.rows(), 1)
  let record = dataset.table.records[0]
  assert_eq(record.field("ts"), @moonloom.Str("2024-01-02T03:04:05Z"))
  assert_eq(record.field("level"), @moonloom.Str("info"))
  assert_eq(record.field("service"), @moonloom.Str("api"))
  assert_eq(record.field("msg"), @moonloom.Str("started ok"))
}

///|
test "pattern: adjacent fields and unclosed braces are rejected" {
  assert_eq(@text.Pattern::compile("{a}{b}"), None)
  assert_true(@text.Pattern::compile("{a} x") is Some(_))
  assert_eq(@text.Pattern::compile("{a"), None)
  assert_eq(@text.Pattern::compile("{}"), None)
  let dataset = @text.parse_pattern("x\n", "{a")
  assert_eq(dataset.table.diagnostics[0].code, "bad-pattern")
}

///|
test "pattern: a missing literal drops only that line" {
  let dataset = @text.parse_pattern("a=1\nzzz\n", "{k}={v}")
  assert_eq(dataset.rows(), 1)
  assert_eq(dataset.skipped, 1)
}

///|
test "auto: format detection picks the reader that fits" {
  assert_eq(@text.detect_format("{\"a\":1}\n"), "jsonl")
  assert_eq(@text.detect_format("[{\"a\":1}]"), "json")
  assert_eq(@text.detect_format("<34>Oct 11 22:14:15 host app: hi\n"), "syslog")
  assert_eq(@text.detect_format("a,b,c\n1,2,3\n"), "csv")
  assert_eq(@text.detect_format("level=info msg=x\n"), "logfmt")
  assert_eq(@text.detect_format("port: 8080\n"), "keyvalue")
  assert_eq(@text.detect_format("just some text\n"), "lines")
}

///|
test "auto: parse_auto follows the detected format and honours an override" {
  let detected = @text.parse_auto("{\"a\":1}\n{\"a\":2}\n")
  assert_eq(detected.format, "jsonl")
  assert_eq(detected.rows(), 2)
  let forced = @text.parse_auto("{\"a\":1}\n", format="lines")
  assert_eq(forced.format, "lines")
  assert_eq(forced.table.records[0].field("line"), @moonloom.Str("{\"a\":1}"))
}

///|
test "auto: max_records caps how much is read" {
  let text = "a,b\n1,2\n3,4\n5,6\n"
  let dataset = @text.parse_auto(text, max_records=2)
  assert_eq(dataset.rows(), 2)
}
