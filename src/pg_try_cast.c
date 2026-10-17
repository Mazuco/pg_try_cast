/*-------------------------------------------------------------------------
 *
 * pg_try_cast.c
 *      TRY_CAST / TRY_CONVERT for PostgreSQL.
 *
 * Converts a text value to any data type. When the conversion fails, the
 * function returns a fallback value (NULL by default) instead of raising
 * an error and aborting the whole query.
 *
 *      SELECT try_cast('42',  NULL::int);   -- 42
 *      SELECT try_cast('abc', NULL::int);   -- NULL
 *      SELECT try_cast('abc', 0);           -- 0   (fallback value)
 *
 * How it works
 * ------------
 * Since PostgreSQL 16, the input function of (almost) every built-in data
 * type supports "soft errors": instead of throwing, it can record the
 * failure in an ErrorSaveContext and return false. We call the target
 * type's input function through InputFunctionCallSafe() and, if it reports
 * a soft error, we return the fallback value.
 *
 * No subtransaction and no PG_TRY/PG_CATCH are needed, so this is much
 * cheaper than the classic PL/pgSQL "BEGIN ... EXCEPTION ... END" trick.
 *
 * Copyright (c) 2026, Vitor Mazuco
 * Released under the PostgreSQL License (see LICENSE).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "nodes/miscnodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/primnodes.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

#if PG_VERSION_NUM < 160000
#error "pg_try_cast requires PostgreSQL 16 or newer (it needs soft-error input functions)"
#endif

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pg_try_cast);
PG_FUNCTION_INFO_V1(pg_try_convert);

/*
 * Per-call-site cache.
 *
 * Looking up a type's input function in the system catalogs is relatively
 * expensive. When try_cast() runs over millions of rows, the target type is
 * the same on every row, so we keep the lookup result in fn_extra, which
 * PostgreSQL preserves between calls of the same expression.
 */
typedef struct TryCastCache
{
    Oid         typid;          /* type the cache was built for */
    int32       typmod;         /* type modifier, e.g. 3 in varchar(3); -1 = none */
    Oid         typioparam;     /* extra parameter for the input function */
    FmgrInfo    inputproc;      /* the type's input function, ready to call */
} TryCastCache;

/*
 * Find the type modifier of argument argnum, e.g. 3 for NULL::varchar(3)
 * or (5,2) for NULL::numeric(5,2). Returns -1 if there is none or if we
 * cannot tell (for instance when called through a prepared statement
 * parameter).
 */
static int32
get_arg_typmod(FmgrInfo *flinfo, int argnum)
{
    List       *args;

    if (flinfo->fn_expr == NULL || !IsA(flinfo->fn_expr, FuncExpr))
        return -1;

    args = ((FuncExpr *) flinfo->fn_expr)->args;
    if (argnum < 0 || argnum >= list_length(args))
        return -1;

    return exprTypmod((Node *) list_nth(args, argnum));
}

static TryCastCache *
get_cache(FunctionCallInfo fcinfo, Oid target_type, int target_arg)
{
    TryCastCache *cache = (TryCastCache *) fcinfo->flinfo->fn_extra;

    if (cache == NULL || cache->typid != target_type)
    {
        Oid         typinput;

        if (cache == NULL)
        {
            /* fn_mcxt lives as long as the expression, so the cache does too */
            cache = MemoryContextAllocZero(fcinfo->flinfo->fn_mcxt,
                                           sizeof(TryCastCache));
            fcinfo->flinfo->fn_extra = cache;
        }

        getTypeInputInfo(target_type, &typinput, &cache->typioparam);
        fmgr_info_cxt(typinput, &cache->inputproc, fcinfo->flinfo->fn_mcxt);
        cache->typmod = get_arg_typmod(fcinfo->flinfo, target_arg);
        cache->typid = target_type;
    }

    return cache;
}

/*
 * Shared implementation.
 *
 * value_arg:  position of the text argument to be converted
 * target_arg: position of the anyelement argument. Its *type* is the target
 *             type and its *value* is the fallback returned on failure.
 */
static Datum
try_cast_common(FunctionCallInfo fcinfo, int value_arg, int target_arg)
{
    Oid         target_type;
    TryCastCache *cache;
    char       *str;
    Datum       result;
    ErrorSaveContext escontext = {T_ErrorSaveContext};

    /* Which type was the second argument? That is our target type. */
    target_type = get_fn_expr_argtype(fcinfo->flinfo, target_arg);
    if (!OidIsValid(target_type))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("could not determine the target type of try_cast")));

    /* Same as CAST(NULL AS ...): NULL in, NULL out. */
    if (PG_ARGISNULL(value_arg))
        PG_RETURN_NULL();

    str = text_to_cstring(PG_GETARG_TEXT_PP(value_arg));
    cache = get_cache(fcinfo, target_type, target_arg);

    /*
     * The heart of the extension: run the input function in "safe" mode.
     * On success it returns true and stores the converted value in result.
     * On a bad value it returns false instead of throwing an error.
     *
     * Passing the typmod gives the same rules as inserting into a column of
     * that type (or COPY): 'abcdef' does not fit varchar(3), so it fails.
     */
    if (InputFunctionCallSafe(&cache->inputproc, str,
                              cache->typioparam, cache->typmod,
                              (Node *) &escontext,
                              &result))
    {
        pfree(str);
        PG_RETURN_DATUM(result);
    }

    pfree(str);

    /* Conversion failed: hand back the fallback value (may be NULL). */
    if (PG_ARGISNULL(target_arg))
        PG_RETURN_NULL();

    PG_RETURN_DATUM(PG_GETARG_DATUM(target_arg));
}

/* try_cast(value text, fallback anyelement) RETURNS anyelement */
Datum
pg_try_cast(PG_FUNCTION_ARGS)
{
    return try_cast_common(fcinfo, 0, 1);
}

/* try_convert(fallback anyelement, value text) RETURNS anyelement
 * Same thing, with the argument order of SQL Server's TRY_CONVERT. */
Datum
pg_try_convert(PG_FUNCTION_ARGS)
{
    return try_cast_common(fcinfo, 1, 0);
}
