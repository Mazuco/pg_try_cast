# Como o pg_try_cast funciona por dentro

Este guia é para quem nunca escreveu uma extensão para PostgreSQL e não programa em C. A ideia é que, ao final,
você consiga ler o código, entender cada parte e fazer pequenas mudanças com segurança.

## 1. A anatomia de uma extensão

Uma extensão do PostgreSQL é só um conjunto de arquivos que o servidor sabe instalar com `CREATE EXTENSION`.

```
pg_try_cast/
├── pg_try_cast.control      ← "carteira de identidade" da extensão
├── pg_try_cast--1.0.sql     ← SQL executado no CREATE EXTENSION
├── src/pg_try_cast.c        ← o código C (a lógica de verdade)
├── Makefile                 ← receita de compilação (usa o PGXS)
└── test/
    ├── sql/*.sql            ← testes: comandos SQL
    └── expected/*.out       ← testes: saída que esperamos de cada comando
```

Quando alguém roda `CREATE EXTENSION pg_try_cast;`, o PostgreSQL:

1. Lê o `pg_try_cast.control` para descobrir a versão padrão (`1.0`) e onde está a biblioteca.
2. Executa o arquivo `pg_try_cast--1.0.sql`.
3. Esse SQL cria as funções `try_cast` e `try_convert` e diz: "o código delas está na biblioteca `pg_try_cast.so`".
4. Na primeira chamada de `try_cast`, o PostgreSQL carrega o `.so` na memória e passa a chamar o código C.

### O arquivo `.control`

```ini
comment = 'TRY_CAST / TRY_CONVERT: convert values without raising errors'
default_version = '1.0'
module_pathname = '$libdir/pg_try_cast'
relocatable = true
trusted = true
```

- `default_version`: qual arquivo `--X.Y.sql` usar quando ninguém pedir uma versão específica.
- `module_pathname`: onde está o `.so`. O `$libdir` é a pasta de bibliotecas do PostgreSQL. No SQL, o texto
  `'MODULE_PATHNAME'` é trocado por esse valor.
- `relocatable`: a extensão pode ser instalada em qualquer schema.
- `trusted`: usuários comuns (sem superusuário) podem instalá-la. Isso é seguro aqui porque a extensão só chama
  funções que o próprio PostgreSQL já expõe.

### O arquivo SQL

```sql
CREATE FUNCTION try_cast(value text, fallback anyelement)
RETURNS anyelement
AS 'MODULE_PATHNAME', 'pg_try_cast'
LANGUAGE C STABLE PARALLEL SAFE;
```

- `anyelement` é um tipo **polimórfico**: o PostgreSQL aceita qualquer tipo nesse argumento, e o retorno terá
  **o mesmo tipo**. É por isso que `try_cast('1', NULL::int)` devolve `int` e `try_cast('1', NULL::date)` devolve `date`.
- `AS 'MODULE_PATHNAME', 'pg_try_cast'`: "a implementação é a função C chamada `pg_try_cast` dentro do `.so`".
- `STABLE`: o resultado não muda dentro de uma mesma query. Não é `IMMUTABLE` porque a leitura de algumas datas
  depende de configurações como `DateStyle` e `TimeZone`.
- `PARALLEL SAFE`: pode rodar em workers paralelos.
- **Não** é `STRICT`. Uma função `STRICT` devolve NULL automaticamente se *qualquer* argumento for NULL, e aqui o
  segundo argumento é NULL quase sempre (`NULL::int`).

## 2. O código C, parte por parte

### Includes e checagem de versão

```c
#include "postgres.h"
#include "fmgr.h"
...
#if PG_VERSION_NUM < 160000
#error "pg_try_cast requires PostgreSQL 16 or newer ..."
#endif

PG_MODULE_MAGIC;
```

- `#include` funciona como um `import`. Ele traz definições do PostgreSQL. O `postgres.h` **sempre** vem primeiro.
- O `#if ... #error` faz a compilação falhar com uma mensagem clara em versões antigas, que não têm a API que usamos.
- `PG_MODULE_MAGIC` grava no `.so` a versão do PostgreSQL para a qual ele foi compilado. Se você tentar carregar um
  `.so` do PG 16 num PG 17, o servidor recusa em vez de travar.

### Declarando as funções

```c
PG_FUNCTION_INFO_V1(pg_try_cast);
```

Avisa o PostgreSQL de que `pg_try_cast` segue a "convenção de chamada versão 1", que é o formato padrão de funções C
do PostgreSQL. Toda função chamável pelo SQL precisa dessa linha.

### Conceitos que aparecem o tempo todo

| Nome              | O que é                                                                                    |
|-------------------|--------------------------------------------------------------------------------------------|
| `Datum`           | Uma "caixa" genérica que guarda qualquer valor SQL (um int, um ponteiro para texto etc.).  |
| `Oid`             | Um número que identifica um objeto do catálogo. O tipo `int4` é o OID 23, por exemplo.     |
| `PG_FUNCTION_ARGS`| Os argumentos que o PostgreSQL passa para a função. Dentro dela, se chamam `fcinfo`.       |
| `PG_ARGISNULL(n)` | O argumento `n` (contando a partir de 0) é NULL?                                           |
| `PG_GETARG_...(n)`| Lê o argumento `n` já no tipo certo.                                                       |
| `PG_RETURN_...`   | Devolve um valor (ou `PG_RETURN_NULL()` para devolver NULL).                               |
| `pfree`           | Libera memória. O PostgreSQL tem "contextos de memória" que limpam tudo no fim da query, mas liberar cedo é educado. |

### O cache

```c
typedef struct TryCastCache
{
    Oid         typid;
    int32       typmod;
    Oid         typioparam;
    FmgrInfo    inputproc;
} TryCastCache;
```

`struct` é como uma "linha de tabela" em C: um agrupamento de campos.

Todo tipo do PostgreSQL tem uma **função de entrada** (input function), que transforma texto em valor. A do `int4` se
chama `int4in`, a do `date` se chama `date_in`, e assim por diante. Descobrir qual é a função de entrada de um tipo
exige uma consulta ao catálogo do sistema, o que não é de graça.

Numa query como `SELECT try_cast(coluna, NULL::int) FROM tabela_com_1_milhao_de_linhas`, o tipo de destino é sempre o
mesmo. Então guardamos a função de entrada no `fn_extra`, um espaço que o PostgreSQL reserva para cada chamada no
plano da query e mantém entre uma linha e outra. Na primeira linha fazemos a busca. Nas próximas 999.999, reaproveitamos.

```c
cache = MemoryContextAllocZero(fcinfo->flinfo->fn_mcxt, sizeof(TryCastCache));
```

Isso aloca memória num contexto que vive enquanto a expressão viver. Se usássemos o contexto padrão, a memória seria
apagada a cada linha e o cache não serviria para nada.

### Descobrindo o `varchar(3)`

```c
static int32
get_arg_typmod(FmgrInfo *flinfo, int argnum)
```

O "typmod" é o número entre parênteses: o `3` de `varchar(3)` ou o `(5,2)` de `numeric(5,2)`. O OID do tipo não
carrega essa informação, então olhamos a **expressão** que o usuário escreveu (`fn_expr`, a árvore da query) e
perguntamos ao PostgreSQL qual o typmod daquele argumento (`exprTypmod`).

### O coração: `try_cast_common`

```c
target_type = get_fn_expr_argtype(fcinfo->flinfo, target_arg);
```

Descobre o tipo do segundo argumento. Se o usuário escreveu `NULL::date`, `target_type` é o OID de `date`.

```c
if (PG_ARGISNULL(value_arg))
    PG_RETURN_NULL();
```

Entra NULL, sai NULL.

```c
str = text_to_cstring(PG_GETARG_TEXT_PP(value_arg));
```

O tipo `text` do PostgreSQL não é uma string C comum. Ele tem um cabeçalho com o tamanho e não termina com `\0`.
As funções de entrada esperam uma string C, então convertemos.

```c
ErrorSaveContext escontext = {T_ErrorSaveContext};

if (InputFunctionCallSafe(&cache->inputproc, str,
                          cache->typioparam, cache->typmod,
                          (Node *) &escontext,
                          &result))
```

**Este é o truque da extensão inteira.** Até o PostgreSQL 15, uma função de entrada com valor inválido sempre lançava
um erro (`ereport(ERROR, ...)`), e um erro aborta a transação. A única forma de "capturar" esse erro era abrir uma
subtransação, que é exatamente o que o `EXCEPTION` do PL/pgSQL faz, e isso é caro.

No PostgreSQL 16, as funções de entrada ganharam um parâmetro extra, o `escontext`. Quando passamos esse "caderninho
de erros", a função **anota** o problema e devolve `false`, em vez de abortar tudo. Esse mecanismo se chama *soft error*
(erro suave), e foi criado justamente para o `COPY ... ON_ERROR` e o `pg_input_is_valid()`.

- Se devolveu `true`, a conversão deu certo e o valor está em `result`.
- Se devolveu `false`, deu errado e devolvemos o valor padrão (o segundo argumento).

```c
if (PG_ARGISNULL(target_arg))
    PG_RETURN_NULL();
PG_RETURN_DATUM(PG_GETARG_DATUM(target_arg));
```

Se o padrão é `NULL::int`, devolve NULL. Se é `0`, devolve 0.

### As duas funções públicas

```c
Datum pg_try_cast(PG_FUNCTION_ARGS)   { return try_cast_common(fcinfo, 0, 1); }
Datum pg_try_convert(PG_FUNCTION_ARGS) { return try_cast_common(fcinfo, 1, 0); }
```

As duas usam a mesma lógica. Só muda a posição dos argumentos: no `try_cast` o valor vem primeiro, e no `try_convert`
(estilo SQL Server) o tipo vem primeiro.

## 3. Como compilar, instalar e testar

```bash
make                  # compila src/pg_try_cast.c → pg_try_cast.so
sudo make install     # copia .so, .control e .sql para as pastas do PostgreSQL
make installcheck     # roda os testes contra um servidor ativo
```

O `Makefile` é curto porque usa o **PGXS**, o sistema de build de extensões que vem com o PostgreSQL. O `pg_config`
diz ao PGXS onde estão os headers e as pastas de instalação. Se você tem mais de uma versão instalada, escolha com
`make PG_CONFIG=/caminho/para/pg_config`.

### Como os testes funcionam

O `make installcheck` usa o `pg_regress`:

1. Cria um banco temporário (`contrib_regression`).
2. Roda cada arquivo de `test/sql/` no `psql`.
3. Grava a saída em `test/results/` e compara com `test/expected/`.
4. Se for idêntica, o teste é `ok`. Se não for, as diferenças vão para `test/regression.diffs`.

Para **adicionar um teste**:

1. Acrescente os comandos SQL num arquivo de `test/sql/` (ou crie um novo e coloque o nome dele em `REGRESS` no Makefile).
2. Rode `make installcheck`. Vai falhar, porque o esperado ainda não tem a saída nova.
3. Abra `test/results/<arquivo>.out` e **confira linha por linha** se a saída está correta.
4. Se estiver, copie para `test/expected/`: `cp test/results/<arquivo>.out test/expected/`.
5. Rode de novo e veja passar.

## 4. Ideias para a versão 1.1

Se quiser evoluir a extensão, algumas ideias, da mais simples para a mais trabalhosa:

- **`try_cast_error(valor, tipo)`**: devolve a mensagem de erro em vez do valor, útil para relatórios de importação.
  Basta setar `escontext.details_wanted = true` e ler `escontext.error_data->message`.
- **Entrada de qualquer tipo**: trocar `text` por `"any"` no SQL e converter o valor para texto com a função de
  saída do tipo antes de chamar a de entrada.
- **Agregação de diagnóstico**: uma função que conta quantos valores de uma coluna falham para cada tipo candidato,
  para ajudar a descobrir "que tipo essa coluna deveria ter?".

Para lançar uma versão nova, crie `pg_try_cast--1.0--1.1.sql` (o script que atualiza uma instalação 1.0 existente) e
`pg_try_cast--1.1.sql` (a instalação do zero), mude `default_version` no `.control` e acrescente os dois em `DATA` no
Makefile. Quem já tem a 1.0 atualiza com `ALTER EXTENSION pg_try_cast UPDATE;`.

## 5. Leitura recomendada

- Documentação oficial, "Packaging Related Objects into an Extension":
  <https://www.postgresql.org/docs/current/extend-extensions.html>
- Documentação oficial, funções em C: <https://www.postgresql.org/docs/current/xfunc-c.html>
- Documentação oficial, PGXS: <https://www.postgresql.org/docs/current/extend-pgxs.html>
