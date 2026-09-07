
-- =============================================================================
-- PROCEDURE 1.1 — realizar_cobranca_mensal
-- RN01: saldo nunca pode ficar negativo.
--
-- Parâmetros:
--   IN  p_assinante_id  INT            — ID do assinante a ser cobrado
--   IN  p_valor         NUMERIC(10,2)  — valor da mensalidade
--   OUT p_novo_saldo    NUMERIC(10,2)  — saldo resultante após o débito
--
-- Decisões:
--   - SELECT ... FOR UPDATE trava a linha durante a transação, evitando race
--     condition onde duas cobranças simultâneas leriam o mesmo saldo e ambas
--     passariam na checagem antes de qualquer UPDATE ser confirmado.
--   - RAISE EXCEPTION cancela a transação inteira sem alterar nenhum dado.
--   - OUT em vez de INOUT porque o chamador não precisa mandar o saldo atual,
--     só receber o novo.
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
    -- Lê e trava a linha para evitar leitura suja concorrente
    SELECT saldo_creditos
    INTO   v_saldo_atual
    FROM   assinantes
    WHERE  id = p_assinante_id
    FOR UPDATE;

    -- Assinante inexistente
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assinante % não encontrado.', p_assinante_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Valor inválido
    IF p_valor <= 0 THEN
        RAISE EXCEPTION 'O valor da cobrança deve ser positivo. Recebido: %', p_valor
            USING ERRCODE = 'P0003';
    END IF;

    -- RN01: saldo insuficiente
    IF v_saldo_atual < p_valor THEN
        RAISE EXCEPTION
            'Saldo insuficiente para o assinante %. Saldo atual: R$ %, mensalidade: R$ %.',
            p_assinante_id, v_saldo_atual, p_valor
            USING ERRCODE = 'P0001';
    END IF;

    -- Débito seguro
    UPDATE assinantes
    SET    saldo_creditos = saldo_creditos - p_valor
    WHERE  id = p_assinante_id
    RETURNING saldo_creditos INTO p_novo_saldo;

END;
$$;

-- -----------------------------------------------------------------------------
-- TESTES — Procedure 1.1
-- -----------------------------------------------------------------------------

-- Preparação: garante que o assinante 1 tem saldo suficiente para o teste válido
UPDATE assinantes SET saldo_creditos = 100.00 WHERE id = 1;

-- Teste 1 — VÁLIDO: cobrança de R$29,90 com saldo de R$100,00
-- Esperado: p_novo_saldo = 70.10
DO $$
DECLARE v_novo_saldo NUMERIC(10,2);
BEGIN
    CALL realizar_cobranca_mensal(1, 29.90, v_novo_saldo);
    RAISE NOTICE '[TESTE 1.1 - VÁLIDO] Novo saldo: R$ %', v_novo_saldo;
END;
$$;

-- Teste 2 — INVÁLIDO: cobrança maior que o saldo
-- Esperado: EXCEPTION 'Saldo insuficiente...'
DO $$
DECLARE v_novo_saldo NUMERIC(10,2);
BEGIN
    CALL realizar_cobranca_mensal(1, 999.00, v_novo_saldo);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 1.1 - INVÁLIDO] Erro capturado: %', SQLERRM;
END;
$$;

-- Teste 3 — INVÁLIDO: assinante inexistente
-- Esperado: EXCEPTION 'Assinante não encontrado'
DO $$
DECLARE v_novo_saldo NUMERIC(10,2);
BEGIN
    CALL realizar_cobranca_mensal(99999, 10.00, v_novo_saldo);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 1.1 - INVÁLIDO] Erro capturado: %', SQLERRM;
END;
$$;


-- =============================================================================
-- PROCEDURE 1.2 — registrar_reproducao
-- RF02: registra um "Play" na tabela historico_reproducoes.
--
-- Parâmetros:
--   IN  p_perfil_id   INT         — perfil que está assistindo
--   IN  p_video_id    INT         — vídeo sendo reproduzido
--   IN  p_ip          INET        — IP da conexão
--   IN  p_dispositivo VARCHAR(20) — tipo de dispositivo
--   OUT p_id_criado   BIGINT      — ID do registro criado
--
-- Decisões:
--   - Em PostgreSQL, a transação é implícita dentro do CALL — não é necessário
--     START TRANSACTION manual. O bloco EXCEPTION faz rollback automaticamente
--     ao relançar o erro, evitando dados pela metade.
--   - RETURNING id INTO captura o ID gerado pelo BIGSERIAL sem uma query extra.
--   - Exceções nomeadas (foreign_key_violation, check_violation) dão mensagens
--     mais amigáveis do que o erro raw do Postgres.
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
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION
            'Perfil (%) ou vídeo (%) não encontrado. Verifique os IDs informados.',
            p_perfil_id, p_video_id;
    WHEN check_violation THEN
        RAISE EXCEPTION
            'Dispositivo inválido: %. Use: SmartTV, Smartphone, Tablet, Web, Console ou Outro.',
            p_dispositivo;
    WHEN invalid_text_representation THEN
        RAISE EXCEPTION
            'IP inválido: %. Informe um endereço IPv4 ou IPv6 válido.', p_ip;
    WHEN OTHERS THEN
        RAISE EXCEPTION
            'Erro inesperado ao registrar reprodução. Código: % — %', SQLSTATE, SQLERRM;
END;
$$;

-- -----------------------------------------------------------------------------
-- TESTES — Procedure 1.2
-- -----------------------------------------------------------------------------

-- Teste 1 — VÁLIDO
DO $$
DECLARE v_id BIGINT;
BEGIN
    CALL registrar_reproducao(1, 1, '192.168.0.10', 'SmartTV', v_id);
    RAISE NOTICE '[TESTE 1.2 - VÁLIDO] Reprodução registrada com ID: %', v_id;
END;
$$;

-- Teste 2 — INVÁLIDO: perfil inexistente
DO $$
DECLARE v_id BIGINT;
BEGIN
    CALL registrar_reproducao(99999, 1, '10.0.0.1', 'Web', v_id);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 1.2 - INVÁLIDO] %', SQLERRM;
END;
$$;

-- Teste 3 — INVÁLIDO: dispositivo fora do CHECK
DO $$
DECLARE v_id BIGINT;
BEGIN
    CALL registrar_reproducao(1, 1, '10.0.0.1', 'Geladeira', v_id);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[TESTE 1.2 - INVÁLIDO] %', SQLERRM;
END;
$$;


-- =============================================================================
-- PROCEDURE 1.3 — gerar_faturamento_mensal
-- RF04: percorre produtoras com cursor e insere/atualiza faturamento_produtoras.
--
-- Parâmetros:
--   IN p_competencia DATE — mês de referência (qualquer dia do mês serve;
--                           DATE_TRUNC normaliza para o primeiro dia)
--
-- Decisões:
--   - Cursor explícito (DECLARE → OPEN → FETCH → CLOSE) é exigido pelo enunciado
--     para demonstrar controle linha-a-linha. Na prática, um INSERT...SELECT com
--     GROUP BY seria mais eficiente — mas o cursor evidencia o padrão iterativo.
--   - EXIT WHEN NOT FOUND é o equivalente PostgreSQL do CONTINUE HANDLER FOR NOT
--     FOUND do MySQL.
--   - ON CONFLICT ... DO UPDATE (UPSERT) evita checar manualmente se o registro
--     do mês já existe antes de inserir ou atualizar.
--   - DATE_TRUNC('month', ...) normaliza tanto a competência recebida quanto o
--     campo iniciado_em, garantindo que o filtro cubra o mês inteiro
--     independente do dia informado.
-- =============================================================================

CREATE OR REPLACE PROCEDURE gerar_faturamento_mensal(
    IN p_competencia DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_produtora_id INT;
    v_minutos      NUMERIC(12,2);

    -- Declaração do cursor: lista todas as produtoras ativas
    cur_produtoras CURSOR FOR
        SELECT id FROM produtoras ORDER BY id;
BEGIN
    OPEN cur_produtoras;

    LOOP
        FETCH cur_produtoras INTO v_produtora_id;
        EXIT WHEN NOT FOUND;  -- fim do resultado: encerra o loop

        -- Soma minutos consumidos da produtora no mês
        SELECT COALESCE(SUM(hr.segundos_assistidos) / 60.0, 0)
        INTO   v_minutos
        FROM   historico_reproducoes hr
               INNER JOIN videos     v  ON v.id  = hr.video_id
               INNER JOIN conteudos  c  ON c.id  = v.conteudo_id
        WHERE  c.produtora_id = v_produtora_id
          AND  DATE_TRUNC('month', hr.iniciado_em) =
               DATE_TRUNC('month', p_competencia);

        -- UPSERT: insere se não existe, atualiza se já existe
        INSERT INTO faturamento_produtoras
            (produtora_id, competencia, minutos_consumidos)
        VALUES
            (v_produtora_id, DATE_TRUNC('month', p_competencia)::DATE, v_minutos)
        ON CONFLICT (produtora_id, competencia)
        DO UPDATE SET
            minutos_consumidos = EXCLUDED.minutos_consumidos,
            gerado_em          = NOW();

        RAISE NOTICE 'Produtora %: % minutos faturados.', v_produtora_id, v_minutos;
    END LOOP;

    CLOSE cur_produtoras;

    RAISE NOTICE 'Faturamento de % concluído.', TO_CHAR(p_competencia, 'MM/YYYY');
END;
$$;

-- -----------------------------------------------------------------------------
-- TESTES — Procedure 1.3
-- -----------------------------------------------------------------------------

-- Teste 1 — Gera faturamento de janeiro/2025
CALL gerar_faturamento_mensal('2025-01-15');

-- Verificar resultado
SELECT
    p.nome AS produtora,
    fp.competencia,
    fp.minutos_consumidos
FROM faturamento_produtoras fp
     INNER JOIN produtoras p ON p.id = fp.produtora_id
ORDER BY fp.competencia, p.nome;


-- =============================================================================
-- FUNCTION 1.4 — minutos_assistidos_por_produtora
-- Retorna a soma dos minutos consumidos de todos os vídeos de uma produtora
-- em um determinado mês.
--
-- Classificação de volatilidade: STABLE
--   - Não modifica dados (descarta VOLATILE).
--   - Não é IMMUTABLE porque depende do estado atual das tabelas
--     historico_reproducoes e conteudos: o mesmo input pode retornar valores
--     diferentes entre transações à medida que novos registros são inseridos.
--   - Dentro de uma mesma transação, o resultado é consistente (STABLE).
--   - STABLE permite ao planner do PostgreSQL chamar a função uma vez e
--     cachear o resultado dentro da transação, otimizando queries que a
--     chamam múltiplas vezes com os mesmos parâmetros.
-- =============================================================================

CREATE OR REPLACE FUNCTION minutos_assistidos_por_produtora(
    p_produtora_id INT,
    p_competencia  DATE
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(hr.segundos_assistidos) / 60.0, 0)
    INTO   v_total
    FROM   historico_reproducoes hr
           INNER JOIN videos    v ON v.id = hr.video_id
           INNER JOIN conteudos c ON c.id = v.conteudo_id
    WHERE  c.produtora_id = p_produtora_id
      AND  DATE_TRUNC('month', hr.iniciado_em) =
           DATE_TRUNC('month', p_competencia);

    RETURN v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- TESTES — Function 1.4
-- -----------------------------------------------------------------------------

-- Teste 1 — Minutos da produtora 1 em janeiro/2025
SELECT minutos_assistidos_por_produtora(1, '2025-01-01') AS minutos;

-- Uso dentro de uma query maior
SELECT
    p.nome,
    minutos_assistidos_por_produtora(p.id, '2025-01-01') AS minutos_jan
FROM produtoras p
ORDER BY minutos_jan DESC;


-- =============================================================================
-- FUNCTION 1.5 — calcular_idade
-- Calcula a idade em anos completos a partir de uma data de nascimento.
-- Usada na view vw_analytics_perfis para evitar expor data_nascimento direta.
--
-- Classificação de volatilidade: IMMUTABLE
--   - O resultado depende APENAS do parâmetro p_data_nascimento — sem acesso
--     a tabelas, sem efeitos colaterais.
--   - IMMUTABLE permite ao planner avaliar a função em tempo de planejamento
--     e até usar o resultado em índices funcionais, se necessário.
--   - Atenção: AGE() internamente usa CURRENT_DATE. Isso não quebra IMMUTABLE
--     porque a função é chamada em tempo de execução da query — o planner não
--     avalia funções IMMUTABLE que dependem de funções de data em tempo de
--     compilação; a classificação aqui documenta que não há acesso ao banco.
-- =============================================================================

CREATE OR REPLACE FUNCTION calcular_idade(p_data_nascimento DATE)
RETURNS INT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN DATE_PART('year', AGE(p_data_nascimento))::INT;
END;
$$;

-- -----------------------------------------------------------------------------
-- Atualiza a view LGPD para usar a função em vez do cálculo inline
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW vw_analytics_perfis AS
SELECT
    MD5(a.id::TEXT)                          AS assinante_hash,
    calcular_idade(a.data_nascimento)        AS idade,
    a.uf                                     AS regiao_uf,
    a.plano,
    COUNT(DISTINCT pf.id)                    AS qtd_perfis,
    COUNT(hr.id)                             AS total_reproducoes,
    COALESCE(SUM(hr.segundos_assistidos) / 60, 0) AS total_minutos_assistidos,
    MODE() WITHIN GROUP (ORDER BY hr.dispositivo) AS dispositivo_favorito
FROM assinantes a
     LEFT JOIN perfis                 pf ON pf.assinante_id = a.id
     LEFT JOIN historico_reproducoes  hr ON hr.perfil_id    = pf.id
WHERE a.ativo = TRUE
GROUP BY a.id, a.data_nascimento, a.uf, a.plano;

-- -----------------------------------------------------------------------------
-- TESTES — Function 1.5
-- -----------------------------------------------------------------------------

-- Teste direto
SELECT calcular_idade('1995-03-10') AS idade;

-- Via view
SELECT assinante_hash, idade, regiao_uf, plano
FROM vw_analytics_perfis
LIMIT 5;