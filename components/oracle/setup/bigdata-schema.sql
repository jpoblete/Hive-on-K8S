-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- oracle.bigdata: in Oracle the Trino "database" is a schema under a user.
-- Schema BIGDATA is owned by user BIGDATA; TRINO can only touch objects in BIGDATA.
-- Run as SYSDBA inside the application PDB (FREEPDB1). Idempotent via guarded blocks.
-- The TRINO password is set by apply-bigdata-schema.sh from the hive-credentials Secret, not here.

ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'BIGDATA';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER bigdata NO AUTHENTICATION';
  END IF;
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'TRINO';
  IF n = 0 THEN
    -- password is set by the wrapper script (ALTER USER ... IDENTIFIED BY) right after this
    EXECUTE IMMEDIATE 'CREATE USER trino IDENTIFIED BY "placeholder_reset_by_script_1A"';
  END IF;
END;
/

GRANT CREATE SESSION TO trino;
GRANT UNLIMITED TABLESPACE TO bigdata;
GRANT CREATE TABLE TO bigdata;

-- Sample table (owned by the bigdata schema user). Idempotent.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_tables WHERE owner = 'BIGDATA' AND table_name = 'SAMPLE_CUSTOMERS';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE bigdata.sample_customers (id NUMBER PRIMARY KEY, name VARCHAR2(64), city VARCHAR2(64))';
    EXECUTE IMMEDIATE 'INSERT INTO bigdata.sample_customers VALUES (1, ''Ana'', ''Madrid'')';
    EXECUTE IMMEDIATE 'INSERT INTO bigdata.sample_customers VALUES (2, ''Ben'', ''Boston'')';
    EXECUTE IMMEDIATE 'INSERT INTO bigdata.sample_customers VALUES (3, ''Chen'', ''Shanghai'')';
    COMMIT;
  END IF;
END;
/

-- trino: read/write on objects owned by bigdata only. Granted AFTER the table exists
-- (a GRANT on a missing object fails and would leave trino with no access on a fresh run).
GRANT SELECT, INSERT, UPDATE, DELETE ON bigdata.sample_customers TO trino;
