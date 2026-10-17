# pg_try_cast

[![CI](https://github.com/Mazuco/pg_try_cast/actions/workflows/ci.yml/badge.svg)](https://github.com/SEU-USUARIO/pg_try_cast/actions/workflows/ci.yml)
![PostgreSQL 16+](https://img.shields.io/badge/PostgreSQL-16%2B-336791?logo=postgresql&logoColor=white)
[![License: PostgreSQL](https://img.shields.io/badge/license-PostgreSQL-blue.svg)](LICENSE)

**`TRY_CAST` and `TRY_CONVERT` for PostgreSQL.** Convert a value to any type and get
`NULL` (or a fallback of your choice) when it doesn't fit, instead of an error that aborts the whole query.

🇧🇷 [Leia em português](README.pt-BR.md)

```sql
SELECT try_cast('42',  NULL::int);   -- 42
SELECT try_cast('abc', NULL::int);   -- NULL   (no error!)
SELECT try_cast('abc', 0);           -- 0      (fallback value)
```

## Why?

One bad row is enough to break a query in PostgreSQL:

```sql
SELECT id, price::numeric FROM staging_import;
-- ERROR:  invalid input syntax for type numeric: "R$ 10,00"
```

SQL Server has `TRY_CAST` and `TRY_CONVERT` for this, and Oracle has `CAST ... DEFAULT ... ON CONVERSION ERROR`.
PostgreSQL has neither yet. The usual workarounds are a regex in front of every cast, which is fragile and different
for each type, or a PL/pgSQL function with an `EXCEPTION` block, which opens a subtransaction on every row and is slow.

`pg_try_cast` is a small C extension that does it properly. It works with **any type** that PostgreSQL can read
from text, including integers, numerics, dates, timestamps, uuid, json/jsonb, arrays, ranges, enums, domains and
composite types. It is also **~16× faster** than the PL/pgSQL approach.

## Usage

### `try_cast(value text, fallback anyelement) → anyelement`

The **type** of `fallback` decides what `value` is converted to. Its **value** is what you get back when the
conversion fails.

```sql
SELECT try_cast('2026-10-17', NULL::date);      -- 2026-10-17
SELECT try_cast('2026-02-30', NULL::date);      -- NULL
SELECT try_cast('99999999999', NULL::int);      -- NULL (out of range)
SELECT try_cast('n/a', 0);                      -- 0
SELECT try_cast('{"a":', '{}'::jsonb);          -- {}
SELECT try_cast(NULL, 0);                       -- NULL (NULL in, NULL out)
```

### `try_convert(fallback anyelement, value text) → anyelement`

The same function with SQL Server's argument order, to make migrations easier:

```sql
SELECT try_convert(NULL::int, '42');            -- 42
SELECT try_convert(NULL::int, 'abc');           -- NULL
```

### Real-world example: cleaning an import

```sql
SELECT id,
       try_cast(raw_amount, NULL::numeric(12,2)) AS amount,
       try_cast(raw_date,   NULL::date)          AS paid_on,
       try_cast(raw_email,  NULL::varchar(120))  AS email
FROM   staging_import;

-- find the rows that need attention
SELECT * FROM staging_import
WHERE  raw_amount IS NOT NULL
AND    try_cast(raw_amount, NULL::numeric) IS NULL;
```

### SQL Server → PostgreSQL cheat sheet

| SQL Server                          | pg_try_cast                              |
|-------------------------------------|------------------------------------------|
| `TRY_CAST(x AS int)`                | `try_cast(x, NULL::int)`                 |
| `TRY_CAST(x AS decimal(10,2))`      | `try_cast(x, NULL::numeric(10,2))`       |
| `TRY_CONVERT(date, x)`              | `try_convert(NULL::date, x)`             |
| `ISNULL(TRY_CAST(x AS int), 0)`     | `try_cast(x, 0)`                         |
| `TRY_CAST(x AS uniqueidentifier)`   | `try_cast(x, NULL::uuid)`                |

## Installation

Requires **PostgreSQL 16 or newer**, because it relies on the "soft error" input functions added in PostgreSQL 16.

### Linux (Debian / Ubuntu)

```bash
sudo apt install build-essential postgresql-server-dev-17   # use your PostgreSQL major version
git clone https://github.com/Mazuco/pg_try_cast.git
cd pg_try_cast
make
sudo make install
```

### Linux (RHEL / Rocky / Fedora)

```bash
sudo dnf install gcc make postgresql17-devel   # package name may vary with your repo
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
sudo make install PG_CONFIG=/usr/pgsql-17/bin/pg_config
```

### macOS (Homebrew)

```bash
brew install postgresql@17
make PG_CONFIG=$(brew --prefix postgresql@17)/bin/pg_config
make install PG_CONFIG=$(brew --prefix postgresql@17)/bin/pg_config
```

### Docker (any OS, including Windows)

```bash
docker build -t pg_try_cast .                    # PostgreSQL 17 by default
docker build --build-arg PG_MAJOR=18 -t pg_try_cast:18 .
docker run -d --name pgtry -e POSTGRES_PASSWORD=postgres -p 5432:5432 pg_try_cast
```

> **Build error mentioning `clang` or `llvm`?** Some PostgreSQL packages were built with JIT support and try to
> compile extra LLVM bitcode. You don't need it. Build with `make with_llvm=no && sudo make with_llvm=no install`.

### Enable it in your database

```sql
CREATE EXTENSION pg_try_cast;
```

The extension is marked `trusted`, so any user with `CREATE` privilege on the database can enable it.
Superuser is not required.

## How it behaves

- **NULL in, NULL out.** `try_cast(NULL, 0)` returns `NULL`, like `CAST(NULL AS int)`.
- **The input is text.** Other types can be passed with `::text`, for example `try_cast(my_col::text, NULL::int)`.
- **Type modifiers are respected**, following the same rules as `INSERT` or `COPY` into a column of that type:
  - `try_cast('abcd', NULL::varchar(3))` returns `NULL` because the value does not fit. A plain `CAST` would truncate it to `'abc'`.
  - `try_cast('123.456', NULL::numeric(5,2))` returns `123.46`, rounded as `numeric(5,2)` does.
  - `try_cast('12345.6', NULL::numeric(5,2))` returns `NULL` (overflow).
- **Domain `CHECK` constraints are checked.** If `CREATE DOMAIN positive AS int CHECK (VALUE > 0)`, then
  `try_cast('-5', NULL::positive)` returns `NULL`.
- **The fallback type must be known.** `try_cast('1', NULL)` is an error. Write `NULL::int`.

## Limitations

- A few input functions do not support soft errors, so they still raise an error:
  - `regtype` with a syntactically invalid type name (for example `'###'`). Unknown but valid names return `NULL`.
  - Data types from other extensions whose authors have not adopted the soft-error API.
- Only conversion **from text** is supported, because that is what dirty data usually is. Casts such as
  `numeric → int` with rounding are a different operation and are not covered here.

## Performance

1,000,000 rows, 10% invalid, PostgreSQL 16, no parallel workers, median of 5 runs:

| Method                                                       | Time        |
|--------------------------------------------------------------|-------------|
| `try_cast(v, NULL::int)`                                     | **~110 ms** |
| `CASE WHEN pg_input_is_valid(v, 'int4') THEN v::int END`     | ~117 ms     |
| PL/pgSQL function with `BEGIN ... EXCEPTION ... END`         | ~1,790 ms   |

`try_cast` runs as fast as the built-in `pg_input_is_valid()` check, because both use the same mechanism. The
advantage is that one call does both the check and the conversion, works with a fallback value and knows the type
modifier of the target. Run it yourself with `psql -f bench/benchmark.sql`.

## Doesn't PostgreSQL already have this?

Not yet. PostgreSQL 16 added `pg_input_is_valid()` and `pg_input_error_info()`, which tell you *whether* a value
is valid but do not convert it. The SQL-standard syntax `CAST(x AS int DEFAULT 0 ON CONVERSION ERROR)` has been
discussed on pgsql-hackers, but it is not part of PostgreSQL 19 (as of RC 1). `pg_try_cast` works today, from
PostgreSQL 16 onward.

## Running the tests

```bash
make
sudo make install
make installcheck          # needs a running server you can connect to
```

## Under the hood

A walkthrough of the C code, written for people who have never built a PostgreSQL extension, is available in
Portuguese: [docs/COMO_FUNCIONA.md](docs/COMO_FUNCIONA.md).

## Contributing

Issues and pull requests are welcome. Please add a regression test in `test/sql/` and its expected output in
`test/expected/` for any change in behaviour.

## License

Released under the [PostgreSQL License](LICENSE).
