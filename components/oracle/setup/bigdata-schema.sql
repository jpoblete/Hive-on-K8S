-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- oracle.bigdata: the lowercase Oracle user "bigdata" owns the schema; Trino sees it as oracle."bigdata".
-- TRINO can only touch objects in the bigdata schema. Run as SYSDBA inside FREEPDB1. Idempotent.
-- The TRINO password is set by apply-bigdata-schema.sh from the hive-credentials Secret, not here.

ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'bigdata';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER "bigdata" NO AUTHENTICATION';
  END IF;
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'TRINO';
  IF n = 0 THEN
    -- password is set by the wrapper script right after this
    EXECUTE IMMEDIATE 'CREATE USER trino IDENTIFIED BY "placeholder_reset_by_script_1A"';
  END IF;
END;
/

GRANT CREATE SESSION TO trino;
GRANT UNLIMITED TABLESPACE TO "bigdata";
GRANT CREATE TABLE TO "bigdata";

-- Sample table, owned by bigdata. Idempotent.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_tables WHERE owner = 'bigdata' AND table_name = 'sample_customers';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE "bigdata"."sample_customers" (id NUMBER PRIMARY KEY, name VARCHAR2(64), city VARCHAR2(64))';
    EXECUTE IMMEDIATE 'INSERT INTO "bigdata"."sample_customers" VALUES (1, ''Ana'', ''Madrid'')';
    EXECUTE IMMEDIATE 'INSERT INTO "bigdata"."sample_customers" VALUES (2, ''Ben'', ''Boston'')';
    EXECUTE IMMEDIATE 'INSERT INTO "bigdata"."sample_customers" VALUES (3, ''Chen'', ''Shanghai'')';
    COMMIT;
  END IF;
END;
/

-- trino: read/write on the bigdata table only. Granted AFTER the table exists.
GRANT SELECT, INSERT, UPDATE, DELETE ON "bigdata"."sample_customers" TO trino;
