CREATE TABLE assinantes (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(150) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    cpf CHAR(11) NOT NULL UNIQUE,
    data_nascimento DATE NOT NULL,
    uf CHAR(2) NOT NULL CHECK (uf ~ '^[A-Z]{2}$'),
    plano VARCHAR(20) NOT NULL DEFAULT 'basico'
        CHECK (plano IN ('basico', 'padrao', 'premium')),
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE perfis (
    id SERIAL PRIMARY KEY,
    assinante_id INT NOT NULL
        REFERENCES assinantes(id)
        ON DELETE CASCADE,
    nome_exibicao VARCHAR(100) NOT NULL,
    avatar_url VARCHAR(500),
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION fn_limite_perfis()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT COUNT(*) FROM perfis WHERE assinante_id = NEW.assinante_id) >= 5 THEN
        RAISE EXCEPTION 'Limite de 5 perfis por assinante atingido.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_limite_perfis
    BEFORE INSERT ON perfis
    FOR EACH ROW EXECUTE FUNCTION fn_limite_perfis();

CREATE TABLE produtoras (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(200) NOT NULL UNIQUE,
    pais CHAR(3),
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE conteudos (
    id SERIAL PRIMARY KEY,
    produtora_id INT NOT NULL
        REFERENCES produtoras(id)
        ON DELETE RESTRICT,
    titulo VARCHAR(300) NOT NULL,
    tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('filme', 'serie')),
    genero VARCHAR(50),
    classificacao VARCHAR(5) CHECK (classificacao IN ('L','10','12','14','16','18')),
    ano_lancamento SMALLINT CHECK (ano_lancamento BETWEEN 1888 AND 2100),
    thumbnail_url VARCHAR(500),
    sinopse TEXT,
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE episodios (
    id SERIAL PRIMARY KEY,
    conteudo_id INT NOT NULL
        REFERENCES conteudos(id)
        ON DELETE CASCADE,
    temporada SMALLINT NOT NULL CHECK (temporada >= 1),
    numero_episodio SMALLINT NOT NULL CHECK (numero_episodio >= 1),
    titulo_episodio VARCHAR(300),
    UNIQUE (conteudo_id, temporada, numero_episodio)
);

CREATE TABLE videos (
    id SERIAL PRIMARY KEY,
    conteudo_id INT NOT NULL
        REFERENCES conteudos(id)
        ON DELETE RESTRICT,
    episodio_id INT
        REFERENCES episodios(id)
        ON DELETE CASCADE,
    duracao_segundos INT NOT NULL CHECK (duracao_segundos > 0),
    resolucao_max VARCHAR(10) CHECK (resolucao_max IN ('SD','HD','FHD','4K','8K')),
    url_stream VARCHAR(500) NOT NULL,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION fn_valida_video_tipo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_tipo VARCHAR(10);
BEGIN
    SELECT tipo INTO v_tipo FROM conteudos WHERE id = NEW.conteudo_id;
    IF NEW.episodio_id IS NOT NULL AND v_tipo = 'filme' THEN
        RAISE EXCEPTION 'Filmes não podem ter episodio_id preenchido.';
    END IF;
    IF NEW.episodio_id IS NULL AND v_tipo = 'serie' THEN
        RAISE EXCEPTION 'Vídeos de série devem ter episodio_id preenchido.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_valida_video_tipo
    BEFORE INSERT OR UPDATE ON videos
    FOR EACH ROW EXECUTE FUNCTION fn_valida_video_tipo();

CREATE TABLE historico_reproducoes (
    id BIGSERIAL PRIMARY KEY,
    perfil_id INT NOT NULL
        REFERENCES perfis(id)
        ON DELETE RESTRICT,
    video_id INT NOT NULL
        REFERENCES videos(id)
        ON DELETE RESTRICT,
    iniciado_em TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    segundos_assistidos INT NOT NULL DEFAULT 0
        CHECK (segundos_assistidos >= 0),
    ip_conexao INET NOT NULL,
    dispositivo VARCHAR(20) NOT NULL
        CHECK (dispositivo IN ('SmartTV','Smartphone','Tablet','Web','Console','Outro')),
    concluido BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE OR REPLACE FUNCTION fn_log_imutavel()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Registros de log são imutáveis: DELETE não permitido.';
    END IF;
    IF OLD.iniciado_em <> NEW.iniciado_em OR
       OLD.ip_conexao <> NEW.ip_conexao OR
       OLD.dispositivo <> NEW.dispositivo OR
       OLD.perfil_id <> NEW.perfil_id OR
       OLD.video_id <> NEW.video_id THEN
        RAISE EXCEPTION 'Campos de auditoria são imutáveis após inserção.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_log_imutavel
    BEFORE UPDATE OR DELETE ON historico_reproducoes
    FOR EACH ROW EXECUTE FUNCTION fn_log_imutavel();


CREATE USER app_streamflow WITH PASSWORD 'app_senha_segura_aqui';

GRANT CONNECT ON DATABASE postgres TO app_streamflow;
GRANT USAGE ON SCHEMA public TO app_streamflow;

GRANT SELECT, INSERT ON TABLE
    assinantes, perfis, produtoras, conteudos, episodios, videos
    TO app_streamflow;

GRANT SELECT, INSERT, UPDATE ON TABLE historico_reproducoes TO app_streamflow;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_streamflow;

CREATE USER analista_auditoria WITH PASSWORD 'auditoria_senha_segura_aqui';

GRANT CONNECT ON DATABASE postgres TO analista_auditoria;
GRANT USAGE ON SCHEMA public TO analista_auditoria;

GRANT SELECT ON TABLE historico_reproducoes TO analista_auditoria;
GRANT SELECT ON TABLE videos, conteudos, episodios, produtoras TO analista_auditoria;

REVOKE ALL ON TABLE assinantes FROM analista_auditoria;
REVOKE ALL ON TABLE perfis FROM analista_auditoria;

CREATE OR REPLACE VIEW vw_acessos_regiao AS
SELECT
    a.uf,
    hr.dispositivo,
    COUNT(hr.id) AS total_acessos,
    COUNT(DISTINCT hr.perfil_id) AS perfis_unicos
FROM historico_reproducoes hr
    INNER JOIN perfis pf ON pf.id = hr.perfil_id
    INNER JOIN assinantes a ON a.id = pf.assinante_id
GROUP BY a.uf, hr.dispositivo;

GRANT SELECT ON vw_acessos_regiao TO analista_auditoria;


CREATE INDEX idx_historico_perfil_andamento
    ON historico_reproducoes (perfil_id, concluido, iniciado_em DESC)
    WHERE concluido = FALSE;

CREATE INDEX idx_historico_video_data
    ON historico_reproducoes (video_id, iniciado_em);

CREATE INDEX idx_assinantes_uf
    ON assinantes (uf);


CREATE OR REPLACE VIEW vw_analytics_perfis AS
SELECT
    MD5(a.id::TEXT) AS assinante_hash,
    DATE_PART('year', AGE(a.data_nascimento)) AS idade,
    a.uf AS regiao_uf,
    a.plano,
    COUNT(DISTINCT pf.id) AS qtd_perfis,
    COUNT(hr.id) AS total_reproducoes,
    COALESCE(SUM(hr.segundos_assistidos) / 60, 0) AS total_minutos_assistidos,
    MODE() WITHIN GROUP (ORDER BY hr.dispositivo) AS dispositivo_favorito
FROM assinantes a
    LEFT JOIN perfis pf ON pf.assinante_id = a.id
    LEFT JOIN historico_reproducoes hr ON hr.perfil_id = pf.id
WHERE a.ativo = TRUE
GROUP BY a.id, a.data_nascimento, a.uf, a.plano;

GRANT SELECT ON vw_analytics_perfis TO analista_auditoria;
CREATE ROLE role_marketing;
GRANT SELECT ON vw_analytics_perfis TO role_marketing;
REVOKE ALL ON TABLE assinantes FROM role_marketing;
REVOKE ALL ON TABLE perfis FROM role_marketing;
