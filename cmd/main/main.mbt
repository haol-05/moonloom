// The MoonLoom command line.
//
//   moonloom query --file app.log "level=error | stats count() by service"
//   moonloom schema --file data.csv
//   moonloom explain --file app.log "where level == \"error\""
//
// Input comes from `--file` or from `--text`, and the result goes to standard
// output in one of the formats `moonloom formats` lists.

///|
const USAGE : String =
  #|moonloom - a query engine over semi-structured text
  #|
  #|usage:
  #|  moonloom query   [options] <query>
  #|  moonloom schema  [options]
  #|  moonloom explain [options] <query>
  #|  moonloom formats
  #|  moonloom version
  #|
  #|options:
  #|  --file <path>     read the input from a file
  #|  --text <data>     read the input from the argument itself
  #|  --format <name>   input format: auto, csv, tsv, json, jsonl, logfmt,
  #|                    keyvalue, access, syslog, lines   (default: auto)
  #|  --output <name>   output format: table, json, jsonl, csv, markdown
  #|                    (default: table)
  #|  --no-index        do not build the index
  #|  --stats           print what the query cost
  #|  --plan            print the plan before the rows
  #|  --limit <n>       stop reading after n records (0 means all)
  #|  -h, --help        show this message
  #|
  #|examples:
  #|  moonloom query --file examples/access.log "where status >= 500 | stats count() as errors by path | sort errors desc | limit 5"
  #|  moonloom query --file examples/sales.csv --output markdown "stats sum(amount) as total by region"
  #|  moonloom schema --file examples/events.jsonl
  #|

///|
/// Everything the command line was asked to do.
struct Options {
  mut command : String
  mut file : String?
  mut text : String?
  mut format : String
  mut output : String
  mut use_index : Bool
  mut show_stats : Bool
  mut show_plan : Bool
  mut limit : Int
  mut query : String?
}

///|
fn default_options() -> Options {
  {
    command: "help",
    file: None,
    text: None,
    format: "auto",
    output: "table",
    use_index: true,
    show_stats: false,
    show_plan: false,
    limit: 0,
    query: None,
  }
}

///|
/// Reads the arguments.
///
/// A mistake comes back as a message rather than a silent guess: an option
/// without its value, a count that is not a number, or a second bare word,
/// which is what a query split by the shell looks like.
fn parse_args(args : Array[String]) -> Result[Options, String] {
  let options = default_options()
  let mut index = 0
  if args.length() > 0 {
    options.command = args[0]
  }
  index = 1
  while index < args.length() {
    let argument = args[index]
    match argument {
      "--file" => {
        if index + 1 >= args.length() {
          return Err("--file needs a path")
        }
        options.file = Some(args[index + 1])
        index += 2
      }
      "--text" => {
        if index + 1 >= args.length() {
          return Err("--text needs a value")
        }
        options.text = Some(args[index + 1])
        index += 2
      }
      "--format" => {
        if index + 1 >= args.length() {
          return Err("--format needs a name")
        }
        options.format = args[index + 1]
        index += 2
      }
      "--output" => {
        if index + 1 >= args.length() {
          return Err("--output needs a name")
        }
        options.output = args[index + 1]
        index += 2
      }
      "--limit" => {
        if index + 1 >= args.length() {
          return Err("--limit needs a count")
        }
        match @moonloom.parse_int_opt(args[index + 1]) {
          Some(value) => options.limit = value
          None =>
            return Err("--limit needs a count, found '" + args[index + 1] + "'")
        }
        index += 2
      }
      "--no-index" => {
        options.use_index = false
        index += 1
      }
      "--stats" => {
        options.show_stats = true
        index += 1
      }
      "--plan" => {
        options.show_plan = true
        index += 1
      }
      "-h" | "--help" => {
        options.command = "help"
        index += 1
      }
      _ => {
        // The first bare word after the command is the query. A second one
        // means the shell split the query, so say so instead of quietly
        // running a fragment of it.
        if argument.has_prefix("--") {
          return Err("unknown option '" + argument + "'")
        }
        match options.query {
          Some(_) =>
            return Err(
              "unexpected extra argument '" +
              argument +
              "'; quote the whole query as one argument",
            )
          None => options.query = Some(argument)
        }
        index += 1
      }
    }
  }
  Ok(options)
}

///|
fn read_source(options : Options) -> Result[String, String] {
  match options.text {
    Some(text) => Ok(text)
    None =>
      match options.file {
        None => Err("no input: pass --file <path> or --text <data>")
        Some(path) => {
          if !@fs.path_exists(path) {
            return Err("file not found: " + path)
          }
          Ok(@fs.read_file_to_string(path)) catch {
            @fs.IOError(message) => Err("cannot read " + path + ": " + message)
          }
        }
      }
  }
}

///|
/// Prints rendered output without adding a blank line when the rendering
/// already ends with one.
fn emit(text : String) -> Unit {
  if text.has_suffix("\n") {
    println(text[:text.length() - 1].to_owned())
  } else {
    println(text)
  }
}

///|
fn fail(message : String) -> Unit {
  println("moonloom: " + message)
  @sys.exit(1)
}

///|
fn is_command(word : String) -> Bool {
  match word {
    "query" | "explain" | "schema" | "formats" | "version" | "help" => true
    _ => false
  }
}

///|
/// Drops whatever the runtime put in front of the arguments.
///
/// On the JavaScript target the list starts with the interpreter and the script
/// path, and on native it starts with the executable path. Skipping everything
/// up to the command name makes the tool behave the same way wherever it runs.
fn command_arguments(args : Array[String]) -> Array[String] {
  let mut start = 0
  while start < args.length() && !is_command(args[start]) {
    start += 1
  }
  args[start:].to_owned()
}

///|
fn main {
  let args = @env.args()
  let rest = command_arguments(args)
  let options = match parse_args(rest) {
    Ok(parsed) => parsed
    Err(message) => {
      println("moonloom: " + message)
      println(USAGE)
      @sys.exit(1)
      return
    }
  }
  match options.command {
    "help" => println(USAGE)
    "formats" => print_formats()
    "version" => println("moonloom " + VERSION)
    "query" => run_query(options)
    "explain" => run_explain(options)
    "schema" => run_schema(options)
    _ => {
      println("moonloom: unknown command '" + options.command + "'")
      println(USAGE)
      @sys.exit(1)
    }
  }
}

///|
const VERSION : String = "0.1.1"

///|
fn print_formats() -> Unit {
  println("input formats")
  for name in @text.known_input_formats() {
    println("  " + name)
  }
  println("output formats")
  for name in @render.known_formats() {
    println("  " + name)
  }
}

///|
fn run_query(options : Options) -> Unit {
  let query_text = match options.query {
    Some(text) => text
    None => {
      fail("no query given")
      return
    }
  }
  let source = match read_source(options) {
    Ok(text) => text
    Err(message) => {
      fail(message)
      return
    }
  }
  let dataset = @text.parse_auto(
    source,
    format=options.format,
    max_records=options.limit,
  )
  let query = match @query.Query::parse(query_text) {
    Ok(parsed) => parsed
    Err(message) => {
      fail(message)
      return
    }
  }
  let built = if options.use_index {
    Some(@index.TableIndex::build(dataset.table))
  } else {
    None
  }
  let plan = @plan.compile(query, dataset.table, built)
  if options.show_plan {
    println(plan.explain())
  }
  let result = @exec.run(query, dataset.table, built)
  emit(@render.render(result, options.output))
  if options.show_stats {
    println(@render.render_stats(result.stats))
  }
}

///|
fn run_explain(options : Options) -> Unit {
  let query_text = match options.query {
    Some(text) => text
    None => {
      fail("no query given")
      return
    }
  }
  let source = match read_source(options) {
    Ok(text) => text
    Err(message) => {
      fail(message)
      return
    }
  }
  let dataset = @text.parse_auto(
    source,
    format=options.format,
    max_records=options.limit,
  )
  let query = match @query.Query::parse(query_text) {
    Ok(parsed) => parsed
    Err(message) => {
      fail(message)
      return
    }
  }
  let built = if options.use_index {
    Some(@index.TableIndex::build(dataset.table))
  } else {
    None
  }
  let plan = @plan.compile(query, dataset.table, built)
  emit(plan.explain())
  println(
    "input           format=" +
    dataset.format +
    "  records=" +
    dataset.rows().to_string() +
    "  skipped=" +
    dataset.skipped.to_string(),
  )
  println("index           fields=" + index_summary(built))
}

///|
fn index_summary(built : @index.TableIndex?) -> String {
  match built {
    Some(table_index) => table_index.indexed_fields().join(", ")
    None => "(disabled)"
  }
}

///|
fn run_schema(options : Options) -> Unit {
  let source = match read_source(options) {
    Ok(text) => text
    Err(message) => {
      fail(message)
      return
    }
  }
  let dataset = @text.parse_auto(
    source,
    format=options.format,
    max_records=options.limit,
  )
  println(
    "format " +
    dataset.format +
    "  records " +
    dataset.rows().to_string() +
    "  skipped " +
    dataset.skipped.to_string(),
  )
  emit(@render.render_schema(@moonloom.infer_fields(dataset.table)))
  if !dataset.table.diagnostics.is_empty() {
    println("diagnostics")
    let mut shown = 0
    for diagnostic in dataset.table.diagnostics {
      if shown < 10 {
        println(
          "  line " +
          diagnostic.line.to_string() +
          "  " +
          diagnostic.code +
          "  " +
          diagnostic.message,
        )
      }
      shown += 1
    }
    if shown > 10 {
      println("  ... " + (shown - 10).to_string() + " more")
    }
  }
}
