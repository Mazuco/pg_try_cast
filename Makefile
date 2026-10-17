# Makefile for pg_try_cast, using PGXS (the PostgreSQL extension build system).
#
#   make                 build
#   sudo make install    install into the PostgreSQL found by pg_config
#   make installcheck    run the regression tests against a running server
#
# To build against a specific PostgreSQL version:
#   make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config

EXTENSION   = pg_try_cast
MODULE_big  = pg_try_cast
OBJS        = src/pg_try_cast.o
DATA        = pg_try_cast--1.0.sql
PGFILEDESC  = "pg_try_cast - TRY_CAST / TRY_CONVERT for PostgreSQL"

REGRESS      = try_cast try_convert types
REGRESS_OPTS = --inputdir=test --outputdir=test

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
