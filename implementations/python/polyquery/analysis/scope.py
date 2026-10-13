"""Name-resolution scopes (spec/sql/semantics.md §1, §8, §9)."""

from __future__ import annotations

from dataclasses import dataclass, field

from .. import errors
from ..datatypes import DataType
from ..names import fold
from ..sql import ast
from . import bound as b


def pos(node: ast.Node) -> dict[str, int]:
    return {"line": node.pos[0], "column": node.pos[1]}


@dataclass(eq=False)
class RangeVar:
    """A range variable of a FROM clause: a named relation with columns."""

    rel: int
    name: str
    column_names: list[str]
    column_types: list[DataType]
    relation: b.TableRelation | b.DerivedRelation
    # folded column name -> positions, built on first lookup (a derived
    # table may have thousands of columns, each referenced)
    _positions: dict[str, list[int]] | None = field(default=None, init=False, repr=False)

    def find(self, name: str) -> list[int]:
        if self._positions is None:
            positions: dict[str, list[int]] = {}
            for i, c in enumerate(self.column_names):
                positions.setdefault(fold(c), []).append(i)
            self._positions = positions
        return list(self._positions.get(fold(name), ()))

    def column(self, index: int) -> b.ColumnRef:
        if isinstance(self.relation, b.TableRelation):
            self.relation.used.add(index)
        return b.ColumnRef(self.column_types[index], self.rel, index, self.column_names[index])


@dataclass(eq=False)
class CteDef:
    name: str
    query: b.BoundQuery
    column_names: list[str]


@dataclass(eq=False)
class CteEnv:
    """CTE definitions visible at some point; inner WITH clauses shadow outer ones."""

    definitions: dict[str, CteDef]
    parent: CteEnv | None = None

    def lookup(self, name: str) -> CteDef | None:
        env: CteEnv | None = self
        key = fold(name)
        while env is not None:
            found = env.definitions.get(key)
            if found is not None:
                return found
            env = env.parent
        return None


@dataclass(eq=False)
class Scope:
    """The range variables of one query level plus a link to the enclosing query.

    ``outer_refs`` collects the columns of enclosing queries referenced from
    this query level (directly or from nested subqueries): they make the query
    correlated. ``opaque_parent`` hides the parent's own range variables
    (derived tables and CTEs cannot see the FROM clause they appear in), while
    lookups still continue to the parent's ancestors.
    """

    parent: Scope | None
    ctes: CteEnv | None
    range_vars: list[RangeVar] = field(default_factory=list)
    outer_refs: dict[b.ColumnKey, b.ColumnRef] = field(default_factory=dict)
    opaque_parent: bool = False
    # indexes of the range variables (a FROM clause may list thousands):
    # by folded name, and their columns by folded column name in FROM order
    _by_name: dict[str, RangeVar] = field(default_factory=dict, init=False, repr=False)
    _columns: dict[str, list[tuple[RangeVar, int]]] = field(default_factory=dict, init=False, repr=False)

    def add(self, rv: RangeVar, node: ast.Node) -> None:
        key = fold(rv.name)
        if key in self._by_name:
            raise errors.semantic_error(
                f"duplicate table name or alias '{rv.name}' in FROM", **pos(node)
            )
        self._by_name[key] = rv
        self.range_vars.append(rv)
        for i, name in enumerate(rv.column_names):
            self._columns.setdefault(fold(name), []).append((rv, i))

    def find_range_var(self, name: str) -> RangeVar | None:
        return self._by_name.get(fold(name))

    def has_local_column(self, name: str) -> bool:
        return fold(name) in self._columns

    def _lookup_local(self, ref: ast.ColumnRef) -> b.ColumnRef | None:
        if ref.qualifier is not None:
            rv = self.find_range_var(ref.qualifier)
            if rv is None:
                return None
            matches = rv.find(ref.name)
            if not matches:
                raise errors.semantic_error(
                    f"unknown column '{ref.qualifier}.{ref.name}'", **pos(ref)
                )
            if len(matches) > 1:
                raise errors.semantic_error(
                    f"column reference '{ref.qualifier}.{ref.name}' is ambiguous", **pos(ref)
                )
            return rv.column(matches[0])
        found = self._columns.get(fold(ref.name), [])
        if len(found) > 1:
            raise errors.semantic_error(f"column reference '{ref.name}' is ambiguous", **pos(ref))
        if found:
            rv, index = found[0]
            return rv.column(index)
        return None

    def resolve(self, ref: ast.ColumnRef) -> b.ColumnRef:
        """Resolves a column reference, searching enclosing queries if needed."""
        scope: Scope | None = self
        skip_locals = False
        passed: list[Scope] = []
        while scope is not None:
            result = None if skip_locals else scope._lookup_local(ref)
            if result is not None:
                for s in passed:
                    s.outer_refs[result.key] = result
                return result
            passed.append(scope)
            skip_locals = scope.opaque_parent
            scope = scope.parent
        if ref.qualifier is not None:
            raise errors.semantic_error(
                f"unknown column '{ref.qualifier}.{ref.name}'", **pos(ref)
            )
        raise errors.semantic_error(f"unknown column '{ref.name}'", **pos(ref))

    def local_rels(self) -> set[int]:
        return {rv.rel for rv in self.range_vars}
