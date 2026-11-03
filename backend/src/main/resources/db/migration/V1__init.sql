-- =====================================================================
-- 4Walls | V1__init.sql
-- Rodada pelo Flyway como `fourwalls_migrator`, com defaultSchema=app.
-- Local: backend/src/main/resources/db/migration/
-- Pré-requisito: 00_bootstrap.sql já executado.
--
-- Decisões:
--  * Tudo no schema `app`, nomes sem prefixo (search_path = app).
--  * Valores em texto + CHECK (mais fácil de evoluir que ENUM do Postgres).
--  * Dinheiro em NUMERIC(15,2) (BigDecimal no Java).
--  * Multi-tenant por household_id, com FKs compostas (um registro nunca
--    aponta para dado de outro lar) e RLS como segunda barreira.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Funções utilitárias
-- ---------------------------------------------------------------------
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Lar "ativo" na transação atual. O Spring define com:
--   SELECT set_config('app.current_household_id', '<uuid>', true);
-- Sem valor definido devolve NULL e as policies de RLS não retornam nada
-- (falha fechada).
CREATE FUNCTION current_household_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.current_household_id', true), '')::uuid
$$;

-- ---------------------------------------------------------------------
-- 2) Identidade e acesso
-- ---------------------------------------------------------------------
CREATE TABLE household (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  currency    varchar(3)     NOT NULL DEFAULT 'BRL',
  timezone    text        NOT NULL DEFAULT 'America/Sao_Paulo',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_user (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 text        NOT NULL,
  password_hash         text        NOT NULL,          -- BCrypt/Argon2, nunca senha pura
  display_name          text        NOT NULL,
  enabled               boolean     NOT NULL DEFAULT true,
  failed_login_attempts integer     NOT NULL DEFAULT 0,
  locked_until          timestamptz,
  last_login_at         timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_app_user_email CHECK (email = lower(email) AND position('@' IN email) > 1)
);
CREATE UNIQUE INDEX ux_app_user_email ON app_user (email);

CREATE TABLE household_member (
  household_id uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  user_id      uuid        NOT NULL REFERENCES app_user (id)  ON DELETE CASCADE,
  role         text        NOT NULL DEFAULT 'MEMBER',
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (household_id, user_id),
  CONSTRAINT ck_household_member_role CHECK (role IN ('OWNER', 'MEMBER'))
);
CREATE INDEX ix_household_member_user ON household_member (user_id);

-- Guarda só o HASH do refresh token
CREATE TABLE refresh_token (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
  token_hash text        NOT NULL UNIQUE,
  user_agent text,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_refresh_token_user ON refresh_token (user_id);

-- ---------------------------------------------------------------------
-- 3) Conexão bancária e contas
-- ---------------------------------------------------------------------
-- Só o identificador do item no Pluggy. Nenhuma credencial bancária aqui.
CREATE TABLE bank_connection (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id      uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  owner_user_id     uuid        NOT NULL REFERENCES app_user (id),
  provider          text        NOT NULL DEFAULT 'PLUGGY',
  provider_item_id  text        NOT NULL,
  connector_name    text,
  status            text,                               -- status do item no provedor
  last_synced_at    timestamptz,
  consent_expires_at timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bank_connection_provider CHECK (provider IN ('PLUGGY')),
  CONSTRAINT ux_bank_connection_item UNIQUE (provider, provider_item_id),
  CONSTRAINT ux_bank_connection_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_bank_connection_household ON bank_connection (household_id);

-- connection_id nulo = conta manual (ex.: dinheiro em espécie)
CREATE TABLE account (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id        uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  connection_id       uuid,
  owner_user_id       uuid        REFERENCES app_user (id),
  provider_account_id text,
  type                text        NOT NULL,
  name                text        NOT NULL,
  masked_number       text,
  currency            varchar(3)     NOT NULL DEFAULT 'BRL',
  balance             numeric(15,2),
  credit_limit        numeric(15,2),
  balance_updated_at  timestamptz,
  active              boolean     NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_account_type CHECK (type IN ('CHECKING', 'SAVINGS', 'CREDIT_CARD', 'INVESTMENT', 'CASH', 'OTHER')),
  CONSTRAINT ck_account_provider_ref CHECK ((connection_id IS NULL) = (provider_account_id IS NULL)),
  CONSTRAINT fk_account_connection FOREIGN KEY (connection_id, household_id)
    REFERENCES bank_connection (id, household_id) ON DELETE CASCADE,
  CONSTRAINT ux_account_provider UNIQUE (connection_id, provider_account_id),
  CONSTRAINT ux_account_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_account_household ON account (household_id);

-- ---------------------------------------------------------------------
-- 4) Categorias
-- ---------------------------------------------------------------------
-- budget_group: necessidade / desejo / poupança (base para metas e orçamento)
CREATE TABLE category (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  parent_id    uuid,
  name         text        NOT NULL,
  kind         text        NOT NULL,
  budget_group text,
  icon         text,
  color        text,
  archived     boolean     NOT NULL DEFAULT false,         -- arquivar, nunca apagar
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_category_kind CHECK (kind IN ('EXPENSE', 'INCOME', 'TRANSFER')),
  CONSTRAINT ck_category_budget_group CHECK (budget_group IS NULL OR budget_group IN ('NEED', 'WANT', 'SAVING')),
  CONSTRAINT ux_category_tenant UNIQUE (id, household_id),
  CONSTRAINT fk_category_parent FOREIGN KEY (parent_id, household_id)
    REFERENCES category (id, household_id)
);
CREATE UNIQUE INDEX ux_category_name ON category (household_id, kind, lower(name));

-- ---------------------------------------------------------------------
-- 5) Transações
-- ---------------------------------------------------------------------
-- amount é sempre positivo; o sentido vem de direction.
-- raw_payload guarda o JSON original do provedor (reprocessamento/auditoria).
-- Pode conter dados pessoais: definir política de retenção depois.
CREATE TABLE financial_transaction (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id              uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  account_id                uuid         NOT NULL,
  provider_transaction_id   text,
  occurred_at               timestamptz  NOT NULL,
  direction                 text         NOT NULL,
  amount                    numeric(15,2) NOT NULL,
  currency                  varchar(3)      NOT NULL DEFAULT 'BRL',
  description               text         NOT NULL DEFAULT '',
  counterpart_name          text,
  counterpart_document      text,
  payment_method            text,
  provider_category         text,
  category_id               uuid,
  classification_status     text         NOT NULL DEFAULT 'PENDING',
  classification_source     text,
  classification_confidence numeric(4,3),
  classified_by             uuid         REFERENCES app_user (id),
  classified_at             timestamptz,
  is_internal_transfer      boolean      NOT NULL DEFAULT false,
  notes                     text,
  raw_payload               jsonb,
  created_at                timestamptz  NOT NULL DEFAULT now(),
  updated_at                timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_ft_direction CHECK (direction IN ('DEBIT', 'CREDIT')),
  CONSTRAINT ck_ft_amount CHECK (amount > 0),
  CONSTRAINT ck_ft_payment_method CHECK (payment_method IS NULL OR payment_method IN ('PIX', 'CARD', 'BOLETO', 'TED_DOC', 'CASH', 'OTHER')),
  CONSTRAINT ck_ft_status CHECK (classification_status IN ('PENDING', 'AUTO', 'CONFIRMED')),
  CONSTRAINT ck_ft_source CHECK (classification_source IS NULL OR classification_source IN ('PROVIDER', 'RULE', 'MODEL', 'USER')),
  CONSTRAINT ck_ft_confidence CHECK (classification_confidence IS NULL OR classification_confidence BETWEEN 0 AND 1),
  CONSTRAINT ck_ft_classified CHECK (classification_status = 'PENDING' OR category_id IS NOT NULL),
  CONSTRAINT fk_ft_account FOREIGN KEY (account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_ft_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT ux_ft_provider UNIQUE (account_id, provider_transaction_id),   -- idempotência da importação
  CONSTRAINT ux_ft_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_ft_household_date ON financial_transaction (household_id, occurred_at DESC);
CREATE INDEX ix_ft_pending ON financial_transaction (household_id, occurred_at DESC)
  WHERE classification_status = 'PENDING';
CREATE INDEX ix_ft_category_date ON financial_transaction (household_id, category_id, occurred_at DESC);
CREATE INDEX ix_ft_counterpart_doc ON financial_transaction (household_id, counterpart_document)
  WHERE counterpart_document IS NOT NULL;
CREATE INDEX ix_ft_account ON financial_transaction (account_id);

-- ---------------------------------------------------------------------
-- 6) Classificação (regras aprendidas + dataset para o modelo)
-- ---------------------------------------------------------------------
-- Ex.: "João da Silva" (documento X) -> Restaurantes e lanches.
-- match_value é guardado normalizado (minúsculo, sem acento) pela aplicação.
CREATE TABLE classification_rule (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id          uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  match_type            text        NOT NULL,
  match_value           text        NOT NULL,
  category_id           uuid        NOT NULL,
  priority              integer     NOT NULL DEFAULT 100,    -- menor = mais forte
  active                boolean     NOT NULL DEFAULT true,
  hit_count             integer     NOT NULL DEFAULT 0,
  last_hit_at           timestamptz,
  created_by            uuid        REFERENCES app_user (id),
  source_transaction_id uuid        REFERENCES financial_transaction (id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_rule_match_type CHECK (match_type IN ('COUNTERPART_DOCUMENT', 'COUNTERPART_NAME', 'DESCRIPTION_CONTAINS')),
  CONSTRAINT fk_rule_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT ux_rule UNIQUE (household_id, match_type, match_value)
);

-- Uma linha por previsão/decisão. final_category_id é o rótulo de treino.
CREATE TABLE classification_feedback (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id         uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  transaction_id       uuid        NOT NULL,
  predicted_category_id uuid,
  predicted_confidence numeric(4,3),
  predicted_source     text,
  model_version        text,
  final_category_id    uuid,
  final_by             uuid        REFERENCES app_user (id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  resolved_at          timestamptz,
  CONSTRAINT ck_cf_source CHECK (predicted_source IS NULL OR predicted_source IN ('PROVIDER', 'RULE', 'MODEL')),
  CONSTRAINT ck_cf_confidence CHECK (predicted_confidence IS NULL OR predicted_confidence BETWEEN 0 AND 1),
  CONSTRAINT fk_cf_transaction FOREIGN KEY (transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id) ON DELETE CASCADE,
  CONSTRAINT fk_cf_predicted FOREIGN KEY (predicted_category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT fk_cf_final FOREIGN KEY (final_category_id, household_id)
    REFERENCES category (id, household_id)
);
CREATE INDEX ix_cf_household ON classification_feedback (household_id, created_at DESC);
CREATE INDEX ix_cf_transaction ON classification_feedback (transaction_id);

-- ---------------------------------------------------------------------
-- 7) Orçamento, metas e sonhos
-- ---------------------------------------------------------------------
CREATE TABLE budget (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id   uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  category_id    uuid         NOT NULL,
  month          date         NOT NULL,                      -- sempre o dia 1
  planned_amount numeric(15,2) NOT NULL,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_budget_month CHECK (EXTRACT(day FROM month) = 1),
  CONSTRAINT ck_budget_amount CHECK (planned_amount >= 0),
  CONSTRAINT fk_budget_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT ux_budget UNIQUE (household_id, category_id, month)
);

CREATE TABLE goal (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  name          text         NOT NULL,
  kind          text         NOT NULL DEFAULT 'SAVING',
  target_amount numeric(15,2) NOT NULL,
  target_date   date,
  status        text         NOT NULL DEFAULT 'ACTIVE',
  priority      smallint     NOT NULL DEFAULT 3,
  notes         text,
  created_at    timestamptz  NOT NULL DEFAULT now(),
  updated_at    timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_goal_kind CHECK (kind IN ('SAVING', 'DREAM', 'NEED')),
  CONSTRAINT ck_goal_status CHECK (status IN ('ACTIVE', 'ACHIEVED', 'PAUSED', 'CANCELLED')),
  CONSTRAINT ck_goal_target CHECK (target_amount > 0),
  CONSTRAINT ck_goal_priority CHECK (priority BETWEEN 1 AND 5),
  CONSTRAINT ux_goal_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_goal_household ON goal (household_id, status);

-- amount negativo = retirada. O valor atual da meta é a soma das contribuições.
CREATE TABLE goal_contribution (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id   uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  goal_id        uuid         NOT NULL,
  transaction_id uuid,
  amount         numeric(15,2) NOT NULL,
  contributed_on date         NOT NULL DEFAULT current_date,
  note           text,
  created_by     uuid         REFERENCES app_user (id),
  created_at     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_gc_amount CHECK (amount <> 0),
  CONSTRAINT fk_gc_goal FOREIGN KEY (goal_id, household_id)
    REFERENCES goal (id, household_id) ON DELETE CASCADE,
  CONSTRAINT fk_gc_transaction FOREIGN KEY (transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id)
);
CREATE INDEX ix_gc_goal ON goal_contribution (goal_id);

-- ---------------------------------------------------------------------
-- 8) Notificações e webhooks
-- ---------------------------------------------------------------------
CREATE TABLE push_subscription (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
  endpoint     text        NOT NULL UNIQUE,
  p256dh       text        NOT NULL,
  auth_key     text        NOT NULL,
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);
CREATE INDEX ix_push_subscription_user ON push_subscription (user_id);

-- Inbox de webhooks do Pluggy: grava primeiro, processa depois (idempotente)
CREATE TABLE webhook_event (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider          text        NOT NULL DEFAULT 'PLUGGY',
  provider_event_id text        NOT NULL,
  event_type        text        NOT NULL,
  payload           jsonb       NOT NULL,
  status            text        NOT NULL DEFAULT 'RECEIVED',
  attempts          integer     NOT NULL DEFAULT 0,
  error             text,
  received_at       timestamptz NOT NULL DEFAULT now(),
  processed_at      timestamptz,
  CONSTRAINT ck_webhook_status CHECK (status IN ('RECEIVED', 'PROCESSED', 'FAILED')),
  CONSTRAINT ux_webhook_event UNIQUE (provider, provider_event_id)
);
CREATE INDEX ix_webhook_event_open ON webhook_event (received_at)
  WHERE status IN ('RECEIVED', 'FAILED');

-- ---------------------------------------------------------------------
-- 9) Triggers de updated_at
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'household', 'app_user', 'bank_connection', 'account', 'category',
    'financial_transaction', 'classification_rule', 'budget', 'goal'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON %1$I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 10) Funções de apoio
-- ---------------------------------------------------------------------
-- O webhook do Pluggy chega sem lar definido. Esta função resolve o lar a
-- partir do item, ignorando RLS só para esse lookup (SECURITY DEFINER).
CREATE FUNCTION household_of_item(p_provider text, p_item_id text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, pg_temp AS $$
  SELECT household_id FROM bank_connection
   WHERE provider = p_provider AND provider_item_id = p_item_id
$$;

-- Categorias padrão. Chamar logo após criar o lar, com
-- app.current_household_id já definido (a RLS garante que só semeia o próprio lar).
CREATE FUNCTION seed_default_categories(p_household_id uuid) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO category (household_id, name, kind, budget_group, icon)
  SELECT p_household_id, v.name, v.kind, v.budget_group, v.icon
  FROM (VALUES
    ('Moradia',                  'EXPENSE',  'NEED',   '🏠'),
    ('Mercado',                  'EXPENSE',  'NEED',   '🛒'),
    ('Contas e assinaturas',     'EXPENSE',  'NEED',   '🧾'),
    ('Transporte',               'EXPENSE',  'NEED',   '🚌'),
    ('Saúde',                    'EXPENSE',  'NEED',   '🩺'),
    ('Educação',                 'EXPENSE',  'NEED',   '📚'),
    ('Casa e limpeza',           'EXPENSE',  'NEED',   '🧹'),
    ('Restaurantes e lanches',   'EXPENSE',  'WANT',   '🍔'),
    ('Lazer',                    'EXPENSE',  'WANT',   '🎬'),
    ('Compras',                  'EXPENSE',  'WANT',   '🛍️'),
    ('Reserva e investimentos',  'EXPENSE',  'SAVING', '🐷'),
    ('Outros',                   'EXPENSE',  NULL,     '📦'),
    ('Salário',                  'INCOME',   NULL,     '💰'),
    ('Renda extra',              'INCOME',   NULL,     '➕'),
    ('Rendimentos',              'INCOME',   NULL,     '📈'),
    ('Reembolso',                'INCOME',   NULL,     '↩️'),
    ('Transferência interna',    'TRANSFER', NULL,     '🔁')
  ) AS v(name, kind, budget_group, icon)
  ON CONFLICT DO NOTHING
$$;

-- ---------------------------------------------------------------------
-- 11) Row Level Security (isolamento entre lares)
-- ---------------------------------------------------------------------
-- O dono das tabelas (migrator) ignora RLS; o app (fourwalls_app) não.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'bank_connection', 'account', 'category', 'financial_transaction',
    'classification_rule', 'classification_feedback', 'budget', 'goal',
    'goal_contribution'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I
         USING (household_id = current_household_id())
         WITH CHECK (household_id = current_household_id())', t);
  END LOOP;
END $$;

-- Tabelas de identidade/sistema: acesso controlado pela camada de serviço
-- (login precisa consultar antes de existir lar ativo). Sem RLS de propósito.
ALTER TABLE household          DISABLE ROW LEVEL SECURITY;
ALTER TABLE household_member   DISABLE ROW LEVEL SECURITY;
ALTER TABLE app_user           DISABLE ROW LEVEL SECURITY;
ALTER TABLE refresh_token      DISABLE ROW LEVEL SECURITY;
ALTER TABLE push_subscription  DISABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_event      DISABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- 12) Grants de função e fechamento
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION set_updated_at()                    FROM PUBLIC;
REVOKE ALL ON FUNCTION current_household_id()              FROM PUBLIC;
REVOKE ALL ON FUNCTION household_of_item(text, text)       FROM PUBLIC;
REVOKE ALL ON FUNCTION seed_default_categories(uuid)       FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fourwalls_app') THEN
    GRANT EXECUTE ON FUNCTION current_household_id()          TO fourwalls_app;
    GRANT EXECUTE ON FUNCTION household_of_item(text, text)   TO fourwalls_app;
    GRANT EXECUTE ON FUNCTION seed_default_categories(uuid)   TO fourwalls_app;
    -- o app não precisa (nem deve) mexer no histórico do Flyway
    IF to_regclass('flyway_schema_history') IS NOT NULL THEN
      REVOKE ALL ON flyway_schema_history FROM fourwalls_app;
    END IF;
  END IF;
END $$;