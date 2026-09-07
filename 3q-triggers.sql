
-- =============================================================================
-- GATILHO 2.1 — Saldo nunca negativo (RN01)
-- Tabela: assinantes | Momento: BEFORE INSERT OR UPDATE
--
-- Decisão de BEFORE:
--   A rejeição precisa acontecer ANTES da linha ser gravada. Com AFTER, o dado
--   já estaria na tabela e o rollback seria mais custoso semanticamente.
--
-- Decisão de FOR EACH ROW:
--   Cada linha inserida ou atualizada precisa ser verificada individualmente,
--   porque o saldo é um campo por assinante.
--
-- Comparação com CHECK constraint:
--   Poderíamos usar CHECK (saldo_creditos >= 0) na tabela — e de fato foi
--   adicionado na Parte 0. O gatilho é complementar: enquanto o CHECK valida
--   o valor final do campo, o gatilho pode emitir uma mensagem de erro
--   personalizada com contexto (qual assinante, qual era o saldo), enquanto
--   o CHECK só diz "check_violation" sem mais detalhes. Além disso, o gatilho
--   pode ser acionado mesmo em cenários onde o CHECK não seria suficiente —
--   como um UPDATE que deriva o novo saldo de uma expressão complexa.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_saldo_nunca_negativo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.saldo_creditos < 0 THEN
        RAISE EXCEPTION
            'RN01 violada: saldo não pode ser negativo. Assinante: %, saldo resultante: R$ %.',
            NEW.id, NEW.saldo_creditos
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

-- Remove se existir para evitar erro em re-execução
DROP TRIGGER IF EXISTS trg_saldo_nunca_negativo ON assinantes;

CREATE TRIGGER trg_saldo_nunca_negativo
    BEFORE INSERT OR UPDATE ON assinantes
    FOR EACH ROW EXECUTE FUNCTION fn_saldo_nunca_negativo();

-- -----------------------------------------------------------------------------
-- TESTES — Gatilho 2.1
-- -----------------------------------------------------------------------------

-- Preparação
UPDATE assinantes SET saldo_creditos = 50.00 WHERE id = 1;

-- Teste 1 — VÁLIDO: saldo positivo
UPDATE assinantes SET saldo_creditos = 80.00 WHERE id = 1;
SELECT id, saldo_creditos FROM assinantes WHERE id = 1;
-- Esperado: 80.00

-- Teste 2 — INVÁLIDO: tentativa de setar saldo negativo direto
DO $$
BEGIN
    UPDATE assinantes SET saldo_creditos = -10.00 WHERE id = 1;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 2.1 - INVÁLIDO] %', SQLERRM;
END;
$$;
-- Esperado: erro 'RN01 violada...'

-- Confirma que o saldo não foi alterado
SELECT id, saldo_creditos FROM assinantes WHERE id = 1;
-- Esperado: ainda 80.00


-- =============================================================================
-- GATILHO 2.2 — Imutabilidade do histórico (RN03)
-- Tabela: historico_reproducoes | Momento: BEFORE UPDATE e BEFORE DELETE
--
-- Nota: o schema anterior já continha fn_log_imutavel e trg_log_imutavel
-- cobrindo exatamente esta regra. Recriamos aqui com nomenclatura alinhada
-- ao enunciado e mensagens mais explicativas.
--
-- Decisão de BEFORE UPDATE (parcial):
--   A trigger bloqueia UPDATE nos campos de auditoria (perfil_id, video_id,
--   ip_conexao, dispositivo, iniciado_em), mas PERMITE atualizar
--   segundos_assistidos e concluido — que é o caso de uso legítimo
--   (reportar progresso de reprodução).
--
-- Decisão de BEFORE DELETE:
--   Nenhum registro de histórico pode ser apagado. Isso garante que o log
--   seja uma evidência confiável mesmo que alguém acesse o banco diretamente.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_historico_imutavel()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Bloqueia DELETE incondicional
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'RN03 violada: registros de historico_reproducoes não podem ser excluídos.'
            USING ERRCODE = 'P0003';
    END IF;

    -- Bloqueia UPDATE nos campos de auditoria
    IF TG_OP = 'UPDATE' THEN
        IF OLD.perfil_id    <> NEW.perfil_id    OR
           OLD.video_id     <> NEW.video_id     OR
           OLD.ip_conexao   <> NEW.ip_conexao   OR
           OLD.dispositivo  <> NEW.dispositivo  OR
           OLD.iniciado_em  <> NEW.iniciado_em  THEN
            RAISE EXCEPTION
                'RN03 violada: campos de auditoria são imutáveis após inserção. '
                'Apenas segundos_assistidos e concluido podem ser atualizados.'
                USING ERRCODE = 'P0003';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_historico_imutavel ON historico_reproducoes;

CREATE TRIGGER trg_historico_imutavel
    BEFORE UPDATE OR DELETE ON historico_reproducoes
    FOR EACH ROW EXECUTE FUNCTION fn_historico_imutavel();

-- -----------------------------------------------------------------------------
-- TESTES — Gatilho 2.2
-- -----------------------------------------------------------------------------

-- Preparação: insere uma reprodução de teste
INSERT INTO historico_reproducoes
    (perfil_id, video_id, ip_conexao, dispositivo, iniciado_em, segundos_assistidos, concluido)
VALUES
    (1, 1, '10.0.0.1', 'Web', NOW(), 0, FALSE);

-- Guarda o ID criado
DO $$
DECLARE v_id BIGINT;
BEGIN
    SELECT MAX(id) INTO v_id FROM historico_reproducoes WHERE perfil_id = 1;
    RAISE NOTICE 'ID de teste criado: %', v_id;
END;
$$;

-- Teste 1 — VÁLIDO: atualizar progresso (permitido)
UPDATE historico_reproducoes
SET segundos_assistidos = 600, concluido = TRUE
WHERE id = (SELECT MAX(id) FROM historico_reproducoes WHERE perfil_id = 1);
-- Esperado: UPDATE 1

-- Teste 2 — INVÁLIDO: tentar mudar o IP
DO $$
BEGIN
    UPDATE historico_reproducoes
    SET ip_conexao = '192.168.1.1'
    WHERE id = (SELECT MAX(id) FROM historico_reproducoes WHERE perfil_id = 1);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 2.2 - INVÁLIDO] %', SQLERRM;
END;
$$;

-- Teste 3 — INVÁLIDO: tentar deletar
DO $$
BEGIN
    DELETE FROM historico_reproducoes
    WHERE id = (SELECT MAX(id) FROM historico_reproducoes WHERE perfil_id = 1);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 2.2 - INVÁLIDO] %', SQLERRM;
END;
$$;


-- =============================================================================
-- GATILHO 2.3 — Auditoria de alterações (RN04)
-- Tabela: perfis | Momento: AFTER UPDATE
--
-- Decisão de AFTER:
--   O log de auditoria deve refletir o que DE FATO foi gravado. Um BEFORE
--   poderia logar uma alteração que depois fosse cancelada por outra trigger.
--   AFTER garante que o registro em auditoria_log só existe se o UPDATE
--   realmente foi confirmado.
--
-- Uso de OLD e NEW:
--   OLD contém a linha antes da alteração, NEW contém depois.
--   row_to_json() serializa a linha inteira como JSONB — qualquer coluna
--   futura adicionada à tabela será automaticamente capturada.
--
-- CURRENT_USER:
--   Retorna o usuário de banco de dados que executou o comando — app_streamflow,
--   analista_auditoria, ou qualquer outro. Isso permite rastrear qual role
--   fez a alteração, não apenas que ela aconteceu.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_auditoria_perfis()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO auditoria_log
        (tabela, operacao, usuario, valor_antigo, valor_novo, data_hora)
    VALUES (
        TG_TABLE_NAME,               -- nome da tabela que disparou
        TG_OP,                       -- 'UPDATE'
        CURRENT_USER,                -- usuário do banco que executou
        row_to_json(OLD)::JSONB,     -- linha inteira antes
        row_to_json(NEW)::JSONB,     -- linha inteira depois
        NOW()
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auditoria_perfis ON perfis;

CREATE TRIGGER trg_auditoria_perfis
    AFTER UPDATE ON perfis
    FOR EACH ROW EXECUTE FUNCTION fn_auditoria_perfis();

-- -----------------------------------------------------------------------------
-- TESTES — Gatilho 2.3
-- -----------------------------------------------------------------------------

-- Teste 1 — Altera nome de exibição e verifica log
UPDATE perfis SET nome_exibicao = 'Perfil Teste Auditoria' WHERE id = 1;

SELECT
    tabela,
    operacao,
    usuario,
    valor_antigo->>'nome_exibicao' AS nome_antes,
    valor_novo->>'nome_exibicao'   AS nome_depois,
    data_hora
FROM auditoria_log
ORDER BY data_hora DESC
LIMIT 5;


-- =============================================================================
-- GATILHO 2.4a — Timestamp automático de alteração
-- Tabela: assinantes | Momento: BEFORE UPDATE
--
-- Decisão de BEFORE:
--   Precisa modificar NEW.data_ultima_alteracao antes da linha ser gravada.
--   Com AFTER, o campo teria que ser atualizado com um segundo UPDATE — o que
--   dispararia a trigger de novo, criando loop infinito.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_timestamp_alteracao()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.data_ultima_alteracao = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_timestamp_assinantes ON assinantes;

CREATE TRIGGER trg_timestamp_assinantes
    BEFORE UPDATE ON assinantes
    FOR EACH ROW EXECUTE FUNCTION fn_timestamp_alteracao();


-- =============================================================================
-- GATILHO 2.4b — Normalização do nome no INSERT
-- Tabela: assinantes | Momento: BEFORE INSERT
--
-- UPPER(TRIM(nome)) garante que 'lucas silva', '  LUCAS SILVA  ' e
-- 'Lucas Silva' todos virem 'LUCAS SILVA' no banco, independente do que
-- a aplicação mandou. Isso evita duplicatas por diferença de caixa e
-- espaços extras — especialmente útil em dados vindos de formulários web.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_normaliza_nome_assinante()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.nome = UPPER(TRIM(NEW.nome));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normaliza_nome ON assinantes;

CREATE TRIGGER trg_normaliza_nome
    BEFORE INSERT ON assinantes
    FOR EACH ROW EXECUTE FUNCTION fn_normaliza_nome_assinante();

-- -----------------------------------------------------------------------------
-- TESTES — Gatilho 2.4
-- -----------------------------------------------------------------------------

-- Teste INSERT com nome sujo
INSERT INTO assinantes
    (nome, email, cpf, data_nascimento, uf, saldo_creditos)
VALUES
    ('  maria souza  ', 'maria.teste@email.com', '98765432100', '1990-06-15', 'RJ', 50.00);

SELECT nome, data_ultima_alteracao
FROM assinantes
WHERE email = 'maria.teste@email.com';
-- Esperado: nome = 'MARIA SOUZA', data_ultima_alteracao = NULL (ainda não houve UPDATE)

-- Teste UPDATE dispara timestamp
UPDATE assinantes SET plano = 'padrao' WHERE email = 'maria.teste@email.com';

SELECT nome, plano, data_ultima_alteracao
FROM assinantes
WHERE email = 'maria.teste@email.com';
-- Esperado: data_ultima_alteracao preenchida com NOW()


-- =============================================================================
-- GATILHO 2.5 — Recálculo de resumo (FOR EACH STATEMENT) — BÔNUS
-- Tabela: historico_reproducoes | Momento: AFTER INSERT
--
-- FOR EACH STATEMENT vs FOR EACH ROW:
--   Com FOR EACH ROW, em um INSERT de 10.000 linhas (ex: carga em batch),
--   a função rodaria 10.000 vezes — cada vez fazendo COUNT(*) na tabela inteira.
--   Isso é O(n²) de trabalho: 10k INSERTs × COUNT de crescente = custo enorme.
--
--   Com FOR EACH STATEMENT, a função roda UMA ÚNICA VEZ depois que todas as
--   10.000 linhas foram inseridas. O COUNT(*) roda uma vez sobre o estado final.
--   Resultado idêntico, custo radicalmente menor em cargas em batch.
--
-- RETURN NULL:
--   Triggers FOR EACH STATEMENT não têm acesso a NEW/OLD — não há "uma linha"
--   de referência. Por isso a função retorna NULL (obrigatório).
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_recalcula_resumo_reproducao()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE resumo_reproducao
    SET total_acessos = (SELECT COUNT(*) FROM historico_reproducoes);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_resumo_reproducao ON historico_reproducoes;

CREATE TRIGGER trg_resumo_reproducao
    AFTER INSERT ON historico_reproducoes
    FOR EACH STATEMENT EXECUTE FUNCTION fn_recalcula_resumo_reproducao();

-- -----------------------------------------------------------------------------
-- TESTES — Gatilho 2.5
-- -----------------------------------------------------------------------------

-- Estado antes
SELECT total_acessos FROM resumo_reproducao;

-- Insere uma nova reprodução
INSERT INTO historico_reproducoes
    (perfil_id, video_id, ip_conexao, dispositivo, iniciado_em, segundos_assistidos, concluido)
VALUES
    (1, 1, '172.16.0.5', 'Tablet', NOW(), 120, FALSE);

-- Confirma que o resumo foi atualizado automaticamente
SELECT total_acessos FROM resumo_reproducao;
-- Esperado: valor anterior + 1