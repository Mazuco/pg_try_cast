/* pg_try_cast--1.0.sql */

-- Refuse to run as a plain SQL script: this file must be loaded by CREATE EXTENSION.
\echo Use "CREATE EXTENSION pg_try_cast" to load this file. \quit

CREATE FUNCTION try_cast(value text, fallback anyelement)
RETURNS anyelement
AS 'MODULE_PATHNAME', 'pg_try_cast'
LANGUAGE C STABLE PARALLEL SAFE;

COMMENT ON FUNCTION try_cast(text, anyelement) IS
'Converts value to the type of fallback. Returns fallback (e.g. NULL::int) when the conversion fails, instead of raising an error.';

CREATE FUNCTION try_convert(fallback anyelement, value text)
RETURNS anyelement
AS 'MODULE_PATHNAME', 'pg_try_convert'
LANGUAGE C STABLE PARALLEL SAFE;

COMMENT ON FUNCTION try_convert(anyelement, text) IS
'SQL Server style TRY_CONVERT: same as try_cast(value, fallback) with the arguments swapped.';
