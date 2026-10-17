# pg_try_cast

[![CI](https://github.com/SEU-USUARIO/pg_try_cast/actions/workflows/ci.yml/badge.svg)](https://github.com/SEU-USUARIO/pg_try_cast/actions/workflows/ci.yml)
![PostgreSQL 16+](https://img.shields.io/badge/PostgreSQL-16%2B-336791?logo=postgresql&logoColor=white)
[![Licença: PostgreSQL](https://img.shields.io/badge/licen%C3%A7a-PostgreSQL-blue.svg)](LICENSE)

**`TRY_CAST` e `TRY_CONVERT` para PostgreSQL.** Converte um valor para qualquer tipo e devolve `NULL`
(ou um valor padrão que você escolher) quando ele não é válido. A query continua rodando, em vez de abortar com erro.

🇺🇸 [Read in English](README.md)

```sql
SELECT try_cast('42',  NULL::int);   -- 42
SELECT try_cast('abc', NULL::int);   -- NULL   (sem erro!)
SELECT try_cast('abc', 0);           -- 0      (valor padrão)
```

## Por quê?

No PostgreSQL, basta uma linha ruim para derrubar a query inteira:

```sql
SELECT id, preco::numeric FROM importacao;
-- ERROR:  invalid input syntax for type numeric: "R$ 10,00"
```

O SQL Server resolve isso com `TRY_CAST` e `TRY_CONVERT`, e o Oracle com `CAST ... DEFAULT ... ON CONVERSION ERROR`.
O PostgreSQL ainda não tem nenhum dos dois. As gambiarras de sempre são uma regex antes de cada cast (frágil, e diferente
para cada tipo) ou uma função PL/pgSQL com bloco `EXCEPTION`, que abre uma subtransação a cada linha e é lenta.

O `pg_try_cast` é uma extensão pequena em C que faz isso do jeito certo. Funciona com **qualquer tipo** que o PostgreSQL
saiba ler a partir de texto: inteiros, numéricos, datas, timestamps, uuid, json/jsonb, arrays, ranges, enums, domínios
e tipos compostos. E é **cerca de 16× mais rápida** que a solução em PL/pgSQL.

## Como usar

### `try_cast(valor text, padrao anyelement) → anyelement`

O **tipo** de `padrao` define para qual tipo `valor` será convertido. O **valor** de `padrao` é o que volta quando a
conversão falha.

```sql
SELECT try_cast('2026-10-17', NULL::date);      -- 2026-10-17
SELECT try_cast('2026-02-30', NULL::date);      -- NULL
SELECT try_cast('99999999999', NULL::int);      -- NULL (fora do intervalo)
SELECT try_cast('n/d', 0);                      -- 0
SELECT try_cast('{"a":', '{}'::jsonb);          -- {}
SELECT try_cast(NULL, 0);                       -- NULL (entra NULL, sai NULL)
```

### `try_convert(padrao anyelement, valor text) → anyelement`

É a mesma função, com a ordem de argumentos do SQL Server, para facilitar migrações:

```sql
SELECT try_convert(NULL::int, '42');            -- 42
SELECT try_convert(NULL::int, 'abc');           -- NULL
```

### Exemplo real: limpando uma importação

```sql
SELECT id,
       try_cast(valor_bruto, NULL::numeric(12,2)) AS valor,
       try_cast(data_bruta,  NULL::date)          AS pago_em,
       try_cast(email_bruto, NULL::varchar(120))  AS email
FROM   importacao;

-- encontrar as linhas com problema
SELECT * FROM importacao
WHERE  valor_bruto IS NOT NULL
AND    try_cast(valor_bruto, NULL::numeric) IS NULL;
```

### Colinha SQL Server → PostgreSQL

| SQL Server                          | pg_try_cast                              |
|-------------------------------------|------------------------------------------|
| `TRY_CAST(x AS int)`                | `try_cast(x, NULL::int)`                 |
| `TRY_CAST(x AS decimal(10,2))`      | `try_cast(x, NULL::numeric(10,2))`       |
| `TRY_CONVERT(date, x)`              | `try_convert(NULL::date, x)`             |
| `ISNULL(TRY_CAST(x AS int), 0)`     | `try_cast(x, 0)`                         |
| `TRY_CAST(x AS uniqueidentifier)`   | `try_cast(x, NULL::uuid)`                |

## Instalação

Requer **PostgreSQL 16 ou mais novo**, porque usa as funções de entrada com "erro suave" (soft error) que surgiram
no PostgreSQL 16.

### Linux (Debian / Ubuntu)

```bash
sudo apt install build-essential postgresql-server-dev-17   # use a versão do seu PostgreSQL
git clone https://github.com/SEU-USUARIO/pg_try_cast.git
cd pg_try_cast
make
sudo make install
```

### Linux (RHEL / Rocky / Fedora)

```bash
sudo dnf install gcc make postgresql17-devel   # o nome do pacote pode variar conforme o repositório
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
sudo make install PG_CONFIG=/usr/pgsql-17/bin/pg_config
```

### macOS (Homebrew)

```bash
brew install postgresql@17
make PG_CONFIG=$(brew --prefix postgresql@17)/bin/pg_config
make install PG_CONFIG=$(brew --prefix postgresql@17)/bin/pg_config
```

### Docker (qualquer sistema, inclusive Windows)

```bash
docker build -t pg_try_cast .                    # PostgreSQL 17 por padrão
docker build --build-arg PG_MAJOR=18 -t pg_try_cast:18 .
docker run -d --name pgtry -e POSTGRES_PASSWORD=postgres -p 5432:5432 pg_try_cast
```

> **Erro de compilação falando de `clang` ou `llvm`?** Alguns pacotes do PostgreSQL foram compilados com suporte a JIT
> e tentam gerar um "bitcode" LLVM extra, que você não precisa. Compile com
> `make with_llvm=no && sudo make with_llvm=no install`.

### Ativando no banco

```sql
CREATE EXTENSION pg_try_cast;
```

A extensão é marcada como `trusted`. Qualquer usuário com privilégio `CREATE` no banco pode ativá-la, sem precisar de
superusuário.

## Como ela se comporta

- **Entra NULL, sai NULL.** `try_cast(NULL, 0)` devolve `NULL`, igual a `CAST(NULL AS int)`.
- **A entrada é texto.** Para outros tipos, use `::text`. Exemplo: `try_cast(minha_coluna::text, NULL::int)`.
- **Modificadores de tipo são respeitados**, com as mesmas regras de um `INSERT` ou `COPY` numa coluna daquele tipo:
  - `try_cast('abcd', NULL::varchar(3))` devolve `NULL`, porque o valor não cabe. Um `CAST` comum truncaria para `'abc'`.
  - `try_cast('123.456', NULL::numeric(5,2))` devolve `123.46`, arredondado como o `numeric(5,2)` faz.
  - `try_cast('12345.6', NULL::numeric(5,2))` devolve `NULL` (estouro).
- **Os `CHECK` de domínios são verificados.** Com `CREATE DOMAIN positivo AS int CHECK (VALUE > 0)`,
  `try_cast('-5', NULL::positivo)` devolve `NULL`.
- **O tipo do padrão precisa ser conhecido.** `try_cast('1', NULL)` dá erro. Escreva `NULL::int`.

## Limitações

- Algumas funções de entrada não suportam erro suave e continuam lançando erro:
  - `regtype` com um nome sintaticamente inválido (por exemplo `'###'`). Nomes válidos que não existem devolvem `NULL`.
  - Tipos de outras extensões cujos autores ainda não adotaram a API de erro suave.
- Só converte **a partir de texto**, que é o formato em que dados sujos costumam chegar. Casts como `numeric → int`
  com arredondamento são outra operação e não fazem parte desta extensão.

## Desempenho

1.000.000 de linhas, 10% inválidas, PostgreSQL 16, sem workers paralelos, mediana de 5 execuções:

| Método                                                        | Tempo        |
|---------------------------------------------------------------|--------------|
| `try_cast(v, NULL::int)`                                      | **~110 ms**  |
| `CASE WHEN pg_input_is_valid(v, 'int4') THEN v::int END`      | ~117 ms      |
| Função PL/pgSQL com `BEGIN ... EXCEPTION ... END`             | ~1.790 ms    |

O `try_cast` é tão rápido quanto a checagem nativa `pg_input_is_valid()`, porque os dois usam o mesmo mecanismo.
A vantagem é que uma única chamada faz a checagem e a conversão, aceita valor padrão e respeita o modificador do tipo
de destino. Rode você mesmo com `psql -f bench/benchmark.sql`.

## O PostgreSQL já não tem isso?

Ainda não. O PostgreSQL 16 trouxe `pg_input_is_valid()` e `pg_input_error_info()`, que dizem *se* um valor é válido,
mas não convertem. A sintaxe do padrão SQL, `CAST(x AS int DEFAULT 0 ON CONVERSION ERROR)`, está em discussão na lista
pgsql-hackers, mas não entrou no PostgreSQL 19 (até o RC 1). O `pg_try_cast` funciona hoje, a partir do PostgreSQL 16.

## Rodando os testes

```bash
make
sudo make install
make installcheck          # precisa de um servidor rodando ao qual você consiga conectar
```

## Documentação extra

- [Como a extensão funciona por dentro (código C explicado linha a linha)](docs/COMO_FUNCIONA.md)

## Contribuindo

Issues e pull requests são bem-vindos. Qualquer mudança de comportamento deve vir com um teste de regressão em
`test/sql/` e a saída esperada em `test/expected/`.

## Licença

Distribuída sob a [Licença PostgreSQL](LICENSE).
