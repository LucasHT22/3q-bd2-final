-- =============================================================================
-- Descrição: Adiciona colunas e tabelas necessárias para o projeto do bimestre
--            sem quebrar a estrutura criada anteriormente.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0.1 — Adicionar colunas em assinantes
-- saldo_creditos: necessário para a RN01 (cobrança mensal)
-- data_ultima_alteracao: necessário para o Gatilho 2.4
-- -----------------------------------------------------------------------------

ALTER TABLE assinantes
    ADD COLUMN IF NOT EXISTS saldo_creditos NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (saldo_creditos >= 0),
    ADD COLUMN IF NOT EXISTS data_ultima_alteracao TIMESTAMPTZ;


-- -----------------------------------------------------------------------------
-- 0.2 — Tabela faturamento_produtoras
-- Registra os minutos consumidos por produtora em cada competência (mês).
-- UNIQUE (produtora_id, competencia) permite UPSERT seguro no cursor da Proc 1.3
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS faturamento_produtoras (
    id             SERIAL PRIMARY KEY,
    produtora_id   INT            NOT NULL REFERENCES produtoras(id) ON DELETE RESTRICT,
    competencia    DATE           NOT NULL,
    minutos_consumidos NUMERIC(12,2) NOT NULL DEFAULT 0
        CHECK (minutos_consumidos >= 0),
    gerado_em      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    UNIQUE (produtora_id, competencia)
);


-- -----------------------------------------------------------------------------
-- 0.3 — Tabela auditoria_log
-- Grava toda alteração sensível (Gatilho 2.3).
-- JSONB para valor_antigo e valor_novo permite capturar a linha inteira
-- sem precisar listar campos — resistente a mudanças de schema futuras.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS auditoria_log (
    id           BIGSERIAL    PRIMARY KEY,
    tabela       VARCHAR(100) NOT NULL,
    operacao     VARCHAR(10)  NOT NULL CHECK (operacao IN ('INSERT','UPDATE','DELETE')),
    usuario      VARCHAR(100) NOT NULL,
    valor_antigo JSONB,
    valor_novo   JSONB,
    data_hora    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- -----------------------------------------------------------------------------
-- 0.4 — Tabela resumo_reproducao
-- Mantida pelo Gatilho 2.5 (FOR EACH STATEMENT).
-- Tem exatamente uma linha que é atualizada a cada INSERT em historico_reproducoes.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resumo_reproducao (
    id            SERIAL  PRIMARY KEY,
    total_acessos BIGINT  NOT NULL DEFAULT 0
);

-- Garante que a linha de resumo existe
INSERT INTO resumo_reproducao (total_acessos)
SELECT 0
WHERE NOT EXISTS (SELECT 1 FROM resumo_reproducao);


-- -----------------------------------------------------------------------------
-- Verificação rápida
-- -----------------------------------------------------------------------------
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'assinantes'
ORDER BY ordinal_position;