-- =============================================================================
-- STREAMFLOW — PARTE 3: REVISÃO COM TRATAMENTO DE EXCEÇÕES COMPLETO
-- SGBD: PostgreSQL
-- Autor: Lucas
--
-- Documentação de erros possíveis por procedure:
--
-- realizar_cobranca_mensal:
--   - P0002 (custom): assinante não encontrado
--   - P0003 (custom): valor <= 0
--   - P0001 (custom): saldo insuficiente
--   - P0001 via trigger trg_saldo_nunca_negativo: UPDATE deixaria saldo negativo
--
-- registrar_reproducao:
--   - 23503 (foreign_key_violation): perfil_id ou video_id inexistente
--   - 23514 (check_violation): dispositivo fora do enum
--   - 22P02 (invalid_text_representation): IP mal formatado
--   - OTHERS: qualquer erro não previsto
--
-- gerar_faturamento_mensal:
--   - 23503 (foreign_key_violation): produtora_id inválida (improvável pois
--     o cursor vem da própria tabela produtoras, mas capturado por segurança)
--   - OTHERS: erro inesperado no loop do cursor
-- =============================================================================


-- =============================================================================
-- PROCEDURE 1.1 REVISADA — com tratamento de exceções completo
-- =============================================================================

CREATE OR REPLACE PROCEDURE realizar_cobranca_mensal(
    IN  p_assinante_id  INT,
    IN  p_valor         NUMERIC(10,2),
    OUT p_novo_saldo    NUMERIC(10,2)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_saldo_atual NUMERIC(10,2);
BEGIN
    -- Trava a linha para leitura consistente em ambiente concorrente
    SELECT saldo_creditos
    INTO   v_saldo_atual
    FROM   assinantes
    WHERE  id = p_assinante_id
    FOR UPDATE;

    -- Verifica se o assinante existe
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assinante % não encontrado.', p_assinante_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Valor deve ser positivo
    IF p_valor <= 0 THEN
        RAISE EXCEPTION 'Valor de cobrança inválido: R$ %. Informe um valor maior que zero.', p_valor
            USING ERRCODE = 'P0003';
    END IF;

    -- RN01: saldo suficiente
    IF v_saldo_atual < p_valor THEN
        RAISE EXCEPTION
            'Saldo insuficiente. Assinante: %, saldo atual: R$ %, cobrança: R$ %.',
            p_assinante_id, v_saldo_atual, p_valor
            USING ERRCODE = 'P0001';
    END IF;

    -- Débito — a trigger trg_saldo_nunca_negativo serve como segunda camada
    UPDATE assinantes
    SET    saldo_creditos = saldo_creditos - p_valor
    WHERE  id = p_assinante_id
    RETURNING saldo_creditos INTO p_novo_saldo;

EXCEPTION
    -- Erros customizados: relança com a mensagem já formatada
    WHEN SQLSTATE 'P0001' OR SQLSTATE 'P0002' OR SQLSTATE 'P0003' THEN
        RAISE;
    -- Check violation: trigger de saldo negativo disparou
    WHEN check_violation THEN
        RAISE EXCEPTION
            'Operação bloqueada por restrição de integridade: saldo não pode ser negativo.';
    -- Qualquer outro erro inesperado
    WHEN OTHERS THEN
        RAISE EXCEPTION
            'Erro inesperado na cobrança do assinante %. Código: % — %',
            p_assinante_id, SQLSTATE, SQLERRM;
END;
$$;


-- =============================================================================
-- PROCEDURE 1.2 REVISADA — com exceções nomeadas
-- =============================================================================

CREATE OR REPLACE PROCEDURE registrar_reproducao(
    IN  p_perfil_id   INT,
    IN  p_video_id    INT,
    IN  p_ip          INET,
    IN  p_dispositivo VARCHAR(20),
    OUT p_id_criado   BIGINT
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO historico_reproducoes
        (perfil_id, video_id, ip_conexao, dispositivo,
         iniciado_em, segundos_assistidos, concluido)
    VALUES
        (p_perfil_id, p_video_id, p_ip, p_dispositivo,
         NOW(), 0, FALSE)
    RETURNING id INTO p_id_criado;

EXCEPTION
    -- FK violada: perfil ou vídeo não existe
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION
            'Perfil (id=%) ou vídeo (id=%) não encontrado.',
            p_perfil_id, p_video_id
            USING ERRCODE = '23503';
    -- CHECK violado: dispositivo inválido
    WHEN check_violation THEN
        RAISE EXCEPTION
            'Dispositivo inválido: %. Valores aceitos: SmartTV, Smartphone, Tablet, Web, Console, Outro.',
            p_dispositivo
            USING ERRCODE = '23514';
    -- NOT NULL violado: campo obrigatório nulo
    WHEN not_null_violation THEN
        RAISE EXCEPTION
            'Campo obrigatório ausente. Verifique perfil_id, video_id, ip_conexao e dispositivo.'
            USING ERRCODE = '23502';
    -- Qualquer outro
    WHEN OTHERS THEN
        RAISE EXCEPTION
            'Erro ao registrar reprodução. Código: % — %', SQLSTATE, SQLERRM;
END;
$$;


-- =============================================================================
-- PROCEDURE 1.3 REVISADA — com tratamento de erro no loop do cursor
-- =============================================================================

CREATE OR REPLACE PROCEDURE gerar_faturamento_mensal(
    IN p_competencia DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_produtora_id INT;
    v_minutos      NUMERIC(12,2);
    v_erro_count   INT := 0;

    cur_produtoras CURSOR FOR
        SELECT id FROM produtoras ORDER BY id;
BEGIN
    OPEN cur_produtoras;

    LOOP
        FETCH cur_produtoras INTO v_produtora_id;
        EXIT WHEN NOT FOUND;

        BEGIN  -- sub-bloco para capturar erro por produtora sem abortar o loop

            SELECT COALESCE(SUM(hr.segundos_assistidos) / 60.0, 0)
            INTO   v_minutos
            FROM   historico_reproducoes hr
                   INNER JOIN videos    v ON v.id = hr.video_id
                   INNER JOIN conteudos c ON c.id = v.conteudo_id
            WHERE  c.produtora_id = v_produtora_id
              AND  DATE_TRUNC('month', hr.iniciado_em) =
                   DATE_TRUNC('month', p_competencia);

            INSERT INTO faturamento_produtoras
                (produtora_id, competencia, minutos_consumidos)
            VALUES
                (v_produtora_id, DATE_TRUNC('month', p_competencia)::DATE, v_minutos)
            ON CONFLICT (produtora_id, competencia)
            DO UPDATE SET
                minutos_consumidos = EXCLUDED.minutos_consumidos,
                gerado_em          = NOW();

            RAISE NOTICE 'Produtora %: % min faturados.', v_produtora_id, v_minutos;

        EXCEPTION
            WHEN OTHERS THEN
                -- Loga o erro mas continua para a próxima produtora
                v_erro_count := v_erro_count + 1;
                RAISE WARNING
                    'Erro ao processar produtora %: % (SQLSTATE: %)',
                    v_produtora_id, SQLERRM, SQLSTATE;
        END;

    END LOOP;

    CLOSE cur_produtoras;

    IF v_erro_count > 0 THEN
        RAISE WARNING 'Faturamento concluído com % erro(s). Verifique os logs.', v_erro_count;
    ELSE
        RAISE NOTICE 'Faturamento de % concluído sem erros.', TO_CHAR(p_competencia, 'MM/YYYY');
    END IF;
END;
$$;
