//! Key interning for hash-based operators (aggregation, DISTINCT, joins).
//!
//! An [`Interner`] maps the values of one key column to dense ids (`0..n`,
//! in first-seen order). It specializes on the column representation:
//! fixed-width values (INT64, DATE, TIMESTAMP, BOOLEAN, DECIMAL of one scale)
//! hash as `i64`, strings as `str`, and dictionary-encoded strings are
//! resolved once per dictionary code. Anything else uses `Value` keys, whose
//! equality and hashing follow the grouping rules of types.md §7.
//!
//! A [`KeyTable`] combines the per-column ids of a multi-column key into one
//! dense group id (one key: the column id itself; two: a packed `u64`;
//! more: a boxed id tuple), so the hash tables of all operators are flat
//! maps of small integer keys.

use std::sync::{Arc, OnceLock};

use std::hash::{Hash, Hasher};

use super::batch::{Data, NO_ROW, Vector};
use crate::exec::hash::{FastHasher, FastMap};
use crate::types::Value;

/// Representation class of `i64`-keyed values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Int,
    Bool,
    Date,
    Ts,
    Dec(u8),
}

impl Class {
    fn of(data: &Data) -> Option<Class> {
        Some(match data {
            Data::Int(_) => Class::Int,
            Data::Bool(_) => Class::Bool,
            Data::Date(_) => Class::Date,
            Data::Timestamp(_) => Class::Ts,
            Data::Decimal(_, s) => Class::Dec(*s),
            _ => return None,
        })
    }

    fn of_value(v: &Value) -> Option<(Class, i64)> {
        Some(match v {
            Value::Int(i) => (Class::Int, *i),
            Value::Bool(b) => (Class::Bool, *b as i64),
            Value::Date(d) => (Class::Date, *d as i64),
            Value::Timestamp(t) => (Class::Ts, *t),
            Value::Decimal(u, s) => (Class::Dec(*s), *u),
            _ => return None,
        })
    }

    fn value(self, x: i64) -> Value {
        match self {
            Class::Int => Value::Int(x),
            Class::Bool => Value::Bool(x != 0),
            Class::Date => Value::Date(x as i32),
            Class::Ts => Value::Timestamp(x),
            Class::Dec(s) => Value::Decimal(x, s),
        }
    }
}

/// Reads element `i` of a fixed-width vector as i64.
#[inline]
fn i64_at(data: &Data, i: usize) -> i64 {
    match data {
        Data::Int(v) | Data::Timestamp(v) | Data::Decimal(v, _) => v[i],
        Data::Date(v) => v[i] as i64,
        Data::Bool(v) => v[i] as i64,
        _ => 0,
    }
}

#[derive(Debug)]
enum Map {
    Empty,
    I64(Class, FastMap<i64, u32>),
    Str(FastMap<Arc<str>, u32>),
    Generic(FastMap<Value, u32>),
}

/// Per-caller cache of dictionary code → id resolutions.
#[derive(Debug, Default)]
pub struct DictCache {
    dict: Option<Arc<[Arc<str>]>>,
    ids: Vec<u32>,
}

impl DictCache {
    fn for_dict(&mut self, dict: &Arc<[Arc<str>]>) -> &mut Vec<u32> {
        if !self.dict.as_ref().is_some_and(|d| Arc::ptr_eq(d, dict)) {
            self.dict = Some(dict.clone());
            self.ids.clear();
            self.ids.resize(dict.len(), NO_ROW);
        }
        &mut self.ids
    }
}

const UNKNOWN: u32 = NO_ROW - 1;

/// The id of NULL, allocated (in first-seen order) on first use.
fn null_id(values: &mut Vec<Value>, null: &mut Option<u32>) -> u32 {
    *null.get_or_insert_with(|| {
        values.push(Value::Null);
        (values.len() - 1) as u32
    })
}

/// Dense ids for the distinct values of one key column.
#[derive(Debug)]
pub struct Interner {
    map: Map,
    /// Value of each id (NULL included, at `null_id`).
    values: Vec<Value>,
    null_id: Option<u32>,
    cache: DictCache,
    /// `Value`-keyed view for lookups whose representation differs from
    /// the specialized map (built on first need).
    generic: OnceLock<FastMap<Value, u32>>,
}

impl Default for Interner {
    fn default() -> Self {
        Interner {
            map: Map::Empty,
            values: Vec::new(),
            null_id: None,
            cache: DictCache::default(),
            generic: OnceLock::new(),
        }
    }
}

impl Interner {
    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn value(&self, id: u32) -> &Value {
        &self.values[id as usize]
    }

    fn null(&mut self) -> u32 {
        null_id(&mut self.values, &mut self.null_id)
    }

    /// Switches to `Value` keys (when a representation does not fit).
    fn switch_to_generic(&mut self) {
        if matches!(self.map, Map::Generic(_)) {
            return;
        }
        let mut map = FastMap::default();
        for (id, v) in self.values.iter().enumerate() {
            if !v.is_null() {
                map.insert(v.clone(), id as u32);
            }
        }
        self.map = Map::Generic(map);
        self.cache = DictCache::default();
    }

    /// Id of `v`, inserting it if new.
    pub fn intern_value(&mut self, v: &Value) -> u32 {
        if v.is_null() {
            return self.null();
        }
        let next = self.values.len() as u32;
        if let Map::Empty = self.map {
            self.map = match Class::of_value(v) {
                Some((c, _)) => Map::I64(c, FastMap::default()),
                None if matches!(v, Value::Str(_)) => Map::Str(FastMap::default()),
                None => Map::Generic(FastMap::default()),
            };
        }
        let id = match (&mut self.map, v) {
            (Map::I64(class, map), _) => match Class::of_value(v) {
                Some((c, x)) if c == *class => *map.entry(x).or_insert(next),
                _ => {
                    self.switch_to_generic();
                    return self.intern_value(v);
                }
            },
            (Map::Str(map), Value::Str(s)) => match map.get(&**s) {
                Some(&id) => id,
                None => {
                    map.insert(s.clone(), next);
                    next
                }
            },
            (Map::Str(_), _) => {
                self.switch_to_generic();
                return self.intern_value(v);
            }
            (Map::Generic(map), _) => *map.entry(v.clone()).or_insert(next),
            (Map::Empty, _) => unreachable!(),
        };
        if id == next {
            self.values.push(v.clone());
        }
        id
    }

    /// Ids of all elements of `v` (inserting new values).
    pub fn intern(&mut self, v: &Vector, out: &mut Vec<u32>) {
        out.clear();
        let n = v.len();
        if let Data::Null = v.data {
            let id = self.null();
            out.resize(n, id);
            return;
        }
        if let Map::Empty = self.map {
            self.map = match Class::of(&v.data) {
                Some(c) => Map::I64(c, FastMap::default()),
                None if matches!(v.data, Data::Str(_) | Data::Dict(..)) => {
                    Map::Str(FastMap::default())
                }
                None => Map::Generic(FastMap::default()),
            };
        }
        let fits = match (&self.map, &v.data) {
            (Map::I64(c, _), d) => Class::of(d) == Some(*c),
            (Map::Str(_), Data::Str(_) | Data::Dict(..)) => true,
            (Map::Generic(_), _) => true,
            _ => false,
        };
        if !fits {
            self.switch_to_generic();
        }
        let valid = v.valid.as_deref();
        match (&mut self.map, &v.data) {
            (Map::I64(class, map), d) => {
                let class = *class;
                for i in 0..n {
                    if valid.is_some_and(|ok| !ok[i]) {
                        out.push(null_id(&mut self.values, &mut self.null_id));
                        continue;
                    }
                    let x = i64_at(d, i);
                    let next = self.values.len() as u32;
                    let id = *map.entry(x).or_insert(next);
                    if id == next {
                        self.values.push(class.value(x));
                    }
                    out.push(id);
                }
            }
            (Map::Str(map), Data::Str(s)) => {
                for i in 0..n {
                    if valid.is_some_and(|ok| !ok[i]) {
                        out.push(null_id(&mut self.values, &mut self.null_id));
                        continue;
                    }
                    let id = match map.get(&*s[i]) {
                        Some(&id) => id,
                        None => {
                            let id = self.values.len() as u32;
                            map.insert(s[i].clone(), id);
                            self.values.push(Value::Str(s[i].clone()));
                            id
                        }
                    };
                    out.push(id);
                }
            }
            (Map::Str(map), Data::Dict(codes, dict)) => {
                let ids = self.cache.for_dict(dict);
                for i in 0..n {
                    if valid.is_some_and(|ok| !ok[i]) {
                        out.push(null_id(&mut self.values, &mut self.null_id));
                        continue;
                    }
                    let code = codes[i] as usize;
                    let mut id = ids[code];
                    if id == NO_ROW {
                        let s = &dict[code];
                        id = match map.get(&**s) {
                            Some(&id) => id,
                            None => {
                                let id = self.values.len() as u32;
                                map.insert(s.clone(), id);
                                self.values.push(Value::Str(s.clone()));
                                id
                            }
                        };
                        ids[code] = id;
                    }
                    out.push(id);
                }
            }
            (Map::Generic(map), _) => {
                for i in 0..n {
                    let x = v.value(i);
                    if x.is_null() {
                        out.push(null_id(&mut self.values, &mut self.null_id));
                        continue;
                    }
                    let next = self.values.len() as u32;
                    let id = *map.entry(x.clone()).or_insert(next);
                    if id == next {
                        self.values.push(x);
                    }
                    out.push(id);
                }
            }
            _ => unreachable!(),
        }
    }

    fn generic_map(&self) -> &FastMap<Value, u32> {
        self.generic.get_or_init(|| {
            self.values
                .iter()
                .enumerate()
                .filter(|(_, v)| !v.is_null())
                .map(|(id, v)| (v.clone(), id as u32))
                .collect()
        })
    }

    /// Id of `v` without inserting (`NO_ROW` if absent or NULL).
    pub fn lookup_value(&self, v: &Value) -> u32 {
        if v.is_null() {
            return NO_ROW;
        }
        let found = match (&self.map, v) {
            (Map::I64(class, map), _) => match Class::of_value(v) {
                Some((c, x)) if c == *class => map.get(&x).copied(),
                _ => self.generic_map().get(v).copied(),
            },
            (Map::Str(map), Value::Str(s)) => map.get(&**s).copied(),
            (Map::Generic(map), _) => map.get(v).copied(),
            _ => self.generic_map().get(v).copied(),
        };
        found.unwrap_or(NO_ROW)
    }

    /// Ids of the elements of `v` without inserting; NULLs and unknown
    /// values get `NO_ROW`.
    pub fn lookup(&self, v: &Vector, out: &mut Vec<u32>, cache: &mut DictCache) {
        out.clear();
        let n = v.len();
        let valid = v.valid.as_deref();
        match (&self.map, &v.data) {
            (_, Data::Null) | (Map::Empty, _) => out.resize(n, NO_ROW),
            (Map::I64(class, map), d) if Class::of(d) == Some(*class) => {
                for i in 0..n {
                    let id = if valid.is_some_and(|ok| !ok[i]) {
                        NO_ROW
                    } else {
                        map.get(&i64_at(d, i)).copied().unwrap_or(NO_ROW)
                    };
                    out.push(id);
                }
            }
            (Map::Str(map), Data::Str(s)) => {
                for i in 0..n {
                    let id = if valid.is_some_and(|ok| !ok[i]) {
                        NO_ROW
                    } else {
                        map.get(&*s[i]).copied().unwrap_or(NO_ROW)
                    };
                    out.push(id);
                }
            }
            (Map::Str(map), Data::Dict(codes, dict)) => {
                let ids = cache.for_dict(dict);
                for i in 0..n {
                    if valid.is_some_and(|ok| !ok[i]) {
                        out.push(NO_ROW);
                        continue;
                    }
                    let code = codes[i] as usize;
                    let mut id = ids[code];
                    if id == NO_ROW {
                        id = map.get(&*dict[code]).copied().unwrap_or(UNKNOWN);
                        ids[code] = id;
                    }
                    out.push(if id == UNKNOWN { NO_ROW } else { id });
                }
            }
            _ => {
                for i in 0..n {
                    out.push(self.lookup_value(&v.value(i)));
                }
            }
        }
    }
}

#[derive(Debug)]
enum Composite {
    /// No key columns: a single group.
    Zero,
    /// One key column: the group id is the column's id.
    One,
    Two(FastMap<u64, u32>),
    Many(FastMap<Box<[u32]>, u32>),
}

/// Dense group ids for multi-column keys.
#[derive(Debug)]
pub struct KeyTable {
    interners: Vec<Interner>,
    composite: Composite,
    /// Column ids of each group (`width` per group; for 2+ columns).
    group_ids: Vec<u32>,
    groups: usize,
    /// Scratch id buffers per column.
    scratch: Vec<Vec<u32>>,
}

impl KeyTable {
    pub fn new(width: usize) -> KeyTable {
        KeyTable {
            interners: (0..width).map(|_| Interner::default()).collect(),
            composite: match width {
                0 => Composite::Zero,
                1 => Composite::One,
                2 => Composite::Two(FastMap::default()),
                _ => Composite::Many(FastMap::default()),
            },
            group_ids: Vec::new(),
            groups: 0,
            scratch: vec![Vec::new(); width],
        }
    }

    /// Number of distinct keys seen.
    pub fn len(&self) -> usize {
        match self.composite {
            Composite::One => self.interners[0].len(),
            _ => self.groups,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn width(&self) -> usize {
        self.interners.len()
    }

    /// Group id of every row of the key vectors (`n` rows), inserting new
    /// keys in first-seen order.
    pub fn assign(&mut self, keys: &[Vector], n: usize, out: &mut Vec<u32>) {
        out.clear();
        match &mut self.composite {
            Composite::Zero => {
                self.groups = 1;
                out.resize(n, 0);
            }
            Composite::One => self.interners[0].intern(&keys[0], out),
            Composite::Two(map) => {
                let (a, b) = self.scratch.split_at_mut(1);
                self.interners[0].intern(&keys[0], &mut a[0]);
                self.interners[1].intern(&keys[1], &mut b[0]);
                for i in 0..n {
                    let k = ((a[0][i] as u64) << 32) | b[0][i] as u64;
                    let next = self.groups as u32;
                    let g = *map.entry(k).or_insert(next);
                    if g == next {
                        self.groups += 1;
                        self.group_ids.push(a[0][i]);
                        self.group_ids.push(b[0][i]);
                    }
                    out.push(g);
                }
            }
            Composite::Many(map) => {
                for (c, interner) in self.interners.iter_mut().enumerate() {
                    interner.intern(&keys[c], &mut self.scratch[c]);
                }
                let w = self.interners.len();
                let mut key = vec![0u32; w];
                for i in 0..n {
                    for (k, ids) in key.iter_mut().zip(&self.scratch) {
                        *k = ids[i];
                    }
                    let next = self.groups as u32;
                    let g = match map.get(key.as_slice()) {
                        Some(&g) => g,
                        None => {
                            map.insert(key.clone().into_boxed_slice(), next);
                            self.groups += 1;
                            self.group_ids.extend_from_slice(&key);
                            next
                        }
                    };
                    out.push(g);
                }
            }
        }
    }

    /// Group id of a key given as values (inserting it if new).
    pub fn assign_values(&mut self, key: &[Value]) -> u32 {
        match self.composite {
            Composite::Zero => {
                self.groups = 1;
                0
            }
            Composite::One => self.interners[0].intern_value(&key[0]),
            _ => {
                let ids: Vec<u32> = self
                    .interners
                    .iter_mut()
                    .zip(key)
                    .map(|(i, v)| i.intern_value(v))
                    .collect();
                self.assign_ids(&ids)
            }
        }
    }

    /// Key id of every row without inserting: `NO_ROW` if any key column
    /// is NULL or the key is unknown (join probing).
    pub fn lookup(&self, keys: &[Vector], n: usize, out: &mut Vec<u32>, caches: &mut [DictCache]) {
        out.clear();
        match &self.composite {
            Composite::Zero => out.resize(n, if self.groups > 0 { 0 } else { NO_ROW }),
            Composite::One => self.interners[0].lookup(&keys[0], out, &mut caches[0]),
            Composite::Two(map) => {
                let mut a = Vec::new();
                let mut b = Vec::new();
                self.interners[0].lookup(&keys[0], &mut a, &mut caches[0]);
                self.interners[1].lookup(&keys[1], &mut b, &mut caches[1]);
                for i in 0..n {
                    out.push(if a[i] == NO_ROW || b[i] == NO_ROW {
                        NO_ROW
                    } else {
                        let k = ((a[i] as u64) << 32) | b[i] as u64;
                        map.get(&k).copied().unwrap_or(NO_ROW)
                    });
                }
            }
            Composite::Many(map) => {
                let w = self.interners.len();
                let mut ids: Vec<Vec<u32>> = vec![Vec::new(); w];
                for (c, interner) in self.interners.iter().enumerate() {
                    interner.lookup(&keys[c], &mut ids[c], &mut caches[c]);
                }
                let mut key = vec![0u32; w];
                for i in 0..n {
                    let mut missing = false;
                    for (k, col) in key.iter_mut().zip(&ids) {
                        *k = col[i];
                        missing |= *k == NO_ROW;
                    }
                    out.push(if missing {
                        NO_ROW
                    } else {
                        map.get(key.as_slice()).copied().unwrap_or(NO_ROW)
                    });
                }
            }
        }
    }

    /// Value of key column `c` of group `g`.
    pub fn key_value(&self, g: u32, c: usize) -> &Value {
        match self.composite {
            Composite::One => self.interners[0].value(g),
            _ => {
                let w = self.interners.len();
                self.interners[c].value(self.group_ids[g as usize * w + c])
            }
        }
    }

    /// Hash of the key of group `g` (consistent across tables: it hashes
    /// the key values).
    pub fn hash_key(&self, g: u32) -> u64 {
        let mut h = FastHasher::default();
        for c in 0..self.width() {
            self.key_value(g, c).hash(&mut h);
        }
        h.finish()
    }

    /// Group id here of group `g` of `other` (same key columns), inserting
    /// it if new.
    pub fn assign_from(&mut self, other: &KeyTable, g: u32) -> u32 {
        match self.composite {
            Composite::Zero => {
                self.groups = 1;
                0
            }
            Composite::One => self.interners[0].intern_value(other.key_value(g, 0)),
            Composite::Two(_) => {
                let a = self.interners[0].intern_value(other.key_value(g, 0));
                let b = self.interners[1].intern_value(other.key_value(g, 1));
                self.assign_ids(&[a, b])
            }
            Composite::Many(_) => {
                let ids: Vec<u32> = (0..self.width())
                    .map(|c| self.interners[c].intern_value(other.key_value(g, c)))
                    .collect();
                self.assign_ids(&ids)
            }
        }
    }

    /// Group id of the per-column ids `ids` (2+ key columns), inserting it.
    fn assign_ids(&mut self, ids: &[u32]) -> u32 {
        let next = self.groups as u32;
        let g = match &mut self.composite {
            Composite::Two(map) => *map
                .entry(((ids[0] as u64) << 32) | ids[1] as u64)
                .or_insert(next),
            Composite::Many(map) => match map.get(ids) {
                Some(&g) => g,
                None => {
                    map.insert(ids.into(), next);
                    next
                }
            },
            Composite::Zero | Composite::One => unreachable!("single-column keys use the interner"),
        };
        if g == next {
            self.groups += 1;
            self.group_ids.extend_from_slice(ids);
        }
        g
    }

    /// The key values of group `g`.
    pub fn key(&self, g: u32) -> Vec<Value> {
        match self.composite {
            Composite::Zero => Vec::new(),
            Composite::One => vec![self.interners[0].value(g).clone()],
            _ => {
                let w = self.interners.len();
                let ids = &self.group_ids[g as usize * w..(g as usize + 1) * w];
                ids.iter()
                    .zip(&self.interners)
                    .map(|(&id, i)| i.value(id).clone())
                    .collect()
            }
        }
    }

    /// The key columns of all groups, as vectors.
    pub fn key_vectors(&self) -> Vec<Vector> {
        let n = self.len();
        (0..self.width())
            .map(|c| {
                let values = (0..n as u32)
                    .map(|g| match self.composite {
                        Composite::One => self.interners[0].value(g).clone(),
                        _ => {
                            let w = self.width();
                            self.interners[c]
                                .value(self.group_ids[g as usize * w + c])
                                .clone()
                        }
                    })
                    .collect();
                Vector::from_values(values)
            })
            .collect()
    }

    /// Approximate memory held (for accounting).
    pub fn approx_size(&self) -> usize {
        let values: usize = self
            .interners
            .iter()
            .map(|i| i.values.iter().map(|v| v.approx_size() + 16).sum::<usize>())
            .sum();
        values + self.group_ids.len() * 4 + self.groups * 16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interning_and_lookup() {
        let mut t = KeyTable::new(2);
        let a = Vector::from_values(vec![
            Value::Int(1),
            Value::Int(2),
            Value::Int(1),
            Value::Null,
        ]);
        let b = Vector::from_values(vec![
            Value::str("x"),
            Value::str("x"),
            Value::str("x"),
            Value::Null,
        ]);
        let mut out = Vec::new();
        t.assign(&[a.clone(), b.clone()], 4, &mut out);
        assert_eq!(out, vec![0, 1, 0, 2]);
        assert_eq!(t.key(2), vec![Value::Null, Value::Null]);
        let mut caches = vec![DictCache::default(), DictCache::default()];
        t.lookup(&[a, b], 4, &mut out, &mut caches);
        assert_eq!(out, vec![0, 1, 0, NO_ROW]);
        // Mixed decimal scales fall back to value keys with value equality.
        let mut i = Interner::default();
        let d = Vector::from_values(vec![Value::Decimal(150, 2)]);
        i.intern(&d, &mut out);
        assert_eq!(i.lookup_value(&Value::Decimal(15, 1)), 0);
        assert_eq!(i.intern_value(&Value::Decimal(15, 1)), 0);
        assert_eq!(i.len(), 1);
    }

    #[test]
    fn dictionary_codes() {
        let dict: Arc<[Arc<str>]> = vec![Arc::from("a"), Arc::from("b")].into();
        let v = Vector::new(Data::Dict(vec![1, 0, 1], dict), None);
        let mut i = Interner::default();
        let mut out = Vec::new();
        i.intern(&v, &mut out);
        assert_eq!(out, vec![0, 1, 0]);
        assert_eq!(i.value(0), &Value::str("b"));
    }
}
