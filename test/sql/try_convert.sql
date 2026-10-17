-- try_convert(fallback anyelement, value text): SQL Server argument order
\pset null '(null)'

SELECT try_convert(NULL::int, '42');
SELECT try_convert(NULL::int, 'abc');
SELECT try_convert(0, 'abc');
SELECT try_convert(NULL::numeric, '1.5');
SELECT try_convert(NULL::timestamp, '2026-10-17 10:30:00');
SELECT try_convert(NULL::timestamp, '2026-10-17 25:30:00');
SELECT try_convert(0, NULL);

-- same answer as try_cast
SELECT try_convert(NULL::uuid, v) IS NOT DISTINCT FROM try_cast(v, NULL::uuid) AS same
FROM (VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'), ('nope')) t(v);
