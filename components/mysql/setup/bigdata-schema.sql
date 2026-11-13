-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- MySQL "bigdata" database for the Trino mysql.bigdata catalog. Idempotent.
-- The trino user password is set by apply-bigdata-schema.sh from hive-credentials (mysql-trino-password).

CREATE DATABASE IF NOT EXISTS bigdata CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS bigdata.sample_customers (
  id   INT PRIMARY KEY,
  name VARCHAR(64),
  city VARCHAR(64)
);
INSERT IGNORE INTO bigdata.sample_customers (id, name, city) VALUES
  (1, 'Ana',  'Madrid'),
  (2, 'Ben',  'Boston'),
  (3, 'Chen', 'Shanghai');

-- trino: read/write on the bigdata database only. Granted after the database exists.
CREATE USER IF NOT EXISTS 'trino'@'%' IDENTIFIED BY 'placeholder_reset_by_script_1A';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER ON bigdata.* TO 'trino'@'%';
