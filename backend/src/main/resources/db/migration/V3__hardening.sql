-- =====================================================================
-- 4Walls | V3__hardening.sql
-- Rodada pelo Flyway como `fourwalls_migrator`, com defaultSchema=app.
-- Local: backend/src/main/resources/db/migration/
--
-- O que entra:
--   1) app não pode mais apagar um lar (DELETE revogado em household)
--   2) índices nas FKs de installment_plan e recurrence que faltaram na V2
--
-- Por que household e household_member NÃO têm RLS:
--   No login ainda não existe lar no contexto: o app precisa perguntar
--   "de quais lares este usuário é membro?" antes de escolher um. Uma policy
--   por current_household_id() devolveria 0 linhas nesse momento.
--   Proteção no MVP: toda consulta a essas tabelas filtra pelo usuário
--   logado no Java. Pós-MVP: RLS por usuário (current_app_user_id()).
--
-- Por que NÃO usamos FORCE ROW LEVEL SECURITY:
--   Com FORCE, o próprio fourwalls_migrator (dono das tabelas) obedeceria
--   ao RLS e migrations de dados (UPDATE/DELETE) rodariam sem lar definido,
--   afetando 0 linhas sem erro. A proteção vem de o app conectar SEMPRE
--   como fourwalls_app, que não é dono.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Apagar um lar é operação administrativa, nunca do app
-- ---------------------------------------------------------------------
-- O DELETE em household apaga em cascata tudo do lar. Um bug num endpoint
-- não pode causar isso. Se um dia for preciso, roda-se como migrator.
REVOKE DELETE ON household FROM fourwalls_app;

-- ---------------------------------------------------------------------
-- 2) Índices nas FKs (o Postgres não cria índice para FK sozinho)
-- ---------------------------------------------------------------------
-- Sem eles, apagar/alterar uma conta ou categoria varre essas tabelas
-- inteiras para checar a FK, e filtros por conta/categoria ficam lentos.
CREATE INDEX ix_installment_plan_account  ON installment_plan (account_id);
CREATE INDEX ix_installment_plan_category ON installment_plan (category_id);
CREATE INDEX ix_recurrence_account        ON recurrence (account_id);
CREATE INDEX ix_recurrence_category       ON recurrence (category_id);
