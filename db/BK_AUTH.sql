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

  -- the users (the form BK_USERS; the pages do the same in bk-api): a new one; a new password (unlocked, its
  -- sessions ended); its role; active or not (not: its sessions ended); unlocked. Always an active ADMIN left
  function create_user(p_username varchar2, p_full_name varchar2, p_role varchar2, p_password varchar2) return number;
  procedure set_password(p_user_id number, p_password varchar2);
  procedure set_role(p_user_id number, p_role varchar2);
  procedure set_active(p_user_id number, p_active varchar2);
  procedure unlock(p_user_id number);

  -- a new PIN of a card (4 digits, not all the same, not 1234): its hash kept (as bk-api: PBKDF2-SHA256), the
  -- card unlocked; the PIN back, once: for its holder
  function new_pin(p_card_id number) return varchar2;
end bk_auth;
/

create or replace package body bk_auth as
  c_max_failed constant pls_integer := 5;
  c_iter constant pls_integer := 120000;         -- (the passwords and the PINs: as bk-api, Auth.ITERATIONS)

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

  procedure password_ok(p varchar2) is
  begin
    if p is null or length(p) < 8 then
      fail(44, 'Ο κωδικός: τουλάχιστον 8 χαρακτήρες');
    end if;
  end;

  procedure role_ok(p varchar2) is
  begin
    if p is null or p not in ('TELLER', 'MANAGER', 'ADMIN') then
      fail(44, 'Ρόλος: TELLER, MANAGER ή ADMIN');
    end if;
  end;

  function user_row(p_user_id number) return bk_user%rowtype is
    u bk_user%rowtype;
  begin
    select * into u from bk_user where id = p_user_id for update;
    return u;
  exception
    when no_data_found then
      fail(44, 'Δεν υπάρχει χρήστης ' || p_user_id);
  end;

  -- an active ADMIN stays, other than p_user_id
  procedure keep_an_admin(p_user_id number) is
    n number;
  begin
    select count(*) into n from bk_user where role = 'ADMIN' and active = 'Y' and id <> p_user_id;
    if n = 0 then
      fail(44, 'Μένει πάντα ένας ενεργός ADMIN');
    end if;
  end;

  function create_user(p_username varchar2, p_full_name varchar2, p_role varchar2, p_password varchar2) return number is
    u varchar2(30) := lower(trim(p_username));
    s raw(16) := dbms_crypto.randombytes(16);
    h raw(32);
    v number;
  begin
    if u is null or not regexp_like(u, '^[a-z0-9._-]{2,30}$') then
      fail(44, 'Όνομα χρήστη: 2 ως 30 πεζά γράμματα, ψηφία, . _ -');
    end if;
    if trim(p_full_name) is null then
      fail(44, 'Το ονοματεπώνυμο του χρήστη');
    end if;
    role_ok(upper(p_role));
    password_ok(p_password);
    h := pbkdf2(p_password, s, c_iter);
    insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter)
    values (u, trim(p_full_name), upper(p_role), h, s, c_iter) returning id into v;
    return v;
  exception
    when dup_val_on_index then
      fail(44, 'Υπάρχει ήδη χρήστης ' || u);
  end;

  procedure set_password(p_user_id number, p_password varchar2) is
    u bk_user%rowtype := user_row(p_user_id);
    s raw(16) := dbms_crypto.randombytes(16);
    h raw(32);
  begin
    password_ok(p_password);
    h := pbkdf2(p_password, s, c_iter);
    update bk_user set pw_hash = h, pw_salt = s, pw_iter = c_iter, failed = 0 where id = u.id;
    update bk_session set revoked = 'Y' where user_id = u.id;
  end;

  procedure set_role(p_user_id number, p_role varchar2) is
    u bk_user%rowtype := user_row(p_user_id);
  begin
    role_ok(upper(p_role));
    if u.role = 'ADMIN' and u.active = 'Y' and upper(p_role) <> 'ADMIN' then
      keep_an_admin(u.id);
    end if;
    update bk_user set role = upper(p_role) where id = u.id;
  end;

  procedure set_active(p_user_id number, p_active varchar2) is
    u bk_user%rowtype := user_row(p_user_id);
  begin
    if p_active is null or p_active not in ('Y', 'N') then
      fail(44, 'Ενεργός: Y ή N');
    end if;
    if p_active = 'N' and u.role = 'ADMIN' and u.active = 'Y' then
      keep_an_admin(u.id);
    end if;
    update bk_user set active = p_active where id = u.id;
    if p_active = 'N' then
      update bk_session set revoked = 'Y' where user_id = u.id;
    end if;
  end;

  procedure unlock(p_user_id number) is
    u bk_user%rowtype := user_row(p_user_id);
  begin
    update bk_user set failed = 0 where id = u.id;
  end;

  function new_pin(p_card_id number) return varchar2 is
    st varchar2(1);
    p varchar2(4);
    s raw(16) := dbms_crypto.randombytes(16);
    h raw(32);
  begin
    begin
      select status into st from bk_card where id = p_card_id for update;
    exception
      when no_data_found then fail(33, 'Δεν υπάρχει η κάρτα');
    end;
    if st = 'C' then
      fail(34, 'Η κάρτα είναι ακυρωμένη');
    end if;
    loop
      p := lpad(mod(abs(dbms_crypto.randominteger), 10000), 4, '0');
      exit when p <> '1234' and p <> rpad(substr(p, 1, 1), 4, substr(p, 1, 1));
    end loop;
    h := pbkdf2(p, s, c_iter);
    update bk_card set pin_hash = h, pin_salt = s, pin_iter = c_iter, pin_failed = 0 where id = p_card_id;
    return p;
  end;

  function at_least(p_role varchar2, p_need varchar2) return varchar2 is
  begin
    return case when instr('TELLER MANAGER ADMIN', p_role) >= instr('TELLER MANAGER ADMIN', p_need)
                     and instr('TELLER MANAGER ADMIN', p_role) > 0 then 'Y' else 'N' end;
  end;
end bk_auth;
/
