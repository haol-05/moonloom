// Field level schema inference.
//
// MoonLoom does not ask for a schema, it recovers one from the data it read.
// Inference only reports what the values prove: a column is `int` when every
// present value is an integer and `mixed` as soon as two kinds disagree.

///|
/// Per column summary used by `moonloom schema`, by the planner when it decides
/// whether a comparison can be answered numerically, and by `explain`.
pub(all) struct FieldInfo {
  name : String
  kind : ValueKind
  present : Int
  missing : Int
  distinct : Int
} derive(Eq, Debug)

///|
pub extend FieldInfo with Eq::{not_equal, equal}

///|
pub extend FieldInfo with @debug.Debug::{to_repr}

///|
fn merge_kind(current : ValueKind, next : ValueKind) -> ValueKind {
  if current == next {
    return current
  }
  if current == KindNull {
    return next
  }
  if next == KindNull {
    return current
  }
  let numeric = (current == KindInt || current == KindNum) &&
    (next == KindInt || next == KindNum)
  if numeric {
    return KindNum
  }
  KindMixed
}

///|
/// Summarises every column of a table.
///
/// `distinct` counts the different printed values per column; it is optional
/// because it costs one set per column on wide tables.
pub fn infer_fields(table : Table, distinct? : Bool) -> Array[FieldInfo] {
  let count_distinct = distinct.unwrap_or(true)
  let fields : Array[FieldInfo] = []
  for name in table.columns {
    let mut kind = KindNull
    let mut present = 0
    let mut missing = 0
    let seen : Set[String] = Set([])
    for record in table.records {
      match record.fields.get(name) {
        Some(value) =>
          match value {
            Null => missing += 1
            _ => {
              present += 1
              kind = merge_kind(kind, value.kind())
              if count_distinct {
                seen.add(value.display())
              }
            }
          }
        None => missing += 1
      }
    }
    if present == 0 {
      kind = KindNull
    }
    fields.push({
      name,
      kind,
      present,
      missing,
      distinct: if count_distinct {
        seen.length()
      } else {
        0
      },
    })
  }
  fields
}

///|
/// Looks up one column summary by name.
pub fn find_field(fields : Array[FieldInfo], name : String) -> FieldInfo? {
  for info in fields {
    if info.name == name {
      return Some(info)
    }
  }
  None
}
