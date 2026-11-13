-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- Schema, grants, and sample data for the postgres.bigdata Trino catalog.
-- Idempotent: safe to re-run. Applied to database "bigdata" on postgres-0 (see apply-bigdata-schema.sh).
-- The trino role itself (LOGIN + password) is created by apply-bigdata-schema.sh from the Secret, not here.

CREATE SCHEMA IF NOT EXISTS bigdata AUTHORIZATION postgres;

-- trino may use and create objects in bigdata only, and nothing in public.
GRANT CONNECT ON DATABASE bigdata TO trino;
GRANT USAGE, CREATE ON SCHEMA bigdata TO trino;
REVOKE ALL ON SCHEMA public FROM trino;

CREATE TABLE IF NOT EXISTS bigdata.sample_customers (
  id   INT PRIMARY KEY,
  name VARCHAR(64),
  city VARCHAR(64)
);
INSERT INTO bigdata.sample_customers (id, name, city) VALUES
  (1, 'Ana',  'Madrid'),
  (2, 'Ben',  'Boston'),
  (3, 'Chen', 'Shanghai')
ON CONFLICT (id) DO NOTHING;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bigdata TO trino;
ALTER DEFAULT PRIVILEGES IN SCHEMA bigdata GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO trino;
