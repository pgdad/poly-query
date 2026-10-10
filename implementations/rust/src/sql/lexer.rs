//! SQL lexer (grammar.md §1).

use crate::error::{Error, Result};
use crate::json::Json;

/// 1-based source position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pos {
    pub line: u32,
    pub column: u32,
}

impl Pos {
    pub fn error(self, err: Error) -> Error {
        err.with_detail("line", Json::uint(self.line as u64)).with_detail("column", Json::uint(self.column as u64))
    }
}

macro_rules! keywords {
    ($($kw:ident),* $(,)?) => {
        /// Reserved keywords.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum Keyword { $($kw),* }

        impl Keyword {
            pub fn lookup(word: &str) -> Option<Keyword> {
                let upper = word.to_ascii_uppercase();
                match upper.as_str() {
                    $(stringify!($kw) => Some(Keyword::$kw),)*
                    _ => None,
                }
            }
            pub fn as_str(self) -> &'static str {
                match self { $(Keyword::$kw => stringify!($kw)),* }
            }
        }
    };
}

#[allow(clippy::upper_case_acronyms)]
mod kw {
    keywords!(
        ALL, AND, AS, ASC, BETWEEN, BY, CASE, CAST, CREATE, CROSS, DATE, DESC, DISTINCT, DROP, ELSE, END, EXISTS,
        EXPLAIN, FALSE, FIRST, FROM, FULL, GROUP, HAVING, IF, IN, INDEX, INNER, IS, JOIN, LAST, LEFT, LIKE, LIMIT,
        NOT, NULL, NULLS, OFFSET, ON, OR, ORDER, OUTER, RIGHT, SELECT, THEN, TIMESTAMP, TRUE, UNION, USING, WHEN,
        WHERE, WITH,
    );
}
pub use kw::Keyword;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Symbol {
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Concat,
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    LParen,
    RParen,
    Comma,
    Dot,
    Semicolon,
}

impl Symbol {
    pub fn as_str(self) -> &'static str {
        match self {
            Symbol::Plus => "+",
            Symbol::Minus => "-",
            Symbol::Star => "*",
            Symbol::Slash => "/",
            Symbol::Percent => "%",
            Symbol::Concat => "||",
            Symbol::Eq => "=",
            Symbol::NotEq => "<>",
            Symbol::Lt => "<",
            Symbol::LtEq => "<=",
            Symbol::Gt => ">",
            Symbol::GtEq => ">=",
            Symbol::LParen => "(",
            Symbol::RParen => ")",
            Symbol::Comma => ",",
            Symbol::Dot => ".",
            Symbol::Semicolon => ";",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    /// Identifier (unquoted or double-quoted).
    Ident { name: String, quoted: bool },
    Keyword(Keyword),
    /// Numeric literal text (digits, optional fraction and exponent).
    Number(String),
    /// String literal content (quotes removed, `''` unescaped).
    Str(String),
    Symbol(Symbol),
    Eof,
}

impl TokenKind {
    pub fn describe(&self) -> String {
        match self {
            TokenKind::Ident { name, .. } => format!("identifier '{name}'"),
            TokenKind::Keyword(k) => format!("keyword {}", k.as_str()),
            TokenKind::Number(n) => format!("number {n}"),
            TokenKind::Str(_) => "string literal".to_string(),
            TokenKind::Symbol(s) => format!("'{}'", s.as_str()),
            TokenKind::Eof => "end of input".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub kind: TokenKind,
    pub pos: Pos,
}

struct Lexer<'a> {
    chars: Vec<char>,
    i: usize,
    line: u32,
    col: u32,
    _src: &'a str,
}

/// Splits SQL text into tokens, ending with `Eof`.
pub fn tokenize(src: &str) -> Result<Vec<Token>> {
    let mut lx = Lexer { chars: src.chars().collect(), i: 0, line: 1, col: 1, _src: src };
    let mut out = Vec::new();
    loop {
        lx.skip_trivia()?;
        let pos = lx.pos();
        let Some(c) = lx.peek(0) else {
            out.push(Token { kind: TokenKind::Eof, pos });
            return Ok(out);
        };
        let kind = if c.is_ascii_alphabetic() || c == '_' {
            let mut word = String::new();
            while let Some(c) = lx.peek(0) {
                if c.is_ascii_alphanumeric() || c == '_' {
                    word.push(c);
                    lx.bump();
                } else {
                    break;
                }
            }
            match Keyword::lookup(&word) {
                Some(k) => TokenKind::Keyword(k),
                None => TokenKind::Ident { name: word, quoted: false },
            }
        } else if c.is_ascii_digit() || (c == '.' && lx.peek(1).is_some_and(|d| d.is_ascii_digit())) {
            lx.number(pos)?
        } else if c == '\'' {
            TokenKind::Str(lx.quoted('\'', pos, "unterminated string literal")?)
        } else if c == '"' {
            let name = lx.quoted('"', pos, "unterminated quoted identifier")?;
            if name.is_empty() {
                return Err(pos.error(Error::parse("empty quoted identifier")));
            }
            TokenKind::Ident { name, quoted: true }
        } else {
            lx.bump();
            let sym = match c {
                '+' => Symbol::Plus,
                '-' => Symbol::Minus,
                '*' => Symbol::Star,
                '/' => Symbol::Slash,
                '%' => Symbol::Percent,
                '(' => Symbol::LParen,
                ')' => Symbol::RParen,
                ',' => Symbol::Comma,
                '.' => Symbol::Dot,
                ';' => Symbol::Semicolon,
                '=' => Symbol::Eq,
                '|' if lx.eat('|') => Symbol::Concat,
                '!' if lx.eat('=') => Symbol::NotEq,
                '<' => {
                    if lx.eat('=') {
                        Symbol::LtEq
                    } else if lx.eat('>') {
                        Symbol::NotEq
                    } else {
                        Symbol::Lt
                    }
                }
                '>' => {
                    if lx.eat('=') {
                        Symbol::GtEq
                    } else {
                        Symbol::Gt
                    }
                }
                _ => return Err(pos.error(Error::parse(format!("unexpected character '{c}'")))),
            };
            TokenKind::Symbol(sym)
        };
        out.push(Token { kind, pos });
    }
}

impl Lexer<'_> {
    fn pos(&self) -> Pos {
        Pos { line: self.line, column: self.col }
    }

    fn peek(&self, k: usize) -> Option<char> {
        self.chars.get(self.i + k).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.chars.get(self.i).copied()?;
        self.i += 1;
        if c == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(c)
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek(0) == Some(c) {
            self.bump();
            true
        } else {
            false
        }
    }

    fn skip_trivia(&mut self) -> Result<()> {
        loop {
            match self.peek(0) {
                Some(' ' | '\t' | '\r' | '\n') => {
                    self.bump();
                }
                Some('-') if self.peek(1) == Some('-') => {
                    while let Some(c) = self.peek(0) {
                        if c == '\n' {
                            break;
                        }
                        self.bump();
                    }
                }
                Some('/') if self.peek(1) == Some('*') => {
                    let pos = self.pos();
                    self.bump();
                    self.bump();
                    loop {
                        match self.peek(0) {
                            None => return Err(pos.error(Error::parse("unterminated block comment"))),
                            Some('*') if self.peek(1) == Some('/') => {
                                self.bump();
                                self.bump();
                                break;
                            }
                            Some(_) => {
                                self.bump();
                            }
                        }
                    }
                }
                _ => return Ok(()),
            }
        }
    }

    fn digits(&mut self, text: &mut String) -> usize {
        let mut n = 0;
        while let Some(c) = self.peek(0) {
            if c.is_ascii_digit() {
                text.push(c);
                self.bump();
                n += 1;
            } else {
                break;
            }
        }
        n
    }

    fn number(&mut self, pos: Pos) -> Result<TokenKind> {
        let mut text = String::new();
        self.digits(&mut text);
        if self.peek(0) == Some('.') {
            text.push('.');
            self.bump();
            self.digits(&mut text);
        }
        if matches!(self.peek(0), Some('e' | 'E')) {
            let has_exp = match self.peek(1) {
                Some(d) if d.is_ascii_digit() => true,
                Some('+' | '-') => self.peek(2).is_some_and(|d| d.is_ascii_digit()),
                _ => false,
            };
            if has_exp {
                text.push(self.bump().unwrap_or('e'));
                if matches!(self.peek(0), Some('+' | '-')) {
                    text.push(self.bump().unwrap_or('+'));
                }
                self.digits(&mut text);
            }
        }
        if self.peek(0).is_some_and(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.') {
            return Err(pos.error(Error::parse(format!("malformed numeric literal near '{text}'"))));
        }
        Ok(TokenKind::Number(text))
    }

    fn quoted(&mut self, q: char, pos: Pos, unterminated: &str) -> Result<String> {
        self.bump();
        let mut s = String::new();
        loop {
            match self.bump() {
                None => return Err(pos.error(Error::parse(unterminated))),
                Some(c) if c == q => {
                    if self.peek(0) == Some(q) {
                        self.bump();
                        s.push(q);
                    } else {
                        return Ok(s);
                    }
                }
                Some(c) => s.push(c),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(s: &str) -> Vec<TokenKind> {
        tokenize(s).unwrap().into_iter().map(|t| t.kind).collect()
    }

    #[test]
    fn basic_tokens() {
        let k = kinds("SELECT a1, 'it''s', \"Q \"\"x\"\"\" FROM t -- c\n WHERE x<>1.5e3 /* b */ || .5");
        assert_eq!(k[0], TokenKind::Keyword(Keyword::SELECT));
        assert_eq!(k[1], TokenKind::Ident { name: "a1".into(), quoted: false });
        assert_eq!(k[3], TokenKind::Str("it's".into()));
        assert_eq!(k[5], TokenKind::Ident { name: "Q \"x\"".into(), quoted: true });
        assert!(k.contains(&TokenKind::Symbol(Symbol::NotEq)));
        assert!(k.contains(&TokenKind::Number("1.5e3".into())));
        assert!(k.contains(&TokenKind::Number(".5".into())));
        assert!(k.contains(&TokenKind::Symbol(Symbol::Concat)));
    }

    #[test]
    fn positions() {
        let t = tokenize("SELECT\n  x").unwrap();
        assert_eq!(t[1].pos, Pos { line: 2, column: 3 });
    }

    #[test]
    fn errors() {
        assert!(tokenize("'abc").is_err());
        assert!(tokenize("/* abc").is_err());
        assert!(tokenize("a @ b").is_err());
        assert!(tokenize("1abc").is_err());
    }

    #[test]
    fn number_followed_by_dot() {
        assert_eq!(kinds("3.")[0], TokenKind::Number("3.".into()));
    }
}
