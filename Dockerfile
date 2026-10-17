# PostgreSQL image with pg_try_cast preinstalled.
#
#   docker build -t pg_try_cast .
#   docker build --build-arg PG_MAJOR=18 -t pg_try_cast:18 .
#   docker run -d --name pgtry -e POSTGRES_PASSWORD=postgres -p 5432:5432 pg_try_cast
#   docker exec -it pgtry psql -U postgres -c "CREATE EXTENSION pg_try_cast"

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential postgresql-server-dev-${PG_MAJOR} \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/pg_try_cast
COPY . .
RUN make with_llvm=no clean \
 && make with_llvm=no \
 && make with_llvm=no install
