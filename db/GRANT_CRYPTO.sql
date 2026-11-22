-- GRANT_CRYPTO.sql -- once, as SYS, in the pluggable database: BANK may use DBMS_CRYPTO, for the login of
-- the forms (BK_AUTH: the same PBKDF2-SHA256 of the passwords as bk-api). SYSTEM cannot give it: DBMS_CRYPTO
-- belongs to SYS.
--
--   sqlplus sys@localhost:1521/FREEPDB1 as sysdba @GRANT_CRYPTO.sql
--
-- (it asks for the password of SYS). Then INSTALL.sql again (without demo: the rows stay).
grant execute on sys.dbms_crypto to bank;
prompt == BANK may use DBMS_CRYPTO: now INSTALL.sql again
exit
