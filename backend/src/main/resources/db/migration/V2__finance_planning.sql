-- =====================================================================
-- 4Walls | V2__finance_planning.sql
-- Rodada pelo Flyway como `fourwalls_migrator`, com defaultSchema=app.
-- Local: backend/src/main/resources/db/migration/
--
-- O que entra:
--   event, installment_plan, bill, recurrence, transfer, transaction_payer
-- O que muda na V1:
--   account.owner_user_id passa a ser obrigatório (e deve ser membro do lar)
--   account.type ganha o valor BENEFIT
--   financial_transaction.event_id (opcional)
--   goal_contribution.transfer_id (opcional)
-- Fica de fora (pós-MVP): debt, debt_settlement, notification, compras.
--
-- Mesmas convenções da V1: texto + CHECK, NUMERIC(15,2), FKs compostas
-- (id, household_id) e RLS tenant_isolation em toda tabela com household_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Conta: dono obrigatório (o casal não usa conta conjunta)
-- ---------------------------------------------------------------------
-- Se já existir conta com owner_user_id NULL, esta migration falha de
-- propósito: corrija os dados e rode de novo.
ALTER TABLE account ALTER COLUMN owner_user_id SET NOT NULL;

-- O dono precisa ser membro do MESMO lar (a FK da V1 só garantia que o
-- usuário existe).
ALTER TABLE account
  ADD CONSTRAINT fk_account_owner_member
  FOREIGN KEY (household_id, owner_user_id)
  REFERENCES household_member (household_id, user_id);

-- Novo tipo de conta: BENEFIT (VA/VR/VT, saldo que só serve para um fim).
-- A V1 é imutável, então a regra é trocada aqui (drop + add).
ALTER TABLE account DROP CONSTRAINT ck_account_type;
ALTER TABLE account
  ADD CONSTRAINT ck_account_type
  CHECK (type IN ('CHECKING', 'SAVINGS', 'CREDIT_CARD', 'INVESTMENT', 'CASH', 'BENEFIT', 'OTHER'));

-- ---------------------------------------------------------------------
-- 2) Evento (viagem, gasto fora da rotina)
-- ---------------------------------------------------------------------
-- Eixo ortogonal à categoria: a transação continua com UMA categoria e
-- ganha, opcionalmente, um evento.
CREATE TABLE event (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid        NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  name         text        NOT NULL,
  starts_on    date        NOT NULL,
  ends_on      date        NOT NULL,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_event_period CHECK (ends_on >= starts_on),
  CONSTRAINT ux_event_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_event_household ON event (household_id, starts_on DESC);

ALTER TABLE financial_transaction ADD COLUMN event_id uuid;
-- SET NULL só na coluna event_id: household_id é NOT NULL e não pode zerar.
ALTER TABLE financial_transaction
  ADD CONSTRAINT fk_ft_event FOREIGN KEY (event_id, household_id)
  REFERENCES event (id, household_id) ON DELETE SET NULL (event_id);
CREATE INDEX ix_ft_event ON financial_transaction (event_id) WHERE event_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3) Parcelamento: plano (a compra) + bill (cada parcela ou boleto)
-- ---------------------------------------------------------------------
-- Conta e categoria moram no PLANO. A soma das parcelas = total_amount e a
-- diferença de centavos vai para a última: quem garante é a aplicação
-- (um CHECK não enxerga outras linhas).
CREATE TABLE installment_plan (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id       uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  account_id         uuid         NOT NULL,
  category_id        uuid         NOT NULL,
  description        text         NOT NULL,
  total_amount       numeric(15,2) NOT NULL,
  installments_count smallint     NOT NULL,
  purchased_on       date         NOT NULL,
  first_due_on       date         NOT NULL,
  status             text         NOT NULL DEFAULT 'ACTIVE',
  created_by         uuid         REFERENCES app_user (id),
  created_at         timestamptz  NOT NULL DEFAULT now(),
  updated_at         timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_ip_total CHECK (total_amount > 0),
  CONSTRAINT ck_ip_count CHECK (installments_count >= 2),
  CONSTRAINT ck_ip_status CHECK (status IN ('ACTIVE', 'CANCELLED')),
  CONSTRAINT fk_ip_account FOREIGN KEY (account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_ip_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT ux_ip_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_ip_household ON installment_plan (household_id, first_due_on);

-- Bill = conta a pagar. Dois jeitos de existir:
--   * parcela: tem plan_id + installment_number e HERDA conta/categoria do plano
--   * boleto avulso: sem plano, categoria obrigatória (conta é opcional)
CREATE TABLE bill (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id            uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  plan_id                 uuid,
  installment_number      smallint,
  account_id              uuid,
  category_id             uuid,
  description             text         NOT NULL,
  amount                  numeric(15,2) NOT NULL,
  due_on                  date         NOT NULL,
  competence_month        date         NOT NULL,            -- sempre o dia 1
  original_competence_month date,                           -- preenchido ao adiar
  status                  text         NOT NULL DEFAULT 'OPEN',
  paid_transaction_id     uuid,
  created_at              timestamptz  NOT NULL DEFAULT now(),
  updated_at              timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_bill_amount CHECK (amount > 0),
  CONSTRAINT ck_bill_status CHECK (status IN ('OPEN', 'PAID', 'CANCELLED')),
  CONSTRAINT ck_bill_competence CHECK (EXTRACT(day FROM competence_month) = 1),
  CONSTRAINT ck_bill_original CHECK (original_competence_month IS NULL OR EXTRACT(day FROM original_competence_month) = 1),
  CONSTRAINT ck_bill_plan_number CHECK ((plan_id IS NULL) = (installment_number IS NULL)),
  CONSTRAINT ck_bill_number CHECK (installment_number IS NULL OR installment_number >= 1),
  -- parcela herda do plano (não repete); avulso precisa de categoria
  CONSTRAINT ck_bill_inherit CHECK (plan_id IS NULL OR (account_id IS NULL AND category_id IS NULL)),
  CONSTRAINT ck_bill_standalone CHECK (plan_id IS NOT NULL OR category_id IS NOT NULL),
  CONSTRAINT ck_bill_paid CHECK (paid_transaction_id IS NULL OR status = 'PAID'),
  CONSTRAINT fk_bill_plan FOREIGN KEY (plan_id, household_id)
    REFERENCES installment_plan (id, household_id) ON DELETE CASCADE,
  CONSTRAINT fk_bill_account FOREIGN KEY (account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_bill_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT fk_bill_paid_tx FOREIGN KEY (paid_transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id),
  CONSTRAINT ux_bill_installment UNIQUE (plan_id, installment_number),
  CONSTRAINT ux_bill_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_bill_competence ON bill (household_id, competence_month);
CREATE INDEX ix_bill_open ON bill (household_id, due_on) WHERE status = 'OPEN';
CREATE INDEX ix_bill_paid_tx ON bill (paid_transaction_id) WHERE paid_transaction_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4) Recorrência (só a REGRA; as ocorrências futuras são calculadas)
-- ---------------------------------------------------------------------
CREATE TABLE recurrence (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  kind         text         NOT NULL,
  description  text         NOT NULL,
  amount       numeric(15,2) NOT NULL,
  account_id   uuid         NOT NULL,
  category_id  uuid         NOT NULL,
  interval_unit  text       NOT NULL DEFAULT 'MONTH',       -- "a cada N <unidade>"
  interval_count smallint   NOT NULL DEFAULT 1,
  starts_on    date         NOT NULL,                       -- âncora do dia/mês
  ends_on      date,
  active       boolean      NOT NULL DEFAULT true,
  created_by   uuid         REFERENCES app_user (id),
  created_at   timestamptz  NOT NULL DEFAULT now(),
  updated_at   timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_rec_kind CHECK (kind IN ('EXPENSE', 'INCOME')),
  CONSTRAINT ck_rec_amount CHECK (amount > 0),
  CONSTRAINT ck_rec_interval_unit CHECK (interval_unit IN ('DAY', 'WEEK', 'MONTH', 'YEAR')),
  CONSTRAINT ck_rec_interval_count CHECK (interval_count > 0),
  CONSTRAINT ck_rec_period CHECK (ends_on IS NULL OR ends_on >= starts_on),
  CONSTRAINT fk_rec_account FOREIGN KEY (account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_rec_category FOREIGN KEY (category_id, household_id)
    REFERENCES category (id, household_id),
  CONSTRAINT ux_rec_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_rec_household ON recurrence (household_id) WHERE active;

-- ---------------------------------------------------------------------
-- 5) Transferência entre contas do lar (não é gasto nem receita)
-- ---------------------------------------------------------------------
-- As pernas (saída numa conta, entrada na outra) são opcionais: com o
-- Pluggy elas chegam como financial_transaction e o importador as vincula;
-- em lançamento manual a transfer pode existir sem elas.
CREATE TABLE transfer (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id       uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  from_account_id    uuid         NOT NULL,
  to_account_id      uuid         NOT NULL,
  amount             numeric(15,2) NOT NULL,
  occurred_at        timestamptz  NOT NULL,
  out_transaction_id uuid,
  in_transaction_id  uuid,
  note               text,
  created_by         uuid         REFERENCES app_user (id),
  created_at         timestamptz  NOT NULL DEFAULT now(),
  updated_at         timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_transfer_amount CHECK (amount > 0),
  CONSTRAINT ck_transfer_accounts CHECK (from_account_id <> to_account_id),
  CONSTRAINT ck_transfer_legs CHECK (out_transaction_id IS NULL OR in_transaction_id IS NULL OR out_transaction_id <> in_transaction_id),
  CONSTRAINT fk_transfer_from FOREIGN KEY (from_account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_transfer_to FOREIGN KEY (to_account_id, household_id)
    REFERENCES account (id, household_id),
  CONSTRAINT fk_transfer_out FOREIGN KEY (out_transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id),
  CONSTRAINT fk_transfer_in FOREIGN KEY (in_transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id),
  CONSTRAINT ux_transfer_out UNIQUE (out_transaction_id),
  CONSTRAINT ux_transfer_in UNIQUE (in_transaction_id),
  CONSTRAINT ux_transfer_tenant UNIQUE (id, household_id)
);
CREATE INDEX ix_transfer_household_date ON transfer (household_id, occurred_at DESC);
CREATE INDEX ix_transfer_from ON transfer (from_account_id);
CREATE INDEX ix_transfer_to ON transfer (to_account_id);

-- Aporte/retirada de meta continua em goal_contribution (V1, valor atual =
-- soma das contribuições); ela passa a poder apontar para a transfer que a gerou.
ALTER TABLE goal_contribution ADD COLUMN transfer_id uuid;
ALTER TABLE goal_contribution
  ADD CONSTRAINT fk_gc_transfer FOREIGN KEY (transfer_id, household_id)
  REFERENCES transfer (id, household_id);
CREATE INDEX ix_gc_transfer ON goal_contribution (transfer_id) WHERE transfer_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 6) Quem pagou de fato (pode ser mais de uma pessoa)
-- ---------------------------------------------------------------------
-- O RESTANTE (amount da transação - soma das linhas) é do dono da conta e
-- NÃO é gravado: é calculado nas consultas.
CREATE TABLE transaction_payer (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id          uuid         NOT NULL REFERENCES household (id) ON DELETE CASCADE,
  transaction_id        uuid         NOT NULL,
  user_id               uuid         NOT NULL,
  amount                numeric(15,2) NOT NULL,
  funded_by_transfer_id uuid,
  note                  text,
  created_at            timestamptz  NOT NULL DEFAULT now(),
  updated_at            timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_tp_amount CHECK (amount > 0),
  CONSTRAINT fk_tp_transaction FOREIGN KEY (transaction_id, household_id)
    REFERENCES financial_transaction (id, household_id) ON DELETE CASCADE,
  CONSTRAINT fk_tp_member FOREIGN KEY (household_id, user_id)
    REFERENCES household_member (household_id, user_id),
  CONSTRAINT fk_tp_transfer FOREIGN KEY (funded_by_transfer_id, household_id)
    REFERENCES transfer (id, household_id),
  CONSTRAINT ux_tp_payer UNIQUE (transaction_id, user_id)
);
CREATE INDEX ix_tp_user ON transaction_payer (household_id, user_id);

-- Regras que CHECK não alcança (olham outras linhas):
--  * só gasto (DEBIT) tem pagador
--  * a soma dos pagadores nunca passa do valor da transação
-- O FOR UPDATE serializa dois inserts simultâneos na mesma transação.
CREATE FUNCTION check_transaction_payers() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_amount    numeric(15,2);
  v_direction text;
  v_sum       numeric(15,2);
BEGIN
  SELECT amount, direction INTO v_amount, v_direction
    FROM financial_transaction
   WHERE id = NEW.transaction_id AND household_id = NEW.household_id
   FOR UPDATE;

  IF v_direction <> 'DEBIT' THEN
    RAISE EXCEPTION 'transaction_payer: só gasto (DEBIT) pode ter pagador'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_sum
    FROM transaction_payer WHERE transaction_id = NEW.transaction_id;

  IF v_sum > v_amount THEN
    RAISE EXCEPTION 'transaction_payer: soma dos pagadores (%) maior que o valor da transação (%)', v_sum, v_amount
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER trg_tp_check AFTER INSERT OR UPDATE ON transaction_payer
  FOR EACH ROW EXECUTE FUNCTION check_transaction_payers();

-- Caminho inverso: editar o valor/sentido da transação não pode deixar os
-- pagadores inconsistentes.
CREATE FUNCTION check_payers_vs_transaction() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_sum numeric(15,2);
BEGIN
  SELECT SUM(amount) INTO v_sum FROM transaction_payer WHERE transaction_id = NEW.id;
  IF v_sum IS NULL THEN
    RETURN NULL;
  END IF;
  IF NEW.direction <> 'DEBIT' THEN
    RAISE EXCEPTION 'transação com pagadores deve continuar sendo DEBIT'
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_sum > NEW.amount THEN
    RAISE EXCEPTION 'novo valor (%) menor que a soma dos pagadores (%)', NEW.amount, v_sum
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER trg_ft_check_payers AFTER UPDATE OF amount, direction ON financial_transaction
  FOR EACH ROW EXECUTE FUNCTION check_payers_vs_transaction();

REVOKE ALL ON FUNCTION check_transaction_payers()   FROM PUBLIC;
REVOKE ALL ON FUNCTION check_payers_vs_transaction() FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 7) Triggers de updated_at
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'event', 'installment_plan', 'bill', 'recurrence', 'transfer', 'transaction_payer'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON %1$I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 8) Row Level Security (mesma policy da V1)
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'event', 'installment_plan', 'bill', 'recurrence', 'transfer', 'transaction_payer'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I
         USING (household_id = current_household_id())
         WITH CHECK (household_id = current_household_id())', t);
  END LOOP;
END $$;