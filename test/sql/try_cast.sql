-- Basic behaviour of try_cast(value text, fallback anyelement)
CREATE EXTENSION pg_try_cast;
\pset null '(null)'

-- valid input is converted
SELECT try_cast('42', NULL::int);
SELECT try_cast('  42  ', NULL::int);
SELECT try_cast('-7', NULL::bigint);
SELECT try_cast('3.14', NULL::numeric);
SELECT try_cast('2026-10-17', NULL::date);

-- invalid input returns NULL instead of an error
SELECT try_cast('abc', NULL::int);
SELECT try_cast('', NULL::int);
SELECT try_cast('4.5', NULL::int);
SELECT try_cast('2026-02-30', NULL::date);

-- out-of-range values also return NULL
SELECT try_cast('99999999999', NULL::int);
SELECT try_cast('40000', NULL::smallint);

-- a non-NULL fallback is returned on failure
SELECT try_cast('abc', 0);
SELECT try_cast('abc', -1::bigint);
SELECT try_cast('not a date', DATE '1900-01-01');
SELECT try_cast('42', 0);

-- NULL input stays NULL, even with a fallback (same as CAST(NULL AS ...))
SELECT try_cast(NULL, 0);
SELECT try_cast(NULL::text, NULL::int);

-- works on table data, row by row
CREATE TEMP TABLE raw_data (id int, v text);
INSERT INTO raw_data VALUES (1, '10'), (2, 'dez'), (3, NULL), (4, '30'), (5, '1e3');
SELECT id, v, try_cast(v, NULL::int) AS as_int, try_cast(v, NULL::numeric) AS as_num
FROM raw_data ORDER BY id;
SELECT sum(try_cast(v, 0)) FROM raw_data;

-- varchar / text values are accepted as input
SELECT try_cast('123'::varchar, NULL::int);

-- the fallback type must be known
SELECT try_cast('1', NULL);
