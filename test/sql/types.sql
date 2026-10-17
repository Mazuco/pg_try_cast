-- try_cast across many kinds of data types
\pset null '(null)'

-- booleans, uuid, network
SELECT try_cast('yes', NULL::boolean), try_cast('talvez', NULL::boolean);
SELECT try_cast('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', NULL::uuid), try_cast('123', NULL::uuid);
SELECT try_cast('192.168.0.1', NULL::inet), try_cast('999.1.1.1', NULL::inet);

-- date/time
SELECT try_cast('10:30', NULL::time), try_cast('25:00', NULL::time);
SELECT try_cast('1 day 2 hours', NULL::interval), try_cast('one day', NULL::interval);

-- json
SELECT try_cast('{"a": 1}', NULL::jsonb), try_cast('{"a":', NULL::jsonb);
SELECT try_cast('[1,2', NULL::json);

-- arrays and ranges
SELECT try_cast('{1,2,3}', NULL::int[]), try_cast('{1,2,x}', NULL::int[]);
SELECT try_cast('[1,10)', NULL::int4range), try_cast('[10,1)', NULL::int4range);

-- type modifiers follow column / COPY rules
SELECT try_cast('abc', NULL::varchar(3)), try_cast('abcd', NULL::varchar(3));
SELECT try_cast('ab', NULL::char(2)), try_cast('abc', NULL::char(2));
SELECT try_cast('123.456', NULL::numeric(5,2)), try_cast('12345.6', NULL::numeric(5,2));

-- typmod taken from the fallback expression
SELECT try_cast(v, 'N/A'::varchar(4)) FROM (VALUES ('BR'), ('BRASIL')) t(v);

-- domains: CHECK constraints are honoured
CREATE DOMAIN positive_int AS int CHECK (VALUE > 0);
SELECT try_cast('5', NULL::positive_int), try_cast('-5', NULL::positive_int), try_cast('x', NULL::positive_int);

-- enums
CREATE TYPE mood AS ENUM ('happy', 'sad');
SELECT try_cast('happy', NULL::mood), try_cast('angry', NULL::mood);

-- composite types
CREATE TYPE pair AS (a int, b text);
SELECT try_cast('(1,abc)', NULL::pair), try_cast('(x,abc)', NULL::pair);

-- object identifiers
SELECT try_cast('pg_class', NULL::regclass), try_cast('no_such_table', NULL::regclass);

-- one call site, many rows, different outcomes (exercises the cache)
SELECT count(*) FILTER (WHERE x IS NULL) AS invalid, count(x) AS valid
FROM (SELECT try_cast(CASE WHEN g % 3 = 0 THEN 'x' ELSE g::text END, NULL::int) x
      FROM generate_series(1, 3000) g) s;
