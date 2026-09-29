// Number parsing helpers.
//
// The toolchain parsers raise a generic error; these wrappers turn them into
// `Option`, which is what schema-on-read typing and the query planner want.

///|
pub fn parse_int_opt(text : StringView) -> Int? {
  Some(@string.parse_int(text)) catch {
    _ => None
  }
}

///|
pub fn parse_int64_opt(text : StringView) -> Int64? {
  Some(@string.parse_int64(text)) catch {
    _ => None
  }
}

///|
pub fn parse_double_opt(text : StringView) -> Double? {
  Some(@string.parse_double(text)) catch {
    _ => None
  }
}
