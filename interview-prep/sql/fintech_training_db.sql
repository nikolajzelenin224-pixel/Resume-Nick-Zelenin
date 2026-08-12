-- =====================================================================
--  Учебная база «Финтех» для подготовки к собеседованиям
--  PostgreSQL 14+
--
--  Запуск:  psql -U postgres -f fintech_training_db.sql
--  или в DBeaver: открыть файл и выполнить целиком (Alt+X)
--
--  Схема сознательно повторяет реальную платёжную систему:
--  клиенты, счета, мерчанты, платежи, леджер проводок, возвраты.
--  На ней отрабатываются ровно те запросы, которые просят на собесе.
-- =====================================================================

DROP SCHEMA IF EXISTS fintech CASCADE;
CREATE SCHEMA fintech;
SET search_path TO fintech, public;

-- ---------------------------------------------------------------------
-- Справочники и основные сущности
-- ---------------------------------------------------------------------

CREATE TABLE clients (
    client_id    bigserial PRIMARY KEY,
    full_name    text        NOT NULL,
    email        text        NOT NULL UNIQUE,
    phone        text,
    city         text,
    kyc_status   text        NOT NULL DEFAULT 'pending',   -- pending | verified | rejected
    created_at   timestamptz NOT NULL,
    CONSTRAINT clients_kyc_chk CHECK (kyc_status IN ('pending','verified','rejected'))
);

CREATE TABLE accounts (
    account_id   bigserial PRIMARY KEY,
    client_id    bigint      NOT NULL REFERENCES clients(client_id),
    currency     char(3)     NOT NULL,
    balance      numeric(18,2) NOT NULL DEFAULT 0,
    status       text        NOT NULL DEFAULT 'active',     -- active | blocked | closed
    opened_at    timestamptz NOT NULL,
    closed_at    timestamptz,
    CONSTRAINT accounts_status_chk  CHECK (status IN ('active','blocked','closed')),
    CONSTRAINT accounts_balance_chk CHECK (balance >= 0)
);

CREATE TABLE merchants (
    merchant_id  bigserial PRIMARY KEY,
    name         text    NOT NULL,
    category     text    NOT NULL,
    mcc          char(4) NOT NULL,      -- Merchant Category Code
    country      char(2) NOT NULL
);

CREATE TABLE payments (
    payment_id       bigserial PRIMARY KEY,
    account_id       bigint        NOT NULL REFERENCES accounts(account_id),
    merchant_id      bigint        REFERENCES merchants(merchant_id),
    amount           numeric(18,2) NOT NULL,
    currency         char(3)       NOT NULL,
    status           text          NOT NULL,   -- created | authorized | captured | declined | refunded
    method           text          NOT NULL,   -- card | sbp | transfer
    decline_reason   text,
    idempotency_key  uuid          NOT NULL UNIQUE,
    created_at       timestamptz   NOT NULL,
    authorized_at    timestamptz,
    captured_at      timestamptz,
    CONSTRAINT payments_amount_chk CHECK (amount > 0),
    CONSTRAINT payments_status_chk
        CHECK (status IN ('created','authorized','captured','declined','refunded')),
    CONSTRAINT payments_method_chk CHECK (method IN ('card','sbp','transfer'))
);

-- Леджер: только добавление, ничего не редактируется и не удаляется
CREATE TABLE transactions (
    txn_id     bigserial PRIMARY KEY,
    payment_id bigint        REFERENCES payments(payment_id),
    account_id bigint        NOT NULL REFERENCES accounts(account_id),
    direction  char(1)       NOT NULL,          -- D = дебет, C = кредит
    amount     numeric(18,2) NOT NULL,
    posted_at  timestamptz   NOT NULL,
    CONSTRAINT txn_direction_chk CHECK (direction IN ('D','C')),
    CONSTRAINT txn_amount_chk    CHECK (amount > 0)
);

CREATE TABLE refunds (
    refund_id  bigserial PRIMARY KEY,
    payment_id bigint        NOT NULL REFERENCES payments(payment_id),
    amount     numeric(18,2) NOT NULL,
    reason     text,
    created_at timestamptz   NOT NULL,
    CONSTRAINT refunds_amount_chk CHECK (amount > 0)
);

-- ---------------------------------------------------------------------
-- Данные. setseed делает генерацию воспроизводимой:
-- у тебя и у меня получатся одинаковые числа.
-- ---------------------------------------------------------------------

SELECT setseed(0.42);

-- 200 клиентов
INSERT INTO clients (full_name, email, phone, city, kyc_status, created_at)
SELECT
    (ARRAY['Анна','Борис','Виктор','Галина','Дмитрий','Елена','Жанна','Игорь',
           'Ксения','Леонид','Марина','Никита','Ольга','Павел','Роман','Светлана'])
      [1 + (i % 16)]
    || ' ' ||
    (ARRAY['Иванов','Петров','Сидоров','Кузнецов','Волков','Морозов','Новиков','Фёдоров'])
      [1 + (i % 8)],
    'client' || i || '@example.com',
    '+7900' || lpad(i::text, 7, '0'),
    (ARRAY['Москва','Санкт-Петербург','Казань','Новосибирск','Екатеринбург',
           'Белград','Ереван','Алматы'])[1 + (i % 8)],
    CASE WHEN i % 10 = 0 THEN 'pending'
         WHEN i % 37 = 0 THEN 'rejected'
         ELSE 'verified' END,
    timestamptz '2024-01-01 00:00:00+00' + (i || ' hours')::interval
FROM generate_series(1, 200) AS i;

-- Счета: у части клиентов их несколько, у некоторых нет вообще
INSERT INTO accounts (client_id, currency, balance, status, opened_at, closed_at)
SELECT
    c.client_id,
    (ARRAY['RUB','RUB','RUB','EUR','USD','RSD'])[1 + ((c.client_id + k) % 6)],
    round((random() * 500000)::numeric, 2),
    CASE WHEN (c.client_id + k) % 23 = 0 THEN 'blocked'
         WHEN (c.client_id + k) % 31 = 0 THEN 'closed'
         ELSE 'active' END,
    c.created_at + interval '1 day',
    CASE WHEN (c.client_id + k) % 31 = 0
         THEN c.created_at + interval '200 days' END
FROM clients c
CROSS JOIN generate_series(0, 2) AS k
WHERE c.client_id % 7 <> 0            -- каждый седьмой клиент остаётся без счетов
  AND (k = 0 OR c.client_id % 3 = 0); -- второй и третий счёт — только у каждого третьего

-- 40 мерчантов
INSERT INTO merchants (name, category, mcc, country)
SELECT
    (ARRAY['Ozon','Wildberries','Yandex Market','Aviasales','Delivery Club','Netflix',
           'Spotify','Steam','IKEA','Zara','Apple','Booking'])[1 + (i % 12)]
      || ' #' || i,
    (ARRAY['retail','travel','food','entertainment','software','fashion'])[1 + (i % 6)],
    (ARRAY['5411','4722','5812','7995','5734','5651'])[1 + (i % 6)],
    (ARRAY['RU','RS','NL','US','DE'])[1 + (i % 5)]
FROM generate_series(1, 40) AS i;

-- ~5000 платежей за 2025 год
INSERT INTO payments (account_id, merchant_id, amount, currency, status, method,
                      decline_reason, idempotency_key,
                      created_at, authorized_at, captured_at)
SELECT
    a.account_id,
    1 + (i % 40),
    round((10 + random() * 40000)::numeric, 2),
    a.currency,
    s.status,
    (ARRAY['card','card','card','sbp','transfer'])[1 + (i % 5)],
    CASE s.status WHEN 'declined'
         THEN (ARRAY['insufficient_funds','limit_exceeded','fraud_suspected','3ds_failed'])
              [1 + (i % 4)] END,
    gen_random_uuid(),
    ts.created_at,
    CASE WHEN s.status <> 'declined' THEN ts.created_at + interval '2 seconds' END,
    CASE WHEN s.status IN ('captured','refunded')
         THEN ts.created_at + ((1 + i % 48) || ' hours')::interval END
FROM generate_series(1, 5000) AS i
CROSS JOIN LATERAL (
    SELECT account_id, currency
    FROM accounts
    ORDER BY (account_id * 7919 + i) % 1000
    LIMIT 1
) AS a
CROSS JOIN LATERAL (
    SELECT timestamptz '2025-01-01 00:00:00+00'
           + ((i * 105) || ' minutes')::interval AS created_at
) AS ts
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN i % 17 = 0 THEN 'declined'
        WHEN i % 23 = 0 THEN 'refunded'
        WHEN i % 29 = 0 THEN 'authorized'
        WHEN i % 97 = 0 THEN 'created'
        ELSE 'captured' END AS status
) AS s;

-- Проводки: по одной паре дебет/кредит на каждый списанный платёж
INSERT INTO transactions (payment_id, account_id, direction, amount, posted_at)
SELECT p.payment_id, p.account_id, 'D', p.amount, p.captured_at
FROM payments p
WHERE p.status IN ('captured','refunded');

INSERT INTO transactions (payment_id, account_id, direction, amount, posted_at)
SELECT p.payment_id, p.account_id, 'C', p.amount, p.captured_at + interval '1 day'
FROM payments p
WHERE p.status = 'refunded';

-- Возвраты
INSERT INTO refunds (payment_id, amount, reason, created_at)
SELECT
    p.payment_id,
    p.amount,
    (ARRAY['client_request','goods_not_delivered','duplicate_charge','fraud'])
      [1 + (p.payment_id % 4)],
    p.captured_at + interval '1 day'
FROM payments p
WHERE p.status = 'refunded';

-- ---------------------------------------------------------------------
-- Индексы (пока намеренно минимум — на неделе 1 будем смотреть EXPLAIN
-- до и после добавления)
-- ---------------------------------------------------------------------

CREATE INDEX idx_accounts_client   ON accounts(client_id);
CREATE INDEX idx_payments_account  ON payments(account_id);
CREATE INDEX idx_payments_created  ON payments(created_at);

ANALYZE;

-- ---------------------------------------------------------------------
-- Проверка: должно вывести непустые числа
-- ---------------------------------------------------------------------

SELECT 'clients'      AS table_name, count(*) FROM clients
UNION ALL SELECT 'accounts',     count(*) FROM accounts
UNION ALL SELECT 'merchants',    count(*) FROM merchants
UNION ALL SELECT 'payments',     count(*) FROM payments
UNION ALL SELECT 'transactions', count(*) FROM transactions
UNION ALL SELECT 'refunds',      count(*) FROM refunds;
