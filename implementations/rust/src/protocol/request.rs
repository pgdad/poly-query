//! Validation of protocol requests into typed values (protocol.md §4–§5).

use crate::engine::{ExecMode, LoadRequest, OpenRequest, QueryOptions, SaveRequest, Source};
use crate::error::{Error, Result};
use crate::ingest::Format;
use crate::json::Json;
use crate::planner::physical::JoinStrategy;
use crate::storage::pqcf::write::{EncodingChoice, SaveOptions};
use crate::storage::{Field, Layout};
use crate::types::DataType;

#[derive(Debug)]
pub enum Request {
    Version,
    Capabilities,
    Tables,
    Schema { table: String },
    Drop { table: String },
    Reset,
    Load(LoadRequest),
    Save(SaveRequest),
    Open(OpenRequest),
    Stats { table: String },
    Query { sql: String, options: QueryOptions },
    Explain { sql: String, options: QueryOptions },
    Sleep { ms: u64 },
}

fn invalid(msg: impl Into<String>) -> Error {
    Error::invalid_request(msg)
}

/// A field that is absent or JSON null.
fn field<'a>(req: &'a Json, key: &str) -> Option<&'a Json> {
    req.get(key).filter(|v| !matches!(v, Json::Null))
}

fn required_str(req: &Json, key: &str) -> Result<String> {
    match field(req, key) {
        Some(Json::String(s)) => Ok(s.clone()),
        Some(_) => Err(invalid(format!("field '{key}' must be a string"))),
        None => Err(invalid(format!("missing required field '{key}'"))),
    }
}

fn table_name(req: &Json) -> Result<String> {
    let t = required_str(req, "table")?;
    if t.is_empty() {
        return Err(invalid("table name must not be empty"));
    }
    Ok(t)
}

fn optional_bool(obj: &Json, key: &str) -> Result<Option<bool>> {
    match field(obj, key) {
        None => Ok(None),
        Some(Json::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(invalid(format!("field '{key}' must be a boolean"))),
    }
}

fn optional_uint(obj: &Json, key: &str) -> Result<Option<u64>> {
    match field(obj, key) {
        None => Ok(None),
        Some(v) => match v.as_i64() {
            Some(n) if n >= 0 => Ok(Some(n as u64)),
            _ => Err(invalid(format!(
                "field '{key}' must be a non-negative integer"
            ))),
        },
    }
}

fn optional_str<'a>(obj: &'a Json, key: &str) -> Result<Option<&'a str>> {
    match field(obj, key) {
        None => Ok(None),
        Some(Json::String(s)) => Ok(Some(s)),
        Some(_) => Err(invalid(format!("field '{key}' must be a string"))),
    }
}

fn optional_object<'a>(req: &'a Json, key: &str) -> Result<Option<&'a Json>> {
    match field(req, key) {
        None => Ok(None),
        Some(v @ Json::Object(_)) => Ok(Some(v)),
        Some(_) => Err(invalid(format!("field '{key}' must be an object"))),
    }
}

impl Request {
    /// Validates a request object.
    pub fn parse(req: &Json, test_functions: bool) -> Result<Request> {
        let op = match req.get("op") {
            Some(Json::String(s)) => s.as_str(),
            Some(_) => return Err(invalid("field 'op' must be a string")),
            None => return Err(invalid("missing required field 'op'")),
        };
        Ok(match op {
            "version" => Request::Version,
            "capabilities" => Request::Capabilities,
            "tables" => Request::Tables,
            "reset" => Request::Reset,
            "schema" => Request::Schema {
                table: table_name(req)?,
            },
            "drop" => Request::Drop {
                table: table_name(req)?,
            },
            "load" => Request::Load(parse_load(req)?),
            "query" => Request::Query {
                sql: required_str(req, "sql")?,
                options: parse_query_options(req)?,
            },
            "sleep" => {
                if !test_functions {
                    return Err(invalid("the sleep op requires --enable-test-functions"));
                }
                let ms = optional_uint(req, "ms")?
                    .ok_or_else(|| invalid("missing required field 'ms'"))?;
                Request::Sleep { ms }
            }
            "explain" => Request::Explain {
                sql: required_str(req, "sql")?,
                options: parse_query_options(req)?,
            },
            "save" => Request::Save(parse_save(req)?),
            "open" => Request::Open(parse_open(req)?),
            "stats" => Request::Stats {
                table: table_name(req)?,
            },
            other => return Err(invalid(format!("unknown op '{other}'"))),
        })
    }
}

fn parse_load(req: &Json) -> Result<LoadRequest> {
    let table = table_name(req)?;
    let format_name = required_str(req, "format")?;
    let format = Format::parse(&format_name)
        .ok_or_else(|| invalid(format!("unknown format '{format_name}'")))?;
    let path = optional_str(req, "path")?;
    let data = optional_str(req, "data")?;
    let source = match (path, data) {
        (Some(p), None) => Source::Path(p.to_string()),
        (None, Some(d)) => Source::Data(d.to_string()),
        (Some(_), Some(_)) => return Err(invalid("exactly one of 'path' or 'data' must be given")),
        (None, None) => return Err(invalid("one of 'path' or 'data' is required")),
    };
    let schema = match field(req, "schema") {
        None => None,
        Some(Json::Array(items)) => {
            let mut fields = Vec::with_capacity(items.len());
            for item in items {
                let name = required_str(item, "name")
                    .map_err(|_| invalid("schema entries need a string 'name'"))?;
                let ty = required_str(item, "type")
                    .map_err(|_| invalid("schema entries need a string 'type'"))?;
                let ty = DataType::parse(&ty)
                    .map_err(|e| invalid(format!("schema column '{name}': {}", e.message)))?;
                fields.push(Field::new(name, ty));
            }
            Some(fields)
        }
        Some(_) => return Err(invalid("field 'schema' must be an array")),
    };
    let mut header = true;
    let mut delimiter = b',';
    let mut layout = Layout::default();
    let mut dictionary = None;
    if let Some(opts) = optional_object(req, "options")? {
        layout = parse_layout(opts)?.unwrap_or_default();
        dictionary = optional_bool(opts, "dictionary")?;
        if let Some(h) = optional_bool(opts, "header")? {
            header = h;
        }
        if let Some(d) = optional_str(opts, "delimiter")? {
            let b = d.as_bytes();
            if b.len() != 1 || !b[0].is_ascii() || matches!(b[0], b'"' | b'\n' | b'\r') {
                return Err(invalid("delimiter must be a single ASCII character"));
            }
            delimiter = b[0];
        }
    }
    if format == Format::Csv && !header && schema.is_none() {
        return Err(invalid("header=false requires an explicit schema"));
    }
    let replace = optional_bool(req, "replace")?.unwrap_or(false);
    Ok(LoadRequest {
        table,
        format,
        source,
        schema,
        header,
        delimiter,
        replace,
        layout,
        dictionary,
    })
}

/// The `layout` option (`"row"` | `"column"`).
fn parse_layout(opts: &Json) -> Result<Option<Layout>> {
    match optional_str(opts, "layout")? {
        None => Ok(None),
        Some(l) => Layout::parse(l)
            .map(Some)
            .ok_or_else(|| invalid(format!("unknown layout '{l}'"))),
    }
}

fn parse_save(req: &Json) -> Result<SaveRequest> {
    let table = table_name(req)?;
    let path = required_str(req, "path")?;
    let mut options = SaveOptions::default();
    if let Some(opts) = optional_object(req, "options")? {
        if let Some(n) = optional_uint(opts, "row_group_size")? {
            if n == 0 {
                return Err(invalid("row_group_size must be at least 1"));
            }
            options.row_group_size = usize::try_from(n).unwrap_or(usize::MAX);
        }
        if let Some(e) = optional_str(opts, "encoding")? {
            options.encoding = EncodingChoice::parse(e)
                .ok_or_else(|| invalid(format!("unknown encoding '{e}'")))?;
        }
    }
    Ok(SaveRequest {
        table,
        path,
        options,
    })
}

fn parse_open(req: &Json) -> Result<OpenRequest> {
    let table = table_name(req)?;
    let path = required_str(req, "path")?;
    let (mut mmap, mut layout, mut dictionary) = (false, None, None);
    if let Some(opts) = optional_object(req, "options")? {
        mmap = optional_bool(opts, "mmap")?.unwrap_or(false);
        layout = parse_layout(opts)?;
        dictionary = optional_bool(opts, "dictionary")?;
    }
    Ok(OpenRequest {
        table,
        path,
        mmap,
        layout,
        dictionary,
        replace: optional_bool(req, "replace")?.unwrap_or(false),
    })
}

/// Upper bound for the `threads` query option.
const MAX_QUERY_THREADS: usize = 256;

fn parse_query_options(req: &Json) -> Result<QueryOptions> {
    let mut o = QueryOptions::default();
    let Some(opts) = optional_object(req, "options")? else {
        return Ok(o);
    };
    o.max_rows = optional_uint(opts, "max_rows")?;
    o.timeout_ms = optional_uint(opts, "timeout_ms")?.unwrap_or(0);
    match optional_str(opts, "result")? {
        None | Some("rows") => {}
        Some("count") => o.count_only = true,
        Some(other) => {
            return Err(Error::unsupported(format!(
                "result mode '{other}' is not supported"
            )));
        }
    }
    match optional_str(opts, "mode")? {
        None | Some("auto") => {}
        Some("row") => o.mode = ExecMode::Row,
        Some("vectorized") => o.mode = ExecMode::Vectorized,
        Some(other) => {
            return Err(Error::unsupported(format!(
                "execution mode '{other}' is not supported"
            )));
        }
    }
    match optional_str(opts, "join")? {
        None | Some("auto") => {}
        Some("hash") => o.join = JoinStrategy::Hash,
        Some("merge") => o.join = JoinStrategy::Merge,
        Some("nested_loop") => o.join = JoinStrategy::NestedLoop,
        Some(other) => {
            return Err(Error::unsupported(format!(
                "join algorithm '{other}' is not supported"
            )));
        }
    }
    if let Some(t) = optional_uint(opts, "threads")? {
        if t == 0 {
            return Err(invalid("threads must be at least 1"));
        }
        o.threads = Some(usize::try_from(t).unwrap_or(usize::MAX).min(MAX_QUERY_THREADS));
    }
    if let Some(b) = optional_bool(opts, "optimize")? {
        o.optimize = b;
    }
    if let Some(u) = optional_bool(opts, "use_indexes")? {
        o.use_indexes = u;
    }
    optional_bool(opts, "native")?;
    o.query_id = optional_str(opts, "query_id")?.map(str::to_string);
    Ok(o)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;
    use crate::json::parse;

    fn code(s: &str) -> ErrorCode {
        Request::parse(&parse(s).unwrap(), false).unwrap_err().code
    }

    #[test]
    fn invalid_requests() {
        assert_eq!(code(r#"{"op":"frobnicate"}"#), ErrorCode::InvalidRequest);
        assert_eq!(code(r#"{"op":"query"}"#), ErrorCode::InvalidRequest);
        assert_eq!(
            code(r#"{"op":"query","sql":42}"#),
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            code(r#"{"op":"load","table":"t","format":"xml","path":"a"}"#),
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            code(r#"{"op":"load","table":"t","format":"csv"}"#),
            ErrorCode::InvalidRequest
        );
        assert_eq!(code(r#"{"op":"sleep","ms":5}"#), ErrorCode::InvalidRequest);
        assert_eq!(
            code(r#"{"op":"query","sql":"x","options":{"mode":"quantum"}}"#),
            ErrorCode::Unsupported
        );
        assert_eq!(
            code(r#"{"op":"query","sql":"x","options":{"max_rows":-1}}"#),
            ErrorCode::InvalidRequest
        );
    }

    #[test]
    fn load_with_schema() {
        let r = Request::parse(
            &parse(r#"{"op":"load","table":"t","format":"csv","data":"x\n1\n","schema":[{"name":"x","type":"NUMERIC(4,2)"}],"options":{"delimiter":";"}}"#).unwrap(),
            false,
        )
        .unwrap();
        let Request::Load(l) = r else { panic!() };
        assert_eq!(l.schema.unwrap()[0].data_type, DataType::decimal(4, 2));
        assert_eq!(l.delimiter, b';');
    }
}
