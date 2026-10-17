# Changelog

## 1.0.0 — 2026-10-17

First release.

- `try_cast(value text, fallback anyelement)`: converts text to any type and returns the fallback on failure.
- `try_convert(fallback anyelement, value text)`: the same function with SQL Server argument order.
- Respects type modifiers (`varchar(n)`, `numeric(p,s)`, …) and domain `CHECK` constraints.
- Supports PostgreSQL 16, 17 and 18.
