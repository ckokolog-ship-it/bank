-- BK_AUTH.sql -- the login of the forms: the same users and sessions as the pages (bk-api: BK_USER,
-- BK_SESSION), so a user has one password and one lock for both. The password: PBKDF2-SHA256 with its own
-- salt and iterations (as Java's PBKDF2WithHmacSHA256: the same hash); 5 wrong in a row: locked (an ADMIN
-- unlocks it). A login: a token of 32 random bytes for 12 hours; only its SHA-256 is kept. Needs DBMS_CRYPTO
-- (GRANT_CRYPTO.sql, as SYS); INSTALL.sql runs this only then.
--
-- It commits (the count of the wrong passwords must stay, the login fails or not).
create or replace package bk_auth as
  function pbkdf2(p_password varchar2, p_salt raw, p_iter pls_integer) return raw;
  -- the token of a login; the role and the full name of the user
  procedure login(p_username varchar2, p_password varchar2, p_client varchar2,
                  o_token out varchar2, o_role out varchar2, o_full_name out varchar2);
  -- who has the token (BK-143: none, expired, revoked, the user inactive or locked)
  procedure check_token(p_token varchar2, o_user_id out number, o_username out varchar2, o_role out varchar2);
  procedure logout(p_token varchar2);
  -- a role at least p_need (TELLER < MANAGER < ADMIN): 'Y' or 'N'
  function at_least(p_role varchar2, p_need varchar2) return varchar2;
end bk_auth;
/

create or replace package body bk_auth as
  c_max_failed constant pls_integer := 5;

  procedure fail(p_no pls_integer, p_text varchar2) is
  begin
    raise_application_error(-20100 - p_no, 'BK-' || to_char(100 + p_no) || ': ' || p_text);
  end;

  function pbkdf2(p_password varchar2, p_salt raw, p_iter pls_integer) return raw is
    k raw(2000) := utl_i18n.string_to_raw(p_password, 'AL32UTF8');
    u raw(32);
    t raw(32);
  begin
    -- one block of 32 bytes (the length of the hash): U1 = HMAC(salt || 00000001), Ui = HMAC(Ui-1), T = xor of them
    u := dbms_crypto.mac(utl_raw.concat(p_salt, hextoraw('00000001')), dbms_crypto.hmac_sh256, k);
    t := u;
    for i in 2 .. p_iter loop
      u := dbms_crypto.mac(u, dbms_crypto.hmac_sh256, k);
      t := utl_raw.bit_xor(t, u);
    end loop;
    return t;
  end;

  function sha256(p varchar2) return raw is
  begin
    return dbms_crypto.hash(utl_i18n.string_to_raw(p, 'AL32UTF8'), dbms_crypto.hash_sh256);
  end;

  procedure login(p_username varchar2, p_password varchar2, p_client varchar2,
                  o_token out varchar2, o_role out varchar2, o_full_name out varchar2) is
    u bk_user%rowtype;
    h raw(32);
  begin
    begin
      select * into u from bk_user where username = lower(trim(p_username)) for update;
    exception
      when no_data_found then
        h := pbkdf2(nvl(p_password, ' '), hextoraw('00'), 1000);          -- (about the same time)
        fail(41, 'Λάθος όνομα ή κωδικός');
    end;
    if u.failed >= c_max_failed then
      rollback;
      fail(42, 'Ο χρήστης κλειδώθηκε μετά από ' || c_max_failed || ' λάθος κωδικούς: τον ξεκλειδώνει ένας ADMIN');
    end if;
    h := pbkdf2(nvl(p_password, ' '), u.pw_salt, u.pw_iter);
    if h <> u.pw_hash or u.active <> 'Y' then
      update bk_user set failed = failed + 1 where id = u.id;
      commit;
      fail(41, 'Λάθος όνομα ή κωδικός');
    end if;
    o_token := rtrim(translate(utl_raw.cast_to_varchar2(utl_encode.base64_encode(dbms_crypto.randombytes(32))), '+/', '-_'), '=');
    update bk_user set failed = 0 where id = u.id;
    delete from bk_session where expires_at < sysdate - 30;
    h := sha256(o_token);                                                -- (not in SQL: PLS-00231)
    insert into bk_session (token_hash, user_id, client, expires_at)
    values (h, u.id, substr(p_client, 1, 60), sysdate + 12 / 24);
    commit;
    o_role := u.role;
    o_full_name := u.full_name;
  end;

  procedure check_token(p_token varchar2, o_user_id out number, o_username out varchar2, o_role out varchar2) is
    h raw(32) := sha256(nvl(p_token, ' '));
  begin
    select u.id, u.username, u.role into o_user_id, o_username, o_role
    from bk_session s join bk_user u on u.id = s.user_id
    where s.token_hash = h and s.revoked = 'N' and s.expires_at > sysdate
      and u.active = 'Y' and u.failed < c_max_failed;
  exception
    when no_data_found then
      fail(43, 'Η σύνδεση έληξε: ξανά είσοδος');
  end;

  procedure logout(p_token varchar2) is
    h raw(32) := sha256(nvl(p_token, ' '));
  begin
    update bk_session set revoked = 'Y' where token_hash = h;
    commit;
  end;

  function at_least(p_role varchar2, p_need varchar2) return varchar2 is
  begin
    return case when instr('TELLER MANAGER ADMIN', p_role) >= instr('TELLER MANAGER ADMIN', p_need)
                     and instr('TELLER MANAGER ADMIN', p_role) > 0 then 'Y' else 'N' end;
  end;
end bk_auth;
/
