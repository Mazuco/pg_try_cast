-- pg_try_cast benchmark
-- Usage:  psql -d your_database -f bench/benchmark.sql
-- Creates temporary objects only; nothing is left behind.

CREATE EXTENSION IF NOT EXISTS pg_try_cast;

-- The classic workaround: a PL/pgSQL function with an EXCEPTION block.
CREATE FUNCTION pg_temp.plpgsql_try_int(v text) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN v::int;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- 1,000,000 values, 10% of them invalid
CREATE TEMP TABLE bench AS
SELECT CASE WHEN g % 10 = 0 THEN 'x' || g ELSE g::text END AS v
FROM generate_series(1, 1000000) g;
ANALYZE bench;

SET max_parallel_workers_per_gather = 0;
\timing on

\echo '--- try_cast'
SELECT count(try_cast(v, NULL::int)) FROM bench;

\echo '--- pg_input_is_valid + cast'
SELECT count(CASE WHEN pg_input_is_valid(v, 'int4') THEN v::int END) FROM bench;

\echo '--- PL/pgSQL with EXCEPTION'
SELECT count(pg_temp.plpgsql_try_int(v)) FROM bench;

\timing off
