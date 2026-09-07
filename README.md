# StreamFlow

Desenvolvido em **PostgreSQL** como trabalho da disciplina de Banco de Dados II.

---

## Estrutura dos arquivos

| Arquivo | Conteúdo |
|---|---|
| `3q-main.sql` | Adaptações no schema do bimestre anterior |
| `3q-procedures-and-functions.sql` | Stored Procedures e Stored Functions |
| `3q-triggers.sql` | Gatilhos (Triggers) |
| `3q-exceptions.sql` | Exceções revisadas |
| `/orm-mapping` | Mapeamento ORM (Prisma) |

---

## Como executar

Execute os arquivos **nesta ordem** — cada parte depende da anterior:

```bash
psql -U postgres -d streamflow -f 3q-main.sql
psql -U postgres -d streamflow -f 3q-procedures-and-functions.sql
psql -U postgres -d streamflow -f 3q-triggers.sql
psql -U postgres -d streamflow -f 3q-exceptions.sql
```

---

## O que cada parte entrega

### Parte 0 — Adaptações no schema

Adiciona o que faltava no schema do bimestre anterior sem quebrar nada:

- `saldo_creditos` e `data_ultima_alteracao` em `assinantes`
- Tabela `faturamento_produtoras` (com UNIQUE para UPSERT seguro)
- Tabela `auditoria_log` (com JSONB para capturar linha inteira)
- Tabela `resumo_reproducao` (mantida pelo gatilho de instrução)

---

### Parte 1 — Stored Procedures e Functions

| Objeto | O que faz |
|---|---|
| `realizar_cobranca_mensal(id, valor)` | Debita mensalidade com checagem de saldo (RN01). `FOR UPDATE` evita race condition. |
| `registrar_reproducao(perfil, video, ip, dispositivo)` | Registra um "Play" e retorna o ID criado via `RETURNING`. |
| `gerar_faturamento_mensal(competencia)` | Percorre produtoras com cursor e faz UPSERT em `faturamento_produtoras`. |
| `minutos_assistidos_por_produtora(id, competencia)` | Retorna soma de minutos. Classificada como `STABLE`. |
| `calcular_idade(data_nascimento)` | Retorna idade em anos. Classificada como `IMMUTABLE`. Usada na view LGPD. |

**Por que `STABLE` e não `IMMUTABLE` em `minutos_assistidos_por_produtora`:**
a função consulta `historico_reproducoes`, que pode mudar entre transações — logo o mesmo input pode retornar valores diferentes ao longo do tempo.

**Por que `IMMUTABLE` em `calcular_idade`:**
depende apenas do parâmetro recebido, sem acesso a nenhuma tabela.

---

### Parte 2 — Triggers

| Gatilho | Tabela | Momento | O que faz |
|---|---|---|---|
| `trg_saldo_nunca_negativo` | `assinantes` | BEFORE INSERT OR UPDATE | Bloqueia qualquer operação que deixe `saldo_creditos < 0` (RN01) |
| `trg_historico_imutavel` | `historico_reproducoes` | BEFORE UPDATE OR DELETE | Bloqueia DELETE e UPDATE nos campos de auditoria (RN03). Permite atualizar apenas `segundos_assistidos` e `concluido`. |
| `trg_auditoria_perfis` | `perfis` | AFTER UPDATE | Grava linha inteira (OLD e NEW como JSONB) em `auditoria_log` com `CURRENT_USER` |
| `trg_timestamp_assinantes` | `assinantes` | BEFORE UPDATE | Mantém `data_ultima_alteracao` sempre atualizado |
| `trg_normaliza_nome` | `assinantes` | BEFORE INSERT | Aplica `UPPER(TRIM(nome))` antes de gravar |
| `trg_resumo_reproducao` | `historico_reproducoes` | AFTER INSERT (STATEMENT) | Recalcula `resumo_reproducao` uma única vez por comando, não por linha |

**Trigger vs CHECK (RN01):**
`CHECK (saldo_creditos >= 0)` valida o campo mas não emite mensagem customizada.
A trigger complementa com contexto (qual assinante, qual valor) e cobre cenários
onde a restrição viria de uma expressão complexa no UPDATE.

**Por que `FOR EACH STATEMENT` no resumo:**
um `INSERT` em batch de 10.000 linhas rodaria a função 10.000 vezes com `FOR EACH ROW`.
Com `FOR EACH STATEMENT`, roda uma única vez depois de todas as inserções — resultado
idêntico, custo radicalmente menor.

---

### Parte 3 — Tratamento de Exceções

Todas as procedures foram revisadas com exceções nomeadas do PostgreSQL:

| Exceção | SQLSTATE | Quando ocorre |
|---|---|---|
| `foreign_key_violation` | 23503 | FK inexistente (perfil, vídeo, produtora) |
| `check_violation` | 23514 | Dispositivo inválido, saldo negativo via CHECK |
| `not_null_violation` | 23502 | Campo obrigatório nulo |
| `unique_violation` | 23505 | Registro duplicado |
| `OTHERS` + `SQLERRM` | — | Qualquer erro não previsto |

A procedure `gerar_faturamento_mensal` usa sub-bloco `BEGIN ... EXCEPTION ... END`
dentro do loop do cursor — erros em uma produtora são logados com `RAISE WARNING`
sem abortar o processamento das demais.

---

## SGBD

PostgreSQL 15+

Sintaxe específica utilizada: `LANGUAGE plpgsql`, `RAISE EXCEPTION/NOTICE/WARNING`,
`RETURNING`, `ON CONFLICT ... DO UPDATE`, `FOR UPDATE`, `row_to_json()`, `INET`,
`TIMESTAMPTZ`, `JSONB`, `DATE_TRUNC`, `MODE() WITHIN GROUP`.