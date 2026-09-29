// Records, tables and the diagnostics that parsing produces.

///|
/// Something that went wrong while reading input. Diagnostics never stop a
/// parse: the offending line is skipped and reported, so one broken line in a
/// million still leaves a usable table.
pub(all) struct Diagnostic {
  code : String
  line : Int
  message : String
} derive(Eq, Debug)

///|
pub extend Diagnostic with Eq::{not_equal, equal}

///|
pub extend Diagnostic with @debug.Debug::{to_repr}

///|
pub fn Diagnostic::new(
  code : String,
  line : Int,
  message : String,
) -> Diagnostic {
  { code, line, message, }
}

///|
/// One row. `fields` holds the extracted values, `order` remembers the order in
/// which field names were first seen so that output columns stay stable, and
/// `raw` keeps the source text for `parse` stages and for debugging.
pub(all) struct Record {
  fields : Map[String, Value]
  order : Array[String]
  source_line : Int
  raw : String
} derive(Debug)

///|
pub extend Record with @debug.Debug::{to_repr}

///|
pub fn Record::empty(source_line : Int, raw : String) -> Record {
  { fields: Map([]), order: [], source_line, raw, }
}

///|
/// The value of a field, or `Null` when the record does not carry it.
pub fn Record::field(self : Record, name : String) -> Value {
  match self.fields.get(name) {
    Some(v) => v
    None => Null
  }
}

///|
pub fn Record::has(self : Record, name : String) -> Bool {
  self.fields.contains(name)
}

///|
/// Stores a value. A new name is appended to the column order, an existing one
/// keeps its position.
pub fn Record::set(self : Record, name : String, value : Value) -> Unit {
  if !self.fields.contains(name) {
    self.order.push(name)
  }
  self.fields[name] = value
}

///|
/// Stores a value only when the name is not present yet, which is how a parser
/// keeps the first occurrence of a repeated key.
pub fn Record::set_if_absent(
  self : Record,
  name : String,
  value : Value,
) -> Unit {
  if !self.fields.contains(name) {
    self.set(name, value)
  }
}

///|
pub fn Record::remove(self : Record, name : String) -> Unit {
  if self.fields.contains(name) {
    self.fields.remove(name)
    let kept : Array[String] = []
    for name_in_order in self.order {
      if name_in_order != name {
        kept.push(name_in_order)
      }
    }
    self.order.clear()
    self.order.push_iter(kept.iter())
  }
}

///|
/// Field names in first-seen order.
pub fn Record::names(self : Record) -> Array[String] {
  self.order.copy()
}

///|
pub fn Record::size(self : Record) -> Int {
  self.order.length()
}

///|
/// A table: an ordered set of columns plus the rows that carry them.
pub(all) struct Table {
  columns : Array[String]
  records : Array[Record]
  diagnostics : Array[Diagnostic]
} derive(Debug)

///|
pub extend Table with @debug.Debug::{to_repr}

///|
pub fn Table::empty() -> Table {
  { columns: [], records: [], diagnostics: [], }
}

///|
pub fn Table::of_records(
  columns : Array[String],
  records : Array[Record],
) -> Table {
  let table : Table = { columns: [], records, diagnostics: [], }
  for name in columns {
    table.add_column(name)
  }
  for record in records {
    for name in record.order {
      table.add_column(name)
    }
  }
  table
}

///|
/// Registers a column name, keeping first-seen order and ignoring repeats.
pub fn Table::add_column(self : Table, name : String) -> Unit {
  if !self.columns.contains(name) {
    self.columns.push(name)
  }
}

///|
pub fn Table::push(self : Table, record : Record) -> Unit {
  for name in record.order {
    self.add_column(name)
  }
  self.records.push(record)
}

///|
pub fn Table::add_diagnostic(self : Table, diagnostic : Diagnostic) -> Unit {
  self.diagnostics.push(diagnostic)
}

///|
pub fn Table::length(self : Table) -> Int {
  self.records.length()
}

///|
pub fn Table::is_empty(self : Table) -> Bool {
  self.records.is_empty()
}

///|
/// Column names in stable order, widened by any field that only some rows carry.
pub fn Table::column_names(self : Table) -> Array[String] {
  self.columns.copy()
}

///|
/// A parsed input together with how it was read.
pub(all) struct Dataset {
  table : Table
  format : String
  mut lines_read : Int
  mut skipped : Int
} derive(Debug)

///|
pub extend Dataset with @debug.Debug::{to_repr}

///|
pub fn Dataset::empty(format : String) -> Dataset {
  { table: Table::empty(), format, lines_read: 0, skipped: 0, }
}

///|
pub fn Dataset::add(self : Dataset, record : Record) -> Unit {
  self.table.push(record)
}

///|
pub fn Dataset::skip(self : Dataset, diagnostic : Diagnostic) -> Unit {
  self.table.add_diagnostic(diagnostic)
  self.skipped += 1
}

///|
pub fn Dataset::rows(self : Dataset) -> Int {
  self.table.length()
}
