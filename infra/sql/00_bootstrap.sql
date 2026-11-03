-- =====================================================================
-- 4Walls | 00_bootstrap.sql
-- Rodar UMA vez, como admin (no Supabase: usuário `postgres`, SQL Editor).
-- NÃO é migration do Flyway. Fica em infra/sql/.
--
-- Antes de rodar: troque os dois <<TROCAR_...>> por senhas fortes
-- e NÃO commite o arquivo com as senhas reais.
-- =====================================================================

-- 1) Roles ------------------------------------------------------------
--   fourwalls_migrator -> dono do schema; usado só pelo Flyway (DDL)
--   fourwalls_app      -> usado pelo Spring em runtime (só DML, sujeito a RLS)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fourwalls_migrator') THEN
    CREATE ROLE fourwalls_migrator LOGIN PASSWORD '<<TROCAR_SENHA_MIGRATOR>>'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 3;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fourwalls_app') THEN
    CREATE ROLE fourwalls_app LOGIN PASSWORD '<<TROCAR_SENHA_APP>>'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT 12;
  END IF;
END $$;

-- O admin precisa ser membro do migrator para criar o schema e os
-- default privileges em nome dele.
GRANT fourwalls_migrator TO CURRENT_USER;

-- 2) Schema próprio (nada de usar o `public`) -----------------------------
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION fourwalls_migrator;

REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO fourwalls_app;

-- Supabase: roles da Data API não podem enxergar nada do nosso schema
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA app FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Ninguém cria objetos no public
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 3) Configurações por role -------------------------------------------
ALTER ROLE fourwalls_app      SET search_path = app;
ALTER ROLE fourwalls_migrator SET search_path = app;

-- Cinto de segurança contra query presa / conexão esquecida
ALTER ROLE fourwalls_app SET statement_timeout = '15s';
ALTER ROLE fourwalls_app SET lock_timeout = '5s';
ALTER ROLE fourwalls_app SET idle_in_transaction_session_timeout = '30s';

-- 4) Privilégios automáticos para tudo que o migrator criar -------------
-- (tabelas e sequences novas já nascem acessíveis ao app, só com DML)
ALTER DEFAULT PRIVILEGES FOR ROLE fourwalls_migrator IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fourwalls_app;

ALTER DEFAULT PRIVILEGES FOR ROLE fourwalls_migrator IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO fourwalls_app;

-- Funções novas NÃO ficam executáveis por PUBLIC; cada uma recebe GRANT explícito
ALTER DEFAULT PRIVILEGES FOR ROLE fourwalls_migrator
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 5) Conferência (rode depois e olhe o resultado) -------------------------
-- SELECT rolname, rolsuper, rolcreaterole, rolbypassrls, rolconnlimit
--   FROM pg_roles WHERE rolname LIKE 'fourwalls_%';
-- SELECT nspname, nspowner::regrole FROM pg_namespace WHERE nspname = 'app';