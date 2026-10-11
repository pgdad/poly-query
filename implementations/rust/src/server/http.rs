//! Minimal HTTP/1.1 message handling (RFC 9112 subset): request parsing with
//! `Content-Length` and chunked bodies, `Expect: 100-continue`, keep-alive,
//! and response writing (fixed-length and chunked).

use std::io::{self, BufRead, Read, Write};

/// Maximum size of the request line plus headers.
const MAX_HEAD_BYTES: usize = 64 * 1024;
/// Maximum number of header fields.
const MAX_HEADERS: usize = 128;
/// Maximum number of bytes of an over-limit body that are read and discarded
/// before responding (so the client sees the response rather than a reset).
const DRAIN_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug)]
pub struct Request {
    pub method: String,
    /// Percent-decoded path segments (without the empty leading segment).
    pub segments: Vec<String>,
    /// Decoded query-string parameters, in order.
    pub params: Vec<(String, String)>,
    /// Header fields with lowercased names.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// Whether the connection may be reused after the response.
    pub keep_alive: bool,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn param(&self, name: &str) -> Option<&str> {
        self.params
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

/// Why no request could be read.
#[derive(Debug)]
pub enum ReadError {
    /// The peer closed the connection (or it failed) between requests.
    Closed,
    /// The request is malformed; respond 400 and close.
    BadRequest(String),
    /// The body exceeds the configured limit; respond 413 and close.
    TooLarge,
}

impl From<io::Error> for ReadError {
    fn from(_: io::Error) -> Self {
        ReadError::Closed
    }
}

/// Reads one line terminated by LF (CR LF accepted), bounded by `budget`.
fn read_line(reader: &mut impl BufRead, budget: &mut usize) -> Result<Option<String>, ReadError> {
    let mut buf = Vec::new();
    let n = reader
        .by_ref()
        .take(*budget as u64 + 1)
        .read_until(b'\n', &mut buf)?;
    if n == 0 {
        return Ok(None);
    }
    if n > *budget {
        return Err(ReadError::BadRequest("request head too large".into()));
    }
    *budget -= n;
    if buf.last() != Some(&b'\n') {
        // EOF in the middle of a line.
        return Err(ReadError::Closed);
    }
    buf.pop();
    if buf.last() == Some(&b'\r') {
        buf.pop();
    }
    String::from_utf8(buf)
        .map(Some)
        .map_err(|_| ReadError::BadRequest("request head is not valid UTF-8".into()))
}

/// Reads the next request from a connection. `Ok(None)` means the peer closed
/// the connection cleanly before starting a new request. `writer` is used to
/// send `100 Continue` when the client asks for it.
pub fn read_request(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    max_body: u64,
) -> Result<Option<Request>, ReadError> {
    let mut budget = MAX_HEAD_BYTES;
    // Tolerate empty lines before the request line (RFC 9112 §2.2).
    let line = loop {
        match read_line(reader, &mut budget)? {
            None => return Ok(None),
            Some(l) if l.is_empty() => continue,
            Some(l) => break l,
        }
    };
    let mut parts = line.split(' ');
    let (Some(method), Some(target), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(ReadError::BadRequest("malformed request line".into()));
    };
    let http11 = match version {
        "HTTP/1.1" => true,
        "HTTP/1.0" => false,
        _ => return Err(ReadError::BadRequest("unsupported HTTP version".into())),
    };
    if method.is_empty() || !method.bytes().all(|b| b.is_ascii_uppercase()) {
        return Err(ReadError::BadRequest("malformed method".into()));
    }
    let mut headers = Vec::new();
    loop {
        let Some(h) = read_line(reader, &mut budget)? else {
            return Err(ReadError::Closed);
        };
        if h.is_empty() {
            break;
        }
        let Some((name, value)) = h.split_once(':') else {
            return Err(ReadError::BadRequest("malformed header field".into()));
        };
        if name.is_empty() || name.ends_with([' ', '\t']) {
            return Err(ReadError::BadRequest("malformed header field".into()));
        }
        if headers.len() >= MAX_HEADERS {
            return Err(ReadError::BadRequest("too many header fields".into()));
        }
        headers.push((name.to_ascii_lowercase(), value.trim().to_string()));
    }
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };
    if !path.starts_with('/') {
        return Err(ReadError::BadRequest(
            "request target must be a path".into(),
        ));
    }
    let segments = path[1..]
        .split('/')
        .map(|s| percent_decode(s, false))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| ReadError::BadRequest("malformed percent-encoding in path".into()))?;
    let params = query
        .split('&')
        .filter(|kv| !kv.is_empty())
        .map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            Some((percent_decode(k, true)?, percent_decode(v, true)?))
        })
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| ReadError::BadRequest("malformed percent-encoding in query".into()))?;
    let mut req = Request {
        method: method.to_string(),
        segments,
        params,
        headers,
        body: Vec::new(),
        keep_alive: false,
    };
    let connection = req.header("connection").unwrap_or("").to_ascii_lowercase();
    let has = |token: &str| connection.split(',').any(|t| t.trim() == token);
    req.keep_alive = if http11 {
        !has("close")
    } else {
        has("keep-alive")
    };
    req.body = read_body(&req, reader, writer, max_body)?;
    Ok(Some(req))
}

fn read_body(
    req: &Request,
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    max_body: u64,
) -> Result<Vec<u8>, ReadError> {
    let chunked = match req.header("transfer-encoding") {
        None => false,
        Some(te) if te.eq_ignore_ascii_case("chunked") => true,
        Some(_) => {
            return Err(ReadError::BadRequest(
                "unsupported transfer encoding".into(),
            ));
        }
    };
    let length = match req.header("content-length") {
        Some(_) if chunked => {
            return Err(ReadError::BadRequest(
                "both Content-Length and Transfer-Encoding given".into(),
            ));
        }
        Some(v) => Some(
            v.parse::<u64>()
                .map_err(|_| ReadError::BadRequest("invalid Content-Length".into()))?,
        ),
        None => None,
    };
    if !chunked && length.unwrap_or(0) == 0 {
        return Ok(Vec::new());
    }
    let expects_continue = req
        .header("expect")
        .is_some_and(|e| e.eq_ignore_ascii_case("100-continue"));
    if let Some(n) = length
        && n > max_body
    {
        if !expects_continue {
            drain(reader, n.min(DRAIN_BYTES));
        }
        return Err(ReadError::TooLarge);
    }
    if expects_continue {
        writer.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
        writer.flush()?;
    }
    if let Some(n) = length {
        let mut body = Vec::with_capacity(usize::try_from(n.min(1 << 20)).unwrap_or(0));
        reader.by_ref().take(n).read_to_end(&mut body)?;
        if (body.len() as u64) < n {
            return Err(ReadError::Closed);
        }
        return Ok(body);
    }
    read_chunked(reader, max_body)
}

/// Decodes a chunked request body (chunk extensions and trailers ignored).
/// Once the body exceeds `max_body` the remaining chunks are decoded and
/// discarded (so the client can read the 413 response), up to
/// `DRAIN_BYTES`.
fn read_chunked(reader: &mut impl BufRead, max_body: u64) -> Result<Vec<u8>, ReadError> {
    let mut body = Vec::new();
    let mut total: u64 = 0;
    loop {
        let mut budget = MAX_HEAD_BYTES;
        let line = read_line(reader, &mut budget)?.ok_or(ReadError::Closed)?;
        let size_text = line.split(';').next().unwrap_or("").trim();
        let size = u64::from_str_radix(size_text, 16)
            .map_err(|_| ReadError::BadRequest("invalid chunk size".into()))?;
        if size == 0 {
            // Trailer fields up to the empty line.
            loop {
                match read_line(reader, &mut budget)? {
                    Some(l) if !l.is_empty() => continue,
                    _ if total > max_body => return Err(ReadError::TooLarge),
                    _ => return Ok(body),
                }
            }
        }
        total = total.saturating_add(size);
        if total > max_body {
            if total > max_body.saturating_add(DRAIN_BYTES) {
                return Err(ReadError::TooLarge);
            }
            body = Vec::new();
            let skipped = io::copy(&mut reader.by_ref().take(size), &mut io::sink())?;
            if skipped != size {
                return Err(ReadError::Closed);
            }
        } else {
            let before = body.len();
            reader.by_ref().take(size).read_to_end(&mut body)?;
            if (body.len() - before) as u64 != size {
                return Err(ReadError::Closed);
            }
        }
        let mut crlf = [0u8; 2];
        reader.read_exact(&mut crlf)?;
        if &crlf != b"\r\n" {
            return Err(ReadError::BadRequest("malformed chunk".into()));
        }
    }
}

/// Reads and discards up to `limit` bytes.
fn drain(reader: &mut impl BufRead, limit: u64) {
    let _ = io::copy(&mut reader.by_ref().take(limit), &mut io::sink());
}

/// Decodes `%XX` escapes (and `+` as space in query strings).
fn percent_decode(s: &str, plus_is_space: bool) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = s.get(i + 1..i + 3)?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' if plus_is_space => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

pub fn reason_phrase(status: u16) -> &'static str {
    match status {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Unknown",
    }
}

/// A complete (non-streamed) response.
#[derive(Debug)]
pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

pub const JSON: &str = "application/json";

impl Response {
    pub fn json(status: u16, body: String) -> Response {
        Response {
            status,
            content_type: JSON,
            headers: Vec::new(),
            body: body.into_bytes(),
        }
    }

    pub fn with_header(mut self, name: &'static str, value: impl Into<String>) -> Response {
        self.headers.push((name, value.into()));
        self
    }
}

fn head(
    status: u16,
    content_type: &str,
    headers: &[(&'static str, String)],
    keep_alive: bool,
) -> String {
    let mut out = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: {content_type}\r\n",
        reason_phrase(status)
    );
    for (k, v) in headers {
        out.push_str(k);
        out.push_str(": ");
        out.push_str(v);
        out.push_str("\r\n");
    }
    out.push_str(if keep_alive {
        "Connection: keep-alive\r\n"
    } else {
        "Connection: close\r\n"
    });
    out
}

/// Writes a complete response in one piece.
pub fn write_response(out: &mut impl Write, resp: &Response, keep_alive: bool) -> io::Result<()> {
    let mut msg = head(resp.status, resp.content_type, &resp.headers, keep_alive);
    msg.push_str(&format!("Content-Length: {}\r\n\r\n", resp.body.len()));
    let mut bytes = msg.into_bytes();
    bytes.extend_from_slice(&resp.body);
    out.write_all(&bytes)?;
    out.flush()
}

/// Starts a response with `Transfer-Encoding: chunked`: status line and headers.
pub fn write_chunked_head(
    out: &mut impl Write,
    status: u16,
    content_type: &str,
    headers: &[(&'static str, String)],
    keep_alive: bool,
) -> io::Result<()> {
    let mut msg = head(status, content_type, headers, keep_alive);
    msg.push_str("Transfer-Encoding: chunked\r\n\r\n");
    out.write_all(msg.as_bytes())
}

/// Writes one chunk (empty data is skipped: it would end the body).
pub fn write_chunk(out: &mut impl Write, data: &[u8]) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    let mut msg = format!("{:x}\r\n", data.len()).into_bytes();
    msg.extend_from_slice(data);
    msg.extend_from_slice(b"\r\n");
    out.write_all(&msg)?;
    out.flush()
}

/// Writes the last chunk, ending the body.
pub fn write_last_chunk(out: &mut impl Write) -> io::Result<()> {
    out.write_all(b"0\r\n\r\n")?;
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufReader;

    fn parse(raw: &str, max: u64) -> Result<Option<Request>, ReadError> {
        let mut r = BufReader::new(raw.as_bytes());
        read_request(&mut r, &mut Vec::new(), max)
    }

    #[test]
    fn parses_request_with_body_and_query() {
        let req = parse(
            "PUT /v1/tables/my%20t?format=csv&replace=true HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\na\n1\n",
            100,
        )
        .unwrap()
        .unwrap();
        assert_eq!(req.method, "PUT");
        assert_eq!(req.segments, vec!["v1", "tables", "my t"]);
        assert_eq!(req.param("format"), Some("csv"));
        assert_eq!(req.param("replace"), Some("true"));
        assert_eq!(req.body, b"a\n1\n");
        assert!(req.keep_alive);
    }

    #[test]
    fn chunked_body_and_connection_close() {
        let req = parse(
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\n\r\n",
            100,
        )
        .unwrap()
        .unwrap();
        assert_eq!(req.body, b"abcde");
        assert!(!req.keep_alive);
    }

    #[test]
    fn limits_and_errors() {
        assert!(matches!(
            parse(
                "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789",
                5
            ),
            Err(ReadError::TooLarge)
        ));
        assert!(matches!(
            parse(
                "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n",
                5
            ),
            Err(ReadError::TooLarge)
        ));
        assert!(matches!(
            parse("GARBAGE\r\n\r\n", 5),
            Err(ReadError::BadRequest(_))
        ));
        assert!(matches!(parse("", 5), Ok(None)));
        let req = parse("GET /health HTTP/1.0\r\n\r\n", 5).unwrap().unwrap();
        assert!(!req.keep_alive);
    }
}
