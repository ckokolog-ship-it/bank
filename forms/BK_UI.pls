-- BK_UI.pls -- the package UI of the forms of the bank (BK_LOGIN, BK_MAIN, BK_CUSTOMERS, BK_ACCOUNTS, BK_MOVE,
-- BK_DAY, BK_RULES, BK_PRODUCTS, BK_CARDS, BK_CCARDS, BK_FX, BK_ATMS, BK_USERS): mkforms.py puts it in each form. The triggers only call it:
--   WHEN-NEW-FORM-INSTANCE   ui.init
--   WHEN-NEW-RECORD-INSTANCE ui.master(:SYSTEM.TRIGGER_BLOCK)   (a master: its detail again)
--   WHEN-BUTTON-PRESSED      ui.press(:SYSTEM.TRIGGER_ITEM)   (the toolbar: ui.tool)
--   WHEN-VALIDATE-ITEM       ui.validate(:SYSTEM.TRIGGER_ITEM)
--   POST-QUERY               ui.post_query(:SYSTEM.TRIGGER_BLOCK)
--   ON-ERROR, ON-MESSAGE     ui.on_error, ui.on_message
-- Items through NAME_IN and COPY (no :BLOCK.ITEM): so tests/test_forms.py compiles and runs it in the database,
-- without the Forms. Every Greek string here becomes bk_text.t('T...') (mkforms.py). Everything that writes
-- goes through BK_CORE, then COMMIT (FORMS_DDL); an error of it: ROLLBACK, and its words (BK-1xx) as they are.
PACKAGE ui IS
  PROCEDURE init;
  PROCEDURE press(p_item VARCHAR2);
  PROCEDURE tool(p_item VARCHAR2);
  PROCEDURE dblclick(p_item VARCHAR2);
  PROCEDURE validate(p_item VARCHAR2);
  PROCEDURE post_query(p_block VARCHAR2);
  PROCEDURE master(p_block VARCHAR2);
  PROCEDURE on_error(p_code NUMBER, p_type VARCHAR2, p_text VARCHAR2, p_dbtext VARCHAR2);
  PROCEDURE on_message(p_code NUMBER, p_type VARCHAR2, p_text VARCHAR2);
  FUNCTION friendly(p_dbtext VARCHAR2) RETURN VARCHAR2;
END;
-- BODY
PACKAGE BODY ui IS
  c_block CONSTANT VARCHAR2(30) := 'BLOCK'; -- BLOCK
  c_where CONSTANT VARCHAR2(400) := ''; -- WHERE
  c_detail CONSTANT VARCHAR2(30) := ''; -- DETAIL
  c_detail2 CONSTANT VARCHAR2(30) := ''; -- DETAIL2
  c_role CONSTANT VARCHAR2(10) := ''; -- ROLE
  c_form CONSTANT VARCHAR2(30) := ''; -- FORM
  g_user VARCHAR2(30);              -- who logged in (BK_LOGIN: the token in GLOBAL.BK_TOKEN), its role, its id
  g_role VARCHAR2(10);
  g_uid NUMBER;
  g_master NUMBER;                  -- the master whose detail is on the screen
  g_detail NUMBER;                  -- the record of the detail whose own detail is on the screen

  FUNCTION num(p_item VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN to_number(name_in(p_item));
  END;

  FUNCTION tx(p_key VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN bk_text.t(p_key);
  END;

  PROCEDURE fail(p_msg VARCHAR2) IS
  BEGIN
    message(p_msg);
    RAISE form_trigger_failure;
  END;

  -- the role of the user at least p_need (TELLER < MANAGER < ADMIN)
  FUNCTION at_least(p_need VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN bk_auth.at_least(g_role, p_need) = 'Y';
  END;

  -- (in another currency than the euro: its code)
  FUNCTION money(p NUMBER, p_cur VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    IF nvl(p_cur, 'EUR') = 'EUR' THEN
      RETURN to_char(p, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''') || ' €';
    END IF;
    RETURN to_char(p, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''') || ' ' || p_cur;
  END;

  FUNCTION date_in(p_item VARCHAR2) RETURN DATE IS
  BEGIN
    RETURN to_date(name_in(p_item), 'DD/MM/YYYY');
  END;

  -- a report of reports/ (the Reports Server: REPORTS_URL of BK_SETTING, db/SET_REPORTS_URL.sql) in a new
  -- window of the browser, in REPORTS_FORMAT (PDF by default); p_params: &P_...=...
  PROCEDURE open_report(p_report VARCHAR2, p_params VARCHAR2) IS
    u VARCHAR2(400);
    f VARCHAR2(20);
  BEGIN
    SELECT max(CASE name WHEN 'REPORTS_URL' THEN value END), max(CASE name WHEN 'REPORTS_FORMAT' THEN value END)
    INTO u, f FROM bk_setting WHERE name IN ('REPORTS_URL', 'REPORTS_FORMAT');
    IF u IS NULL THEN
      fail('Δεν ορίστηκε ο Reports Server (db/SET_REPORTS_URL.sql)');
    END IF;
    IF f IS NULL THEN
      f := 'PDF';
    END IF;
    web.show_document(u || '&report=' || p_report || '.rdf&destype=cache&desformat=' || f || p_params, '_blank');
  END;

  -- the login of this form: the token of BK_LOGIN still good (the user active, not locked), and its role at
  -- least the role of the form; else to the login, or back to the first menu. The database knows who it is
  -- (CLIENT_IDENTIFIER: BK_ENTRY.CREATED_BY)
  FUNCTION session_ok RETURN BOOLEAN IS
    u NUMBER;
  BEGIN
    IF c_role IS NULL THEN                -- BK_LOGIN itself
      RETURN TRUE;
    END IF;
    default_value('', 'GLOBAL.BK_TOKEN');
    BEGIN
      bk_auth.check_token(name_in('GLOBAL.BK_TOKEN'), u, g_user, g_role);
      g_uid := u;
    EXCEPTION
      WHEN OTHERS THEN
        g_user := NULL;
        g_role := NULL;
        new_form('BK_LOGIN');
        RETURN FALSE;
    END;
    dbms_session.set_identifier(g_user);
    set_window_property('WIN', TITLE, get_window_property('WIN', TITLE) || '  [' || g_user || ']');
    IF NOT at_least(c_role) THEN
      message('Η φόρμα θέλει ρόλο ' || c_role || ': ' || g_user);
      new_form('BK_MAIN');
      RETURN FALSE;
    END IF;
    RETURN TRUE;
  END;

  -- a block of a higher role: read only (its rows seen, not changed)
  PROCEDURE read_only_block(p_block VARCHAR2) IS
  BEGIN
    set_block_property(p_block, INSERT_ALLOWED, PROPERTY_FALSE);
    set_block_property(p_block, UPDATE_ALLOWED, PROPERTY_FALSE);
    set_block_property(p_block, DELETE_ALLOWED, PROPERTY_FALSE);
  END;

  -- the master block again, all of it
  PROCEDURE requery IS
  BEGIN
    go_block(c_block);
    set_block_property(c_block, DEFAULT_WHERE, c_where);
    g_master := NULL;
    execute_query;
  END;

  -- the master block shown again with one record only (after a change by BK_CORE: the same record on the screen)
  PROCEDURE show_only(p_id NUMBER) IS
  BEGIN
    go_block(c_block);
    set_block_property(c_block, DEFAULT_WHERE, 'id = ' || to_char(p_id));
    g_master := NULL;
    execute_query;
    set_block_property(c_block, DEFAULT_WHERE, c_where);
  END;

  -- the account of BK_MOVE: its balance, what is available, its last moves
  PROCEDURE move_refresh IS
    acc NUMBER := num('CTL.M_ACC_ID');
    b NUMBER;
    a NUMBER;
    t VARCHAR2(200);
    c VARCHAR2(3);
  BEGIN
    IF acc IS NULL THEN
      RETURN;
    END IF;
    SELECT iban || ' ' || holder, balance, CASE WHEN status = 'O' THEN balance + od_limit ELSE 0 END, currency
    INTO t, b, a, c FROM bk_account_v WHERE id = acc;
    copy(t, 'CTL.M_ACC_TEXT');
    copy(money(b, c), 'CTL.M_BAL');
    copy(money(a, c), 'CTL.M_AVAIL');
    go_block('LAST');
    set_block_property('LAST', DEFAULT_WHERE, 'account_id = ' || to_char(acc));
    execute_query;
    go_item('CTL.M_AMOUNT');
  END;

  -- BK_DAY: the business day, the last closed, the entries of the day, BK_CHECK
  PROCEDURE day_refresh IS
    d DATE;
    l DATE;
    n NUMBER;
    s VARCHAR2(400);
  BEGIN
    d := bk_core.open_day;
    SELECT max(day) INTO l FROM bk_day;
    copy(to_char(d, 'DD/MM/YYYY'), 'CTL.D_OPEN');
    copy(to_char(l, 'DD/MM/YYYY'), 'CTL.D_LAST');
    SELECT count(*) INTO n FROM bk_entry WHERE book_date = d;
    copy(to_char(n), 'CTL.D_ENTRIES');
    SELECT count(*) INTO n FROM bk_check;
    IF n = 0 THEN
      copy('Όλα συμφωνούν', 'CTL.D_CHECK');
    ELSE
      SELECT what || ' ' || ref || ': ' || detail INTO s FROM bk_check WHERE rownum = 1;
      copy(substr(n || ' διαφορές: ' || s, 1, 300), 'CTL.D_CHECK');
    END IF;
  END;

  -- what each form needs when it opens
  PROCEDURE init_form IS
    acc VARCHAR2(40);
    t2 VARCHAR2(40);
  BEGIN
    IF c_form = 'BK_MAIN' THEN
      copy('Εργάσιμη ημέρα ' || to_char(bk_core.open_day, 'DD/MM/YYYY') || '  ·  ' || g_user || ' (' || g_role || ')',
           'CTL.D_OPEN');
    ELSIF c_form = 'BK_MOVE' THEN
      copy(to_char(bk_core.open_day, 'DD/MM/YYYY'), 'CTL.M_VDATE');
      copy('Κατάθεση', 'CTL.M_KIND_TEXT');
      -- from BK_ACCOUNTS (Νέα κίνηση): its account
      default_value('', 'GLOBAL.BK_ACCOUNT');
      acc := name_in('GLOBAL.BK_ACCOUNT');
      IF acc IS NOT NULL THEN
        copy(acc, 'CTL.M_ACC_ID');
        copy('', 'GLOBAL.BK_ACCOUNT');
        move_refresh;
      END IF;
    ELSIF c_form = 'BK_DAY' THEN
      day_refresh;
    ELSIF c_form = 'BK_PRODUCTS' THEN
      copy(to_char(bk_core.open_day, 'DD/MM/YYYY'), 'CTL.N_FROM');
    ELSIF c_form = 'BK_ATMS' THEN
      SELECT max(CASE name WHEN 'ATM_NOTES' THEN value END), max(CASE name WHEN 'ATM_MAX_NOTES' THEN value END)
      INTO acc, t2 FROM bk_setting WHERE name IN ('ATM_NOTES', 'ATM_MAX_NOTES');
      copy(acc, 'CTL.S_NOTES');
      copy(t2, 'CTL.S_MAX');
    END IF;
  END;

  PROCEDURE init IS
  BEGIN
    NULL; -- TEXTS
    IF NOT session_ok THEN
      RETURN;
    END IF;
    NULL; -- ROLES
    IF c_block IS NOT NULL THEN          -- (the menu has no block of a table)
      go_block(c_block);
      set_block_property(c_block, DEFAULT_WHERE, c_where);
      execute_query;
    END IF;
    init_form;
  END;

  -- the detail of the master record on the screen (once for each master record)
  PROCEDURE back_to(p_item VARCHAR2) IS
  BEGIN
    IF p_item LIKE c_block || '.%' THEN
      go_item(p_item);
    ELSE
      go_block(c_block);
    END IF;
  END;

  PROCEDURE master(p_block VARCHAR2) IS
    id_ NUMBER := num(p_block || '.ID');
    at_ VARCHAR2(80) := name_in('SYSTEM.CURSOR_ITEM');
  BEGIN
    IF id_ IS NULL THEN
      IF p_block = c_block AND c_detail IS NOT NULL AND g_master IS NOT NULL THEN
        g_master := NULL;
        g_detail := NULL;
        go_block(c_detail);
        clear_block(NO_VALIDATE);
        back_to(at_);
      END IF;
      RETURN;
    END IF;
    IF p_block = c_block AND c_detail IS NOT NULL THEN
      IF id_ = g_master THEN
        RETURN;
      END IF;
      g_master := id_;
      g_detail := NULL;
      go_block(c_detail);
      execute_query;
      back_to(at_);
    ELSIF p_block = c_detail AND c_detail2 IS NOT NULL THEN
      IF id_ = g_detail THEN
        RETURN;
      END IF;
      g_detail := id_;
      go_block(c_detail2);
      execute_query;
      go_block(c_detail);
    END IF;
  END;

  -- the work of a button, through BK_CORE; then COMMIT
  PROCEDURE action(p_item VARCHAR2) IS
    id_ NUMBER;
    acc NUMBER;
    e NUMBER;
    amt NUMBER;
    k VARCHAR2(3);
    st VARCHAR2(1);
    t VARCHAR2(200);
    tok VARCHAR2(100);
    r VARCHAR2(10);
    d DATE;
  BEGIN
    IF p_item IN ('CTL.LOGIN', 'CTL.L_PW') THEN
      BEGIN
        bk_auth.login(name_in('CTL.L_USER'), name_in('CTL.L_PW'), 'forms', tok, r, t);
      EXCEPTION
        WHEN OTHERS THEN
          copy('', 'CTL.L_PW');
          fail(friendly(sqlerrm));
      END;
      copy(tok, 'GLOBAL.BK_TOKEN');
      copy('', 'CTL.L_PW');
      new_form('BK_MAIN');
    ELSIF p_item = 'CTL.EXIT' THEN
      exit_form;
    ELSIF p_item = 'CTL.LOGOUT' THEN
      BEGIN
        bk_auth.logout(name_in('GLOBAL.BK_TOKEN'));
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;
      copy('', 'GLOBAL.BK_TOKEN');
      new_form('BK_LOGIN');
    ELSIF p_item LIKE 'CTL.GO\_BK\_%' ESCAPE '\' AND p_item <> 'CTL.GO_BK_MOVE' THEN
      new_form(substr(p_item, 8));
    ELSIF p_item = 'CTL.GO_BK_MOVE' THEN
      IF c_form = 'BK_ACCOUNTS' THEN       -- the account on the screen to the movement
        copy(name_in('ACC.ID'), 'GLOBAL.BK_ACCOUNT');
      END IF;
      new_form('BK_MOVE');

    -- BK_CUSTOMERS: a new customer; a new account of the one on the screen
    ELSIF p_item = 'CTL.NEWCUST' THEN
      id_ := bk_core.new_customer(p_name => name_in('CTL.C_NAME'), p_afm => name_in('CTL.C_AFM'),
                                  p_phone => name_in('CTL.C_PHONE'), p_email => name_in('CTL.C_EMAIL'));
      forms_ddl('COMMIT');
      SELECT code INTO t FROM bk_customer WHERE id = id_;
      copy('', 'CTL.C_NAME');
      copy('', 'CTL.C_AFM');
      copy('', 'CTL.C_PHONE');
      copy('', 'CTL.C_EMAIL');
      show_only(id_);
      message('Ο πελάτης ' || t || ' καταχωρίστηκε');
    ELSIF p_item = 'CTL.NEWACC' THEN
      id_ := num('CUST.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένας πελάτης στην οθόνη');
      END IF;
      acc := bk_core.open_account(p_product_code => name_in('CTL.A_PRODUCT'), p_customer_id => id_,
                                  p_od_limit => nvl(num('CTL.A_OD'), 0), p_currency => name_in('CTL.A_CURRENCY'));
      forms_ddl('COMMIT');
      SELECT iban || ' (' || currency || ')' INTO t FROM bk_account WHERE id = acc;
      g_master := NULL;
      go_block('CA');
      execute_query;
      go_block(c_block);
      message('Άνοιξε ο λογαριασμός ' || t);

    -- BK_ACCOUNTS: the account on the screen
    ELSIF p_item IN ('CTL.SETOD', 'CTL.BLOCKACC', 'CTL.ACCRUE', 'CTL.CLOSEACC', 'CTL.REVERSE') THEN
      acc := num('ACC.ID');
      IF acc IS NULL THEN
        fail('Πρώτα ένας λογαριασμός στην οθόνη');
      END IF;
      IF p_item = 'CTL.SETOD' THEN
        bk_core.set_od_limit(acc, nvl(num('CTL.O_LIMIT'), 0));
        t := 'Το όριο υπερανάληψης άλλαξε';
      ELSIF p_item = 'CTL.BLOCKACC' THEN
        SELECT status INTO st FROM bk_account WHERE id = acc;
        IF st = 'O' THEN
          bk_core.set_status(acc, 'B');
          t := 'Ο λογαριασμός δεσμεύτηκε';
        ELSE
          bk_core.set_status(acc, 'O');
          t := 'Ο λογαριασμός αποδεσμεύτηκε';
        END IF;
      ELSIF p_item = 'CTL.ACCRUE' THEN
        bk_core.accrue(acc);
        t := 'Οι τόκοι μετρήθηκαν ως χθες';
      ELSIF p_item = 'CTL.CLOSEACC' THEN
        bk_core.close_account(acc);
        t := 'Ο λογαριασμός έκλεισε';
      ELSE
        e := num('ST.ENTRY_ID');
        IF e IS NULL THEN
          fail('Πρώτα μια κίνηση από κάτω');
        END IF;
        e := bk_core.reverse(e, name_in('CTL.R_DESCR'));
        copy('', 'CTL.R_DESCR');
        t := 'Αντιλογισμός: εγγραφή #' || e;
      END IF;
      forms_ddl('COMMIT');
      show_only(acc);
      message(t);

    -- BK_ACCOUNTS: the statement or the interest of the account on the screen (its interest counted first)
    ELSIF p_item IN ('CTL.PRINTST', 'CTL.PRINTINT') THEN
      acc := num('ACC.ID');
      IF acc IS NULL THEN
        fail('Πρώτα ένας λογαριασμός στην οθόνη');
      END IF;
      IF name_in('CTL.P_FROM') IS NULL OR name_in('CTL.P_TO') IS NULL OR date_in('CTL.P_FROM') > date_in('CTL.P_TO') THEN
        fail('Το διάστημα: από - έως (ΗΗ/ΜΜ/ΕΕΕΕ)');
      END IF;
      t := '&P_ACCOUNT=' || acc || '&P_FROM=' || to_char(date_in('CTL.P_FROM'), 'DD/MM/YYYY')
           || '&P_TO=' || to_char(date_in('CTL.P_TO'), 'DD/MM/YYYY');
      IF p_item = 'CTL.PRINTINT' THEN
        bk_core.accrue(acc);
        forms_ddl('COMMIT');
        open_report('BK_INTEREST', '&P_KIND=I' || t);
      ELSE
        open_report('BK_STATEMENT', '&P_KIND=S' || t);
      END IF;

    -- BK_MOVE: the account; a movement
    ELSIF p_item = 'CTL.SHOWACC' THEN
      IF num('CTL.M_ACC_ID') IS NULL THEN
        fail('Πρώτα ένας λογαριασμός (λίστα)');
      END IF;
      move_refresh;
    ELSIF p_item = 'CTL.SAVE' THEN
      acc := num('CTL.M_ACC_ID');
      k := name_in('CTL.M_KIND');
      amt := num('CTL.M_AMOUNT');
      d := date_in('CTL.M_VDATE');
      t := name_in('CTL.M_DESCR');
      IF acc IS NULL THEN
        fail('Πρώτα ένας λογαριασμός (λίστα)');
      END IF;
      IF k = 'DEP' THEN
        e := bk_core.deposit(acc, amt, t, d, 'BR');
      ELSIF k = 'WDR' THEN
        e := bk_core.withdraw(acc, amt, t, d, 'BR');
      ELSIF k = 'TRF' THEN
        IF num('CTL.M_TO_ID') IS NULL THEN
          fail('Η μεταφορά θέλει λογαριασμό της τράπεζας (λίστα)');
        END IF;
        e := bk_core.transfer(acc, num('CTL.M_TO_ID'), amt, t, d, 'BR');
      ELSIF k = 'OUT' THEN
        e := bk_core.transfer_out(acc, amt, name_in('CTL.M_IBAN'), t, d, 'BR');
      ELSIF k = 'INC' THEN
        e := bk_core.transfer_in(acc, amt, name_in('CTL.M_IBAN'), t, d, 'BR');
      ELSE
        fail('Κίνηση: DEP, WDR, TRF, OUT ή INC (λίστα)');
      END IF;
      forms_ddl('COMMIT');
      SELECT currency INTO k FROM bk_account WHERE id = acc;
      t := 'Εγγραφή #' || e || ' · ' || name_in('CTL.M_KIND_TEXT') || ' ' || money(amt, k);
      -- (to an account in another currency: what it got)
      IF name_in('CTL.M_KIND') = 'TRF' THEN
        id_ := num('CTL.M_TO_ID');
        SELECT max(l.credit), max(l.currency) INTO amt, r FROM bk_line l
        WHERE l.entry_id = e AND l.account_id = id_ AND l.op = 'TRI';
        IF r <> k THEN
          t := t || ' → ' || money(amt, r);
        END IF;
      END IF;
      copy(t, 'CTL.M_RESULT');
      copy('', 'CTL.M_AMOUNT');
      copy('', 'CTL.M_DESCR');
      move_refresh;

    -- BK_RULES: the one selected to the fields; a rule set from them (again with the same keys: replaced); removed
    ELSIF p_item = 'CTL.LOADRULE' THEN
      IF num('RULE.ID') IS NULL THEN
        fail('Πρώτα ένας κανόνας από τη λίστα');
      END IF;
      copy(name_in('RULE.PRODUCT'), 'CTL.R_PRODUCT');
      copy(name_in('RULE.ACCOUNT_ID'), 'CTL.R_ACC_ID');
      copy(name_in('RULE.IBAN'), 'CTL.R_ACC_TEXT');
      copy(name_in('RULE.OP'), 'CTL.R_OP');
      copy(name_in('RULE.CHANNEL'), 'CTL.R_CHANNEL');
      copy(name_in('RULE.ALLOWED'), 'CTL.R_ALLOWED');
      copy(name_in('RULE.MIN_AMOUNT'), 'CTL.R_MIN');
      copy(name_in('RULE.MAX_AMOUNT'), 'CTL.R_MAX');
      copy(name_in('RULE.DAY_AMOUNT'), 'CTL.R_DAYAMT');
      copy(name_in('RULE.DAY_COUNT'), 'CTL.R_DAYCNT');
      copy(name_in('RULE.MONTH_AMOUNT'), 'CTL.R_MONAMT');
      copy(name_in('RULE.MONTH_COUNT'), 'CTL.R_MONCNT');
      copy(name_in('RULE.FREE_MONTH'), 'CTL.R_FREE');
      copy(name_in('RULE.FEE'), 'CTL.R_FEE');
      copy(name_in('RULE.MIN_BALANCE'), 'CTL.R_MINBAL');
    ELSIF p_item = 'CTL.CLEARRULE' THEN
      copy('', 'CTL.R_PRODUCT');
      copy('', 'CTL.R_ACC_ID');
      copy('', 'CTL.R_ACC_TEXT');
      copy('', 'CTL.R_ALLOWED');
      copy('', 'CTL.R_MIN');
      copy('', 'CTL.R_MAX');
      copy('', 'CTL.R_DAYAMT');
      copy('', 'CTL.R_DAYCNT');
      copy('', 'CTL.R_MONAMT');
      copy('', 'CTL.R_MONCNT');
      copy('', 'CTL.R_FREE');
      copy('', 'CTL.R_FEE');
      copy('', 'CTL.R_MINBAL');
    ELSIF p_item = 'CTL.SETRULE' THEN
      IF name_in('CTL.R_ACC_TEXT') IS NULL THEN
        copy('', 'CTL.R_ACC_ID');            -- (the text cleared: the account too)
      END IF;
      id_ := bk_core.set_rule(p_product_code => name_in('CTL.R_PRODUCT'), p_account_id => num('CTL.R_ACC_ID'),
                              p_op => name_in('CTL.R_OP'), p_channel => name_in('CTL.R_CHANNEL'),
                              p_allowed => name_in('CTL.R_ALLOWED'),
                              p_min_amount => num('CTL.R_MIN'), p_max_amount => num('CTL.R_MAX'),
                              p_day_amount => num('CTL.R_DAYAMT'), p_day_count => num('CTL.R_DAYCNT'),
                              p_month_amount => num('CTL.R_MONAMT'), p_month_count => num('CTL.R_MONCNT'),
                              p_free_month => num('CTL.R_FREE'), p_fee => num('CTL.R_FEE'),
                              p_min_balance => num('CTL.R_MINBAL'));
      forms_ddl('COMMIT');
      requery;
      message('Ο κανόνας αποθηκεύτηκε (#' || id_ || ')');
    ELSIF p_item = 'CTL.REMOVERULE' THEN
      id_ := num('RULE.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένας κανόνας από τη λίστα');
      END IF;
      bk_core.remove_rule(id_);
      forms_ddl('COMMIT');
      requery;
      message('Ο κανόνας αφαιρέθηκε');

    -- BK_PRODUCTS: a new rate of the product on the screen, from the business day on
    ELSIF p_item = 'CTL.SETRATE' THEN
      id_ := num('PROD.ID');
      d := date_in('CTL.N_FROM');
      IF id_ IS NULL THEN
        fail('Πρώτα ένα προϊόν στην οθόνη');
      END IF;
      IF d < bk_core.open_day THEN
        fail('Ένα επιτόκιο αλλάζει από την εργάσιμη ημέρα και μετά: οι τόκοι των κλεισμένων ημερών δεν ξαναμετριούνται');
      END IF;
      bk_core.set_rate(id_, d, nvl(num('CTL.N_MIN'), 0), num('CTL.N_RATE'), nvl(name_in('CTL.N_CURRENCY'), 'EUR'));
      forms_ddl('COMMIT');
      g_master := NULL;
      go_block('RATE');
      execute_query;
      go_block(c_block);
      message('Το επιτόκιο αποθηκεύτηκε');
    ELSIF p_item = 'CTL.SETCURS' THEN
      id_ := num('PROD.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένα προϊόν στην οθόνη');
      END IF;
      bk_core.set_currencies(name_in('PROD.CODE'), name_in('CTL.P_CURS'));
      forms_ddl('COMMIT');
      copy('', 'CTL.P_CURS');
      requery;
      message('Τα νομίσματα του προϊόντος άλλαξαν');

    -- BK_CARDS: the card on the screen; a new card
    ELSIF p_item IN ('CTL.NEWPIN', 'CTL.BLOCKCARD', 'CTL.ACTIVATE', 'CTL.CANCELCARD') THEN
      id_ := num('CARD.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα μια κάρτα στην οθόνη');
      END IF;
      IF p_item = 'CTL.NEWPIN' THEN
        t := bk_auth.new_pin(id_);
        forms_ddl('COMMIT');
        copy(t || '   (' || name_in('CARD.PAN') || ')', 'CTL.C_PIN');
        t := 'Το PIN για τον κάτοχο: δεν φαίνεται ξανά';
      ELSE
        IF p_item = 'CTL.BLOCKCARD' THEN
          st := 'B';
        ELSIF p_item = 'CTL.ACTIVATE' THEN
          st := 'A';
        ELSE
          st := 'C';
        END IF;
        bk_core.set_card_status(id_, st);
        forms_ddl('COMMIT');
        copy('', 'CTL.C_PIN');
        t := 'Η κατάσταση της κάρτας: ' || st;
      END IF;
      show_only(id_);
      message(t);
    ELSIF p_item = 'CTL.NEWCARD' THEN
      acc := num('CTL.C_ACC_ID');
      IF acc IS NULL THEN
        fail('Πρώτα ένας λογαριασμός (λίστα)');
      END IF;
      id_ := bk_core.new_card(acc);
      t := bk_auth.new_pin(id_);
      forms_ddl('COMMIT');
      show_only(id_);
      SELECT pan INTO tok FROM bk_card WHERE id = id_;
      copy(t || '   (' || tok || ')', 'CTL.C_PIN');
      message('Νέα κάρτα ' || tok || ': το PIN για τον κάτοχο, δεν φαίνεται ξανά');

    -- BK_CCARDS: the credit card on the screen: its limit, a payment, a purchase, its statement printed
    ELSIF p_item IN ('CTL.SETLIMIT', 'CTL.PAYCC', 'CTL.PAYCASH', 'CTL.BUY', 'CTL.PRINTSTMT') THEN
      acc := num('CC.ID');
      IF acc IS NULL THEN
        fail('Πρώτα μια κάρτα στην οθόνη');
      END IF;
      IF p_item = 'CTL.PRINTSTMT' THEN
        IF name_in('CST.STMT_TEXT') IS NULL THEN
          fail('Πρώτα μια κίνηση από κάτω');
        END IF;
        open_report('BK_CC_STATEMENT', '&P_KIND=C&P_ACCOUNT=' || acc || '&P_FROM=' || name_in('CST.FROM_TEXT')
                                       || '&P_TO=' || name_in('CST.STMT_TEXT'));
      ELSE
        IF p_item = 'CTL.SETLIMIT' THEN
          bk_core.cc_set_limit(acc, num('CTL.L_LIMIT'));
          copy('', 'CTL.L_LIMIT');
          t := 'Το όριο της κάρτας άλλαξε';
        ELSIF p_item = 'CTL.PAYCC' THEN
          IF num('CTL.P_FROM_ID') IS NULL THEN
            fail('Πρώτα ο λογαριασμός της πληρωμής (λίστα)');
          END IF;
          e := bk_core.cc_pay(acc, num('CTL.P_FROM_ID'), num('CTL.P_AMOUNT'));
          copy('', 'CTL.P_AMOUNT');
          t := 'Πληρωμή: εγγραφή #' || e;
        ELSIF p_item = 'CTL.PAYCASH' THEN
          e := bk_core.deposit(acc, num('CTL.P_AMOUNT'), 'Πληρωμή κάρτας μετρητοίς');
          copy('', 'CTL.P_AMOUNT');
          t := 'Πληρωμή μετρητοίς: εγγραφή #' || e;
        ELSE
          SELECT max(id) INTO id_ FROM bk_card WHERE account_id = acc AND status = 'A';
          IF id_ IS NULL THEN
            fail('Ο λογαριασμός δεν έχει ενεργή κάρτα');
          END IF;
          e := bk_core.cc_purchase(id_, num('CTL.Q_AMOUNT'), name_in('CTL.Q_MERCHANT'), name_in('CTL.Q_CURRENCY'));
          copy('', 'CTL.Q_AMOUNT');
          t := 'Αγορά: εγγραφή #' || e;
        END IF;
        forms_ddl('COMMIT');
        show_only(acc);
        message(t);
      END IF;
    ELSIF p_item = 'CTL.NEWCC' THEN
      IF num('CTL.N_CUST_ID') IS NULL THEN
        fail('Πρώτα ο πελάτης (λίστα)');
      END IF;
      acc := bk_core.cc_open(name_in('CTL.N_PRODUCT'), num('CTL.N_CUST_ID'), num('CTL.N_LIMIT'), num('CTL.N_DAY'));
      id_ := bk_core.new_card(acc);
      t := bk_auth.new_pin(id_);
      forms_ddl('COMMIT');
      show_only(acc);
      SELECT pan INTO tok FROM bk_card WHERE id = id_;
      copy(t || '   (' || tok || ')', 'CTL.C_RESULT');
      message('Νέα πιστωτική κάρτα ' || tok || ': το PIN για τον κάτοχο, δεν φαίνεται ξανά');

    -- BK_FX: a rate of the currency on the screen; a currency new or changed, active or not; an amount converted
    ELSIF p_item IN ('CTL.SETFX', 'CTL.TOGGLECUR') THEN
      id_ := num('CURR.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένα νόμισμα στην οθόνη');
      END IF;
      k := name_in('CURR.CODE');
      IF p_item = 'CTL.SETFX' THEN
        bk_core.set_fx_rate(k, date_in('CTL.R_DAY'), num('CTL.R_MID'));
        copy('', 'CTL.R_MID');
        t := 'Η ισοτιμία του ' || k || ' αποθηκεύτηκε';
      ELSE
        SELECT CASE active WHEN 'Y' THEN 'N' ELSE 'Y' END, name, decimals, spread_pct INTO st, t, amt, e
        FROM bk_currency WHERE code = k;
        bk_core.set_currency(k, t, amt, e, st);
        t := 'Το ' || k || ': ' || CASE st WHEN 'Y' THEN 'ενεργό' ELSE 'ανενεργό' END;
      END IF;
      forms_ddl('COMMIT');
      show_only(id_);
      message(t);
    ELSIF p_item = 'CTL.SAVECUR' THEN
      k := upper(name_in('CTL.S_CODE'));
      SELECT nvl(max(active), 'Y') INTO st FROM bk_currency WHERE code = k;
      bk_core.set_currency(k, name_in('CTL.S_NAME'), num('CTL.S_DEC'), num('CTL.S_SPREAD'), st);
      forms_ddl('COMMIT');
      SELECT ora_hash(k) INTO id_ FROM dual;
      show_only(id_);
      message('Το νόμισμα ' || k || ' αποθηκεύτηκε');
    ELSIF p_item = 'CTL.CONVERT' THEN
      amt := num('CTL.X_AMOUNT');
      IF amt IS NULL OR name_in('CTL.X_FROM') IS NULL OR name_in('CTL.X_TO') IS NULL THEN
        fail('Ποσό, από νόμισμα, σε νόμισμα');
      END IF;
      copy(money(amt, name_in('CTL.X_FROM')) || ' = ' || money(bk_core.fx_convert(amt, name_in('CTL.X_FROM'), name_in('CTL.X_TO')), name_in('CTL.X_TO'))
           || '  ·  ο πελάτης παίρνει ' || money(bk_core.fx_convert(amt, name_in('CTL.X_FROM'), name_in('CTL.X_TO'), NULL, 'Y'), name_in('CTL.X_TO')),
           'CTL.X_RESULT');

    -- BK_ATMS: a cassette of the ATM on the screen; the notes of all of them
    ELSIF p_item = 'CTL.FILL' THEN
      id_ := num('ATMS.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένα ATM στην οθόνη');
      END IF;
      bk_core.atm_fill(name_in('ATMS.CODE'), num('CTL.F_NOTE'), num('CTL.F_PIECES'));
      forms_ddl('COMMIT');
      copy('', 'CTL.F_PIECES');
      show_only(id_);
      message('Η κασέτα των ' || name_in('CTL.F_NOTE') || ' € άλλαξε');
    ELSIF p_item = 'CTL.SETNOTES' THEN
      bk_core.set_atm_notes(name_in('CTL.S_NOTES'), num('CTL.S_MAX'));
      forms_ddl('COMMIT');
      requery;
      message('Τα χαρτονομίσματα των ATM αποθηκεύτηκαν');

    -- BK_USERS: a new one; the one selected: a password, the role, active, unlocked
    ELSIF p_item IN ('CTL.NEWUSER', 'CTL.SETPW') AND nvl(name_in('CTL.U_PW'), ' ') <> nvl(name_in('CTL.U_PW2'), ' ') THEN
      fail('Οι δύο κωδικοί δεν είναι ίδιοι');
    ELSIF p_item = 'CTL.NEWUSER' THEN
      id_ := bk_auth.create_user(name_in('CTL.U_NAME'), name_in('CTL.U_FULL'), name_in('CTL.U_ROLE'), name_in('CTL.U_PW'));
      forms_ddl('COMMIT');
      copy('', 'CTL.U_PW');
      copy('', 'CTL.U_PW2');
      copy('', 'CTL.U_NAME');
      copy('', 'CTL.U_FULL');
      requery;
      message('Ο χρήστης καταχωρίστηκε');
    ELSIF p_item IN ('CTL.SETPW', 'CTL.SETROLE', 'CTL.TOGGLEACT', 'CTL.UNLOCK') THEN
      id_ := num('USR.ID');
      IF id_ IS NULL THEN
        fail('Πρώτα ένας χρήστης από τη λίστα');
      END IF;
      IF p_item = 'CTL.SETPW' THEN
        bk_auth.set_password(id_, name_in('CTL.U_PW'));
        copy('', 'CTL.U_PW');
        copy('', 'CTL.U_PW2');
        t := 'Ο κωδικός άλλαξε: οι συνδέσεις του έκλεισαν';
      ELSIF p_item = 'CTL.SETROLE' THEN
        bk_auth.set_role(id_, name_in('CTL.U_ROLE'));
        t := 'Ο ρόλος άλλαξε';
      ELSIF p_item = 'CTL.TOGGLEACT' THEN
        SELECT active INTO st FROM bk_user WHERE id = id_;
        IF st = 'Y' THEN
          bk_auth.set_active(id_, 'N');
          t := 'Ο χρήστης απενεργοποιήθηκε';
        ELSE
          bk_auth.set_active(id_, 'Y');
          t := 'Ο χρήστης ενεργοποιήθηκε';
        END IF;
      ELSE
        bk_auth.unlock(id_);
        t := 'Ο χρήστης ξεκλειδώθηκε';
      END IF;
      forms_ddl('COMMIT');
      requery;
      message(t);

    -- BK_DAY
    ELSIF p_item = 'CTL.REFRESH' THEN
      day_refresh;
    ELSIF p_item = 'CTL.CLOSEDAY' THEN
      d := bk_core.open_day;
      bk_core.close_day(d);
      forms_ddl('COMMIT');
      day_refresh;
      message('Έκλεισε η ' || to_char(d, 'DD/MM/YYYY'));
    END IF;
  EXCEPTION
    WHEN form_trigger_failure THEN
      RAISE;
    WHEN OTHERS THEN
      -- (an error of BK_CORE: nothing of the button stays)
      forms_ddl('ROLLBACK');
      message(friendly(sqlerrm));
      RAISE form_trigger_failure;
  END;

  PROCEDURE press(p_item VARCHAR2) IS
    v VARCHAR2(40);
  BEGIN
    IF p_item = 'CTL.FIND' THEN
      copy('', 'CTL.FIND_ID');
      IF show_lov('LOV_FIND') THEN
        v := name_in('CTL.FIND_ID');
        IF v IS NOT NULL THEN
          show_only(to_number(v));
        END IF;
      END IF;
    ELSIF p_item = 'CTL.ALL' THEN
      copy('', 'CTL.FIND_TEXT');
      go_block(c_block);
      set_block_property(c_block, DEFAULT_WHERE, c_where);
      g_master := NULL;
      execute_query;
    ELSE
      action(p_item);
    END IF;
  END;

  -- the toolbar: the keys of the Forms on the block of the cursor (the buttons do not take it)
  PROCEDURE tool(p_item VARCHAR2) IS
  BEGIN
    IF p_item = 'TB.T_SAVE' THEN
      do_key('COMMIT_FORM');
    ELSIF p_item = 'TB.T_ENTERQ' THEN
      do_key('ENTER_QUERY');
    ELSIF p_item = 'TB.T_EXECQ' THEN
      do_key('EXECUTE_QUERY');
    ELSIF p_item = 'TB.T_NEW' THEN
      do_key('CREATE_RECORD');
    ELSIF p_item = 'TB.T_DEL' THEN
      do_key('DELETE_RECORD');
    ELSIF p_item = 'TB.T_LOV' THEN
      do_key('LIST_VALUES');
    ELSIF p_item = 'TB.T_PREV' THEN
      do_key('PREVIOUS_RECORD');
    ELSIF p_item = 'TB.T_NEXT' THEN
      do_key('NEXT_RECORD');
    ELSIF p_item = 'TB.T_MAIN' THEN
      new_form('BK_MAIN');
    ELSIF p_item = 'TB.T_EXIT' THEN
      do_key('EXIT_FORM');
    END IF;
  END;

  -- a double click on an item with a list: the list (F9 is not the key of the list on the web)
  PROCEDURE dblclick(p_item VARCHAR2) IS
  BEGIN
    IF p_item IS NOT NULL AND get_item_property(p_item, LOV_NAME) IS NOT NULL THEN
      do_key('LIST_VALUES');
    END IF;
  END;

  PROCEDURE validate(p_item VARCHAR2) IS
    v VARCHAR2(400) := name_in(p_item);
  BEGIN
    IF v IS NULL THEN
      RETURN;
    END IF;
    IF p_item = 'CUST.AFM' THEN
      IF bk_core.afm_ok(v) = 'N' THEN
        fail('Το ΑΦΜ δεν είναι σωστό: 9 ψηφία, με σωστό ψηφίο ελέγχου');
      END IF;
    ELSIF p_item = 'CUST.EMAIL' THEN
      IF v NOT LIKE '_%@_%._%' THEN
        fail('Το email δεν είναι σωστό');
      END IF;
    END IF;
  END;

  -- the lines of a statement (ST, LAST): the words of their kind, the balance after each (its account: the
  -- lines up to it, in the order of the entries)
  PROCEDURE post_query(p_block VARCHAR2) IS
    acc NUMBER;
    en NUMBER;
    ln NUMBER;
    s NUMBER;
    k VARCHAR2(3);
    t VARCHAR2(60);
  BEGIN
    IF p_block IN ('ST', 'LAST') THEN
      IF p_block = 'ST' THEN
        acc := num('ACC.ID');
      ELSE
        acc := num('CTL.M_ACC_ID');
      END IF;
      en := num(p_block || '.ENTRY_ID');
      ln := num(p_block || '.LINE_ID');
      k := name_in(p_block || '.KIND');
      SELECT nvl(sum(credit - debit), 0) INTO s FROM bk_line
      WHERE account_id = acc AND (entry_id < en OR (entry_id = en AND id <= ln));
      copy(to_char(s), p_block || '.RUN_BALANCE');
      -- (in another currency: the amount it was in, at its rate)
      IF name_in(p_block || '.ORIG_CURRENCY') IS NOT NULL AND nvl(name_in(p_block || '.OP'), '-') <> 'FEE' THEN
        copy(money(num(p_block || '.ORIG_AMOUNT'), name_in(p_block || '.ORIG_CURRENCY')) || ' × '
             || rtrim(rtrim(to_char(num(p_block || '.FX_RATE'), 'FM999G990D999999', 'NLS_NUMERIC_CHARACTERS='',.'''), '0'), ','),
             p_block || '.ORIG_TEXT');
      END IF;
      IF name_in(p_block || '.OP') = 'FEE' THEN
        t := 'Προμήθεια';
      ELSIF k = 'DEP' THEN
        t := 'Κατάθεση';
      ELSIF k = 'WDR' THEN
        t := 'Ανάληψη';
      ELSIF k = 'TRF' THEN
        t := 'Μεταφορά';
      ELSIF k = 'OUT' THEN
        t := 'Σε άλλη τράπεζα';
      ELSIF k = 'INC' THEN
        t := 'Από άλλη τράπεζα';
      ELSIF k = 'INT' THEN
        t := 'Τόκοι';
      ELSIF k = 'REV' THEN
        t := 'Αντιλογισμός';
      ELSIF k = 'PUR' THEN
        t := 'Αγορά με κάρτα';
      ELSE
        t := k;
      END IF;
      copy(t, p_block || '.KIND_TEXT');
      -- (what this procedure put in the record is not a change of the user)
      set_record_property(to_number(name_in('SYSTEM.TRIGGER_RECORD')), p_block, STATUS, QUERY_STATUS);
    END IF;
  END;

  -- the messages of the database in words: BK_CORE as it is (BK-1xx: its line), a constraint by its name
  FUNCTION friendly(p_dbtext VARCHAR2) RETURN VARCHAR2 IS
    p PLS_INTEGER := instr(p_dbtext, 'BK-1');
  BEGIN
    IF p > 0 THEN
      RETURN rtrim(substr(p_dbtext, p, instr(p_dbtext || chr(10), chr(10), p) - p));
    END IF;
    IF instr(p_dbtext, 'BK_CUSTOMER_AFM_UK') > 0 THEN
      RETURN 'Υπάρχει ήδη πελάτης με αυτό το ΑΦΜ';
    ELSIF instr(p_dbtext, 'BK_CUSTOMER_AFM_CK') > 0 THEN
      RETURN 'Το ΑΦΜ θέλει 9 ψηφία';
    END IF;
    RETURN p_dbtext;
  END;

  PROCEDURE on_error(p_code NUMBER, p_type VARCHAR2, p_text VARCHAR2, p_dbtext VARCHAR2) IS
  BEGIN
    -- FRM-40508/40509/40510: insert, update, delete failed; the reason is in DBMS_ERROR_TEXT
    IF p_code IN (40508, 40509, 40510) AND p_dbtext IS NOT NULL THEN
      message(friendly(p_dbtext));
    ELSE
      message(p_type || '-' || to_char(p_code) || ': ' || p_text);
    END IF;
  END;

  -- FRM-40350 (Query caused no records to be retrieved) not shown: a list of nothing is no news
  PROCEDURE on_message(p_code NUMBER, p_type VARCHAR2, p_text VARCHAR2) IS
  BEGIN
    IF p_code = 40350 THEN
      RETURN;
    END IF;
    message(p_type || '-' || to_char(p_code) || ': ' || p_text);
  END;
END;
