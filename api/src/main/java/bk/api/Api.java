package bk.api;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The endpoints (JSON). Dates in and out as YYYY-MM-DD, money as numbers. A login first (POST /api/auth/login):
 * then "Authorization: Bearer <token>" on every call but /api/health. Everything that writes goes through
 * BK_CORE (its errors BK-1xx as 400, with their words); each entry carries the user that made it
 * (BK_ENTRY.CREATED_BY). The roles: TELLER (the counter), MANAGER (and what is marked M), ADMIN (and the users).
 *
 * <pre>
 *   POST /api/auth/login {username, password}   its token (12 hours)            (anyone)
 *   POST /api/auth/logout   GET /api/auth/me     the end of the session; who it is
 *   GET  /api/health                             the service and its database    (anyone)
 *   GET  /api/day                                the business day, the last one closed, BK_CHECK, the entries of the day
 *   POST /api/day/close                          the business day closed: its interest (M)
 *   GET  /api/check                              the rows of BK_CHECK (none: all is right)
 *   GET  /api/ai/alerts?status=&limit=            the suspicious movements (db/BK_AI.sql: N new, C not a fraud, F a fraud)
 *   GET  /api/ai/model                           the model: ready (Y/N), in a line, the threshold
 *   POST /api/ai/scan {day}                      the movements of a day (none: the business day) scored: the new alerts (M)
 *   POST /api/ai/train                           the model again from the days closed (A)
 *   POST /api/ai/alerts/{id} {status, note, block}   C not a fraud, F a fraud (block N: its account not blocked) (M)
 *   GET  /api/customers?q=&limit=&offset=        the customers (name, AFM, code, phone)
 *   GET  /api/customers/{id}                     one, with its accounts
 *   POST /api/customers {name, afm, phone, email, address, birth_date, id_card}   a new one
 *   POST /api/customers/{id} {... active}        its data corrected
 *   GET  /api/products                           the products, their currencies, their rates now (by tier; in the
 *                                                base currency, and by currency) and their history
 *   POST /api/products/{code}/rates {valid_from, min_balance, rate, currency}   a rate from a day on (M)
 *   POST /api/products/{code}/currencies {currencies: "EUR,USD"}   the currencies it opens in (M)
 *   GET  /api/branches                           the branches: accounts, users, ATMs, cash (and by channel)
 *   POST /api/branches {code, name, city, address, active}   a branch new or changed (M)
 *   POST /api/accounts/{id}/branch {branch}      an account to another branch: its IBAN as it was (M)
 *   POST /api/atms/{code}/branch {branch}        an ATM to a branch (M)
 *   GET  /api/loans?q=&status=&branch=          the loans (A active, C paid off; of a branch)
 *   GET  /api/loans/quote?product=&amount=&months=   the installment of a loan before it is opened, the rate now
 *   GET  /api/loans/{id}                         one: its schedule, what pays it off today
 *   POST /api/loans {product, pay_account, amount, months, pay_day}   a new one, paid to that account (its IBAN or
 *                                                number; the customer: its primary holder), its installments from it (M)
 *   POST /api/loans/{id}/prepay {amount, mode T|P}   a prepayment (M)    POST /api/loans/{id}/payoff   paid off (M)
 *   GET  /api/fx                                 the currencies (the base one first), their last rate and its day
 *   GET  /api/fx/convert?amount=&from=&to=       an amount converted: at the mid rate, and as the customer gets it
 *   GET  /api/fx/{code}?days=                    its rates, the newest first
 *   POST /api/fx {code, name, decimals, spread_pct, active}   a currency new or changed (M)
 *   POST /api/fx/{code}/rates {day, mid}         its rate from a day on: 1 of the base currency = mid (M)
 *   GET  /api/accounts?q=&status=&branch=&limit=&offset= the accounts (IBAN, the name or AFM of a holder; a branch)
 *   GET  /api/accounts/{id}                      one: its product, holders, balance, what is available
 *   POST /api/accounts {product, customer_id, od_limit, name, currency, branch}   a new one (in a currency of its
 *                                                product; in a branch, else that of the user)
 *   POST /api/accounts/{id}/holders {customer_id}   POST /api/accounts/{id}/holders/{customer}/remove
 *   POST /api/accounts/{id}/status {status O|B}  (M)   .../od-limit {od_limit} (M)   .../close (M)
 *   GET  /api/accounts/{id}/statement?from=&to=  its moves, the balance before and after
 *   GET  /api/accounts/{id}/interest?from=&to=   the interest by stretches (accrued first, up to the last day
 *                                                closed) and the capitalizations
 *   GET  /api/accounts/{id}/limits               BK_LIMITS: what each move may do now, by channel, and the rules
 *   POST /api/movements {kind DEP|WDR|TRF|OUT|INC, account_id, to_account, iban, amount, descr, value_date, channel}
 *   GET  /api/entries/{id}                       an entry and its lines
 *   POST /api/entries/{id}/reverse {descr}       its reversal (M)
 *   GET  /api/rules?product=&account_id=         the rules of the moves
 *   POST /api/rules {product, account_id, op, channel, allowed, min_amount, ...}   set (M)
 *   POST /api/rules/{id}/remove                  (M)
 *   GET  /api/accounts/{id}/cards   POST /api/accounts/{id}/cards {customer_id}   its cards; a new one (its PIN
 *                                                back, once: for the customer)
 *   POST /api/cards/{id}/pin                     a new PIN (back, once), unlocked
 *   POST /api/cards/pins {pin, all}              a PIN to every card without one (all: to every card): the same
 *                                                (pin) or a new one each; the cards and their PIN back, once (M)
 *   POST /api/cards/{id}/status {status A|B|C}   B blocked (anyone); A again, C cancelled (M)
 *   GET  /api/atms                               the ATMs, their cassettes, the notes they give, the most notes
 *   POST /api/atms/{code}/fill {note, pieces}    a cassette filled (+) or emptied (-) (M)
 *   POST /api/atms/notes {notes: "20,50", max_notes}   the notes the ATMs give; the most of one withdrawal (M)
 *   GET  /api/users   POST /api/users {username, full_name, role, password}
 *   POST /api/users/{id} {full_name, role, active, password, unlock}   (ADMIN)
 * </pre>
 */
final class Api {
    private static final int MAX_LIMIT = 500;
    private static final String AI_FROM = "ΆΈΉΊΌΎΏΪΫ";        // (a search without the accents)
    private static final String AI_TO = "ΑΕΗΙΟΥΩΙΥ";
    private final Db db;

    Api(Db db) {
        this.db = db;
    }

    void register(HttpServer server) {
        server.createContext("/api/", this::handle);
    }

    private void handle(HttpExchange ex) throws IOException {
        try {
            String raw = ex.getRequestURI().getRawPath();
            String low = raw.toLowerCase();
            if (low.contains("..") || low.contains("%2e") || low.contains("%2f") || low.contains("//")) {
                throw new Http.Fail(400, "bad_path", "bad path");
            }
            String method = ex.getRequestMethod();
            if (!"GET".equals(method) && !"POST".equals(method)) {
                ex.getResponseHeaders().set("Allow", "GET, POST");
                throw new Http.Fail(405, "method_not_allowed", "GET or POST");
            }
            String[] p = raw.substring("/api/".length()).split("/");
            Map<String, String> q = Http.query(ex);
            Map<String, Object> in = "POST".equals(method) ? Http.body(ex) : Map.of();
            Object body;
            try (Connection c = db.connection()) {
                try {
                    if ("POST".equals(method) && is(p, "auth", "login")) {
                        body = Auth.login(c, Http.text(in, "username", true), Http.text(in, "password", true),
                                ex.getRemoteAddress().getAddress().getHostAddress());
                    } else if ("GET".equals(method) && is(p, "health")) {
                        body = Map.of("status", "ok", "open_day", day(c).toString());
                    } else {
                        String token = bearer(ex);
                        Auth.User u = Auth.check(c, token);
                        if (u == null) {
                            throw new Http.Fail(401, "no_session", "Η σύνδεση έληξε: ξανά είσοδος");
                        }
                        Db.exec(c, "begin dbms_session.set_identifier(?); end;", u.username());
                        try {
                            body = route(c, u, token, method, p, q, in);
                            c.commit();
                        } finally {
                            Db.exec(c, "begin dbms_session.clear_identifier; end;");
                        }
                    }
                } catch (SQLException e) {
                    c.rollback();
                    throw Http.fromSql(e);
                } catch (RuntimeException e) {
                    c.rollback();
                    throw e;
                }
            }
            Http.send(ex, 200, body);
        } catch (Http.Fail f) {
            Http.send(ex, f.status, Http.error(f.code, f.getMessage()));
        } catch (SQLException e) {
            Http.Fail f = Http.fromSql(e);
            Http.send(ex, f.status, Http.error(f.code, f.getMessage()));
        } catch (Exception e) {
            System.err.println("== bk-api: " + e);
            Http.send(ex, 500, Http.error("error", "Λάθος της υπηρεσίας"));
        } finally {
            ex.close();
        }
    }

    private static boolean is(String[] p, String... names) {
        if (p.length != names.length) {
            return false;
        }
        for (int i = 0; i < names.length; i++) {
            if (!"*".equals(names[i]) && !names[i].equals(p[i])) {
                return false;
            }
        }
        return true;
    }

    private static String bearer(HttpExchange ex) {
        String h = ex.getRequestHeaders().getFirst("Authorization");
        return h != null && h.startsWith("Bearer ") ? h.substring(7).trim() : null;
    }

    private static void need(Auth.User u, String role) {
        if (!u.is(role)) {
            throw new Http.Fail(403, "forbidden", "Χρειάζεται ρόλος " + role);
        }
    }

    private Object route(Connection c, Auth.User u, String token, String m, String[] p, Map<String, String> q,
                         Map<String, Object> in) throws SQLException {
        boolean get = "GET".equals(m);
        String what = p[0];
        switch (what) {
            case "auth" -> {
                if (!get && is(p, "auth", "logout")) {
                    Auth.logout(c, token);
                    return Map.of("ok", true);
                }
                if (get && is(p, "auth", "me")) {
                    return me(u);
                }
            }
            case "day" -> {
                if (get && p.length == 1) {
                    return dayInfo(c);
                }
                if (!get && is(p, "day", "close")) {
                    need(u, "MANAGER");
                    LocalDate d = day(c);
                    Db.exec(c, "begin bk_core.close_day(p_day => ?); end;", d);
                    Map<String, Object> r = new LinkedHashMap<>(dayInfo(c));
                    r.put("closed", d.toString());
                    return r;
                }
            }
            case "check" -> {
                if (get && p.length == 1) {
                    return Db.rows(c, "select what, ref, detail from bk_check order by what, ref");
                }
            }
            case "customers" -> {
                return customers(c, get, p, q, in);
            }
            case "products" -> {
                return products(c, u, get, p, in);
            }
            case "fx" -> {
                return fx(c, u, get, p, q, in);
            }
            case "loans" -> {
                return loans(c, u, get, p, q, in);
            }
            case "ai" -> {
                need(u, "MANAGER");
                return ai(c, u, get, p, q, in);
            }
            case "branches" -> {
                if (get && p.length == 1) {
                    return branches(c);
                }
                if (!get && p.length == 1) {
                    need(u, "MANAGER");
                    String active = Http.text(in, "active", false);
                    Db.exec(c, "begin bk_core.set_branch(?, ?, ?, ?, ?); end;", Http.text(in, "code", true),
                            Http.text(in, "name", true), Http.text(in, "city", false), Http.text(in, "address", false),
                            active == null ? "Y" : active.toUpperCase());
                    return branches(c);
                }
            }
            case "accounts" -> {
                return accounts(c, u, get, p, q, in);
            }
            case "movements" -> {
                if (!get && p.length == 1) {
                    return movement(c, in);
                }
            }
            case "entries" -> {
                if (get && p.length == 2) {
                    return entry(c, Http.id(p[1]));
                }
                if (!get && is(p, "entries", "*", "reverse")) {
                    need(u, "MANAGER");
                    long e = Db.fn(c, "bk_core.reverse(p_entry_id => ?, p_descr => ?)", Http.id(p[1]),
                            Http.text(in, "descr", false));
                    return entry(c, e);
                }
            }
            case "rules" -> {
                return rules(c, u, get, p, q, in);
            }
            case "cards" -> {
                return cards(c, u, get, p, in);
            }
            case "atms" -> {
                if (get && p.length == 1) {
                    return atms(c);
                }
                if (!get && is(p, "atms", "notes")) {
                    need(u, "MANAGER");
                    Db.exec(c, "begin bk_core.set_atm_notes(?, ?); end;", Http.text(in, "notes", true),
                            Http.decimal(in, "max_notes", null));
                    return atms(c);
                }
                if (!get && is(p, "atms", "*", "branch")) {
                    need(u, "MANAGER");
                    Db.exec(c, "begin bk_core.set_atm_branch(?, ?); end;", p[1], Http.text(in, "branch", true));
                    return atms(c);
                }
                if (!get && is(p, "atms", "*", "fill")) {
                    need(u, "MANAGER");
                    Db.exec(c, "begin bk_core.atm_fill(?, ?, ?); end;", p[1], Http.decimal(in, "note", null),
                            Http.decimal(in, "pieces", null));
                    return atms(c);
                }
            }
            case "users" -> {
                need(u, "ADMIN");
                return users(c, u, get, p, in);
            }
            default -> {
                // below
            }
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει: /api/" + String.join("/", p));
    }

    private static Map<String, Object> atms(Connection c) throws SQLException {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("notes", Atm.notes(c));
        r.put("max_notes", Atm.maxNotes(c));
        List<Map<String, Object>> rows = Db.rows(c, "select id, code, name, address, cash, deposits, active, branch_code "
                + "from bk_atm order by code");
        for (Map<String, Object> m : rows) {
            m.put("cassettes", Db.rows(c, "select note, pieces, note * pieces amount from bk_atm_note where atm_id = ? "
                    + "order by note desc", m.remove("id")));
        }
        r.put("atms", rows);
        return r;
    }

    private static final String ALERT_COLS = "select id, status, score, reasons, created_at, reviewed_by, reviewed_at, note, "
            + "entry_id, account_id, book_date, at_time, kind, channel, descr, amount, currency, amount_eur, direction, "
            + "orig_amount, orig_currency, iban, holder, account_status, branch_code from bk_ai_alert_v";

    private static Map<String, Object> aiModel(Connection c) throws SQLException {
        return Db.row(c, "select bk_ai.ready ready, bk_ai.model_info info, bk_ai.threshold threshold, "
                + "(select count(*) from bk_ai_alert where status = 'N') open from dual");
    }

    private Object ai(Connection c, Auth.User u, boolean get, String[] p, Map<String, String> q, Map<String, Object> in)
            throws SQLException {
        if (get && is(p, "ai", "alerts")) {
            String st = q.getOrDefault("status", "").trim().toUpperCase();
            Object vs = st.isEmpty() ? null : st;
            return Db.rows(c, ALERT_COLS + " where (? is null or status = ?) "
                    + "order by case status when 'N' then 0 else 1 end, score desc, id fetch first ? rows only", vs, vs, limit(q));
        }
        if (get && is(p, "ai", "model")) {
            return aiModel(c);
        }
        if (!get && is(p, "ai", "scan")) {
            LocalDate d = Http.dateValue(in, "day");
            long n = Db.fn(c, "bk_ai.scan(p_day => ?)", d);
            Map<String, Object> r = new LinkedHashMap<>(aiModel(c));
            r.put("new_alerts", n);
            return r;
        }
        if (!get && is(p, "ai", "train")) {
            need(u, "ADMIN");
            long n = Db.fn(c, "bk_ai.train");
            Map<String, Object> r = new LinkedHashMap<>(aiModel(c));
            r.put("rows", n);
            return r;
        }
        if (!get && is(p, "ai", "alerts", "*")) {
            long id = Http.id(p[2]);
            String block = Http.text(in, "block", false);
            Db.exec(c, "begin bk_ai.review(?, ?, ?, ?); end;", id, Http.text(in, "status", true).toUpperCase(),
                    Http.text(in, "note", false), block == null ? "Y" : block.toUpperCase());
            return Db.row(c, ALERT_COLS + " where id = ?", id);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    private static List<Map<String, Object>> branches(Connection c) throws SQLException {
        List<Map<String, Object>> rows = Db.rows(c, "select code, name, city, address, active, accounts, users, atms, cash "
                + "from bk_branch_v order by code");
        for (Map<String, Object> b : rows) {
            b.put("by_channel", Db.rows(c, "select channel, cash, cash_today, entries from bk_branch_cash "
                    + "where branch_code = ? order by channel", b.get("code")));
        }
        return rows;
    }

    private static Map<String, Object> me(Auth.User u) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("id", u.id());
        r.put("username", u.username());
        r.put("full_name", u.fullName());
        r.put("role", u.role());
        return r;
    }

    // ---------------------------------------------------------------------------------------------
    static LocalDate day(Connection c) throws SQLException {
        return LocalDate.parse((String) Db.row(c, "select bk_core.open_day d from dual").get("d"));
    }

    private static Map<String, Object> dayInfo(Connection c) throws SQLException {
        return Db.row(c, "select to_char(bk_core.open_day, 'YYYY-MM-DD') open_day, "
                + "(select to_char(max(day), 'YYYY-MM-DD') from bk_day) last_closed, "
                + "(select count(*) from bk_check) check_rows, "
                + "(select count(*) from bk_entry where book_date = bk_core.open_day) entries, "
                + "(select count(*) from bk_account where status <> 'C') accounts, "
                + "(select count(*) from bk_customer where active = 'Y') customers from dual");
    }

    private static int limit(Map<String, String> q) {
        return Http.number(q, "limit", 50, 1, MAX_LIMIT);
    }

    private static String ai(String column) {
        return "translate(upper(" + column + "), '" + AI_FROM + "', '" + AI_TO + "')";
    }

    // ---------------------------------------------------------------------------------------------
    private Object customers(Connection c, boolean get, String[] p, Map<String, String> q, Map<String, Object> in)
            throws SQLException {
        if (get && p.length == 1) {
            String s = q.getOrDefault("q", "").trim();
            String where = " where (? is null or " + ai("c.name") + " like '%' || " + ai("?") + " || '%' "
                    + "or c.afm = ? or c.code = upper(?) or c.phone like ? || '%')";
            Object v = s.isEmpty() ? null : s;
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("total", Db.row(c, "select count(*) n from bk_customer c" + where, v, v, v, v, v).get("n"));
            r.put("rows", Db.rows(c, "select c.id, c.code, c.name, c.afm, c.phone, c.email, c.active, "
                    + "(select count(*) from bk_holder h join bk_account a on a.id = h.account_id "
                    + "where h.customer_id = c.id and a.status <> 'C') accounts from bk_customer c" + where
                    + " order by c.name, c.id offset ? rows fetch next ? rows only",
                    v, v, v, v, v, Http.number(q, "offset", 0, 0, Integer.MAX_VALUE), limit(q)));
            return r;
        }
        if (get && p.length == 2) {
            return customer(c, Http.id(p[1]));
        }
        if (!get && p.length == 1) {
            long id = Db.fn(c, "bk_core.new_customer(p_name => ?, p_afm => ?, p_phone => ?, p_email => ?, "
                            + "p_address => ?, p_birth_date => ?, p_id_card => ?)",
                    Http.text(in, "name", false), Http.text(in, "afm", false), Http.text(in, "phone", false),
                    Http.text(in, "email", false), Http.text(in, "address", false), Http.dateValue(in, "birth_date"),
                    Http.text(in, "id_card", false));
            return customer(c, id);
        }
        if (!get && p.length == 2) {
            long id = Http.id(p[1]);
            Map<String, Object> old = customer(c, id);
            Db.exec(c, "begin bk_core.update_customer(p_customer_id => ?, p_name => ?, p_afm => ?, p_phone => ?, "
                            + "p_email => ?, p_address => ?, p_birth_date => ?, p_id_card => ?, p_active => ?); end;",
                    id, keep(in, old, "name"), keep(in, old, "afm"), keep(in, old, "phone"), keep(in, old, "email"),
                    keep(in, old, "address"), in.containsKey("birth_date") ? Http.dateValue(in, "birth_date")
                            : old.get("birth_date") == null ? null : LocalDate.parse((String) old.get("birth_date")),
                    keep(in, old, "id_card"), keep(in, old, "active"));
            return customer(c, id);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    /** a value of a body, or the old one when it is not in it */
    private static String keep(Map<String, Object> in, Map<String, Object> old, String name) {
        if (in.containsKey(name)) {
            return Http.text(in, name, false);
        }
        Object v = old.get(name);
        return v == null ? null : String.valueOf(v);
    }

    private static Map<String, Object> customer(Connection c, long id) throws SQLException {
        Map<String, Object> r = Db.row(c, "select id, code, name, afm, id_card, birth_date, phone, email, address, active, "
                + "created_at from bk_customer where id = ?", id);
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει πελάτης " + id);
        }
        r.put("accounts", Db.rows(c, "select a.id, a.iban, p.code product, p.name product_name, a.name, a.status, "
                + "a.currency, a.branch_code, a.balance, a.od_limit, h.role from bk_holder h join bk_account a on a.id = h.account_id "
                + "join bk_product p on p.id = a.product_id where h.customer_id = ? order by a.status desc, a.id", id));
        return r;
    }

    // ---------------------------------------------------------------------------------------------
    private Object products(Connection c, Auth.User u, boolean get, String[] p, Map<String, Object> in)
            throws SQLException {
        if (get && p.length == 1) {
            List<Map<String, Object>> rows = Db.rows(c, "select id, code, name, kind, day_basis, cap_every, tax_rate, "
                    + "od_rate, active, currencies, (select count(*) from bk_account a where a.product_id = p.id and a.status <> 'C') "
                    + "accounts from bk_product p order by id");
            for (Map<String, Object> r : rows) {
                Object id = r.get("id");
                r.put("rates_now", Db.rows(c, "select min_balance, bk_core.rate_of(?, bk_core.open_day, min_balance) rate "
                        + "from (select distinct min_balance from bk_rate where product_id = ? "
                        + "and currency = bk_core.base_currency "         // (the other currencies: the next step)
                        + "and valid_from <= bk_core.open_day) order by min_balance", id, id));
                r.put("rates", Db.rows(c, "select currency, valid_from, min_balance, rate from bk_rate where product_id = ? "
                        + "order by case when currency = bk_core.base_currency then 0 else 1 end, currency, valid_from desc, "
                        + "min_balance", id));
                // the rates now in each of its currencies
                Map<String, Object> by = new LinkedHashMap<>();
                for (String cur : String.valueOf(r.get("currencies")).split(",")) {
                    by.put(cur, Db.rows(c, "select min_balance, bk_core.rate_of(?, bk_core.open_day, min_balance, ?) rate "
                            + "from (select distinct min_balance from bk_rate where product_id = ? and currency = ? "
                            + "and valid_from <= bk_core.open_day) order by min_balance", id, cur, id, cur));
                }
                r.put("rates_by_currency", by);
            }
            return rows;
        }
        if (!get && is(p, "products", "*", "rates")) {
            need(u, "MANAGER");
            Map<String, Object> pr = Db.row(c, "select id from bk_product where code = upper(?)", p[1]);
            if (pr == null) {
                throw new Http.Fail(404, "not_found", "Δεν υπάρχει προϊόν " + p[1]);
            }
            LocalDate from = Http.dateValue(in, "valid_from");
            if (from == null) {
                from = day(c);
            }
            if (from.isBefore(day(c))) {
                throw new Http.Fail(400, "bad_date", "Ένα επιτόκιο αλλάζει από την εργάσιμη ημέρα (" + day(c)
                        + ") και μετά: οι τόκοι των κλεισμένων ημερών δεν ξαναμετριούνται");
            }
            BigDecimal rate = Http.decimal(in, "rate", null);
            if (rate == null) {
                throw new Http.Fail(400, "missing", "rate");
            }
            String cur = Http.text(in, "currency", false);
            Db.exec(c, "begin bk_core.set_rate(?, ?, ?, ?, ?); end;", pr.get("id"), from,
                    Http.decimal(in, "min_balance", BigDecimal.ZERO), rate, cur == null ? "EUR" : cur.toUpperCase());
            return products(c, u, true, new String[]{"products"}, Map.of());
        }
        if (!get && is(p, "products", "*", "currencies")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.set_currencies(?, ?); end;", p[1], Http.text(in, "currencies", true));
            return products(c, u, true, new String[]{"products"}, Map.of());
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    // ---------------------------------------------------------------------------------------------
    private static final String LOAN_COLS = "select id, iban, product, product_name, currency, status, principal, months, "
            + "start_date, pay_day, rate, rate_type, owed, pay_account_id, pay_iban, principal_after, next_due, late, holder, "
            + "branch_code from bk_loan_v";

    private Object loans(Connection c, Auth.User u, boolean get, String[] p, Map<String, String> q, Map<String, Object> in)
            throws SQLException {
        if (get && p.length == 1) {
            String s = q.getOrDefault("q", "").trim();
            String st = q.getOrDefault("status", "").trim().toUpperCase();
            String br = q.getOrDefault("branch", "").trim();
            Object v = s.isEmpty() ? null : s;
            Object vs = st.isEmpty() ? null : st;
            Object vb = br.isEmpty() ? null : br;
            return Db.rows(c, LOAN_COLS + " where (? is null or iban like '%' || replace(upper(?), ' ') || '%' or "
                    + ai("holder") + " like '%' || " + ai("?") + " || '%') and (? is null or status = ?) "
                    + "and (? is null or branch_code = ?) order by id fetch first 500 rows only", v, v, v, vs, vs, vb, vb);
        }
        if (get && is(p, "loans", "quote")) {
            String prod = q.get("product");
            if (prod == null || q.get("amount") == null || q.get("months") == null) {
                throw new Http.Fail(400, "missing", "product, amount, months");
            }
            BigDecimal amount;
            int months;
            try {
                amount = new BigDecimal(q.get("amount").replace(',', '.'));
                months = Integer.parseInt(q.get("months").trim());
            } catch (NumberFormatException e) {
                throw new Http.Fail(400, "bad_number", "amount, months: numbers");
            }
            return Db.row(c, "select bk_core.ln_quote(?, ?, ?) payment, bk_core.ln_rate(?) rate from dual",
                    prod, amount, months, prod);
        }
        if (!get && p.length == 1) {
            need(u, "MANAGER");
            long pay = toAccount(c, Http.text(in, "pay_account", true));
            Map<String, Object> h = Db.row(c, "select customer_id from bk_holder where account_id = ? and role = 'P'", pay);
            BigDecimal months = Http.decimal(in, "months", null);
            long id = Db.fn(c, "bk_core.ln_open(p_product_code => ?, p_customer_id => ?, p_amount => ?, p_months => ?, "
                    + "p_pay_account_id => ?, p_pay_day => ?)", Http.text(in, "product", true), h.get("customer_id"),
                    Http.decimal(in, "amount", null), months, pay, Http.decimal(in, "pay_day", null));
            return loan(c, id);
        }
        if (p.length < 2) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
        }
        long id = Http.id(p[1]);
        if (get && p.length == 2) {
            return loan(c, id);
        }
        if (!get && is(p, "loans", "*", "prepay")) {
            need(u, "MANAGER");
            loan(c, id);
            String mode = Http.text(in, "mode", false);
            long e = Db.fn(c, "bk_core.ln_prepay(?, ?, ?)", id, Http.decimal(in, "amount", null),
                    mode == null ? "T" : mode.toUpperCase());
            Map<String, Object> r = loan(c, id);
            r.put("entry_id", e);
            return r;
        }
        if (!get && is(p, "loans", "*", "payoff")) {
            need(u, "MANAGER");
            loan(c, id);
            long e = Db.fn(c, "bk_core.ln_prepay(?, bk_core.ln_payoff(?))", id, id);
            Map<String, Object> r = loan(c, id);
            r.put("entry_id", e);
            return r;
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    private static Map<String, Object> loan(Connection c, long id) throws SQLException {
        Map<String, Object> r = Db.row(c, LOAN_COLS + " where id = ?", id);
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει δάνειο " + id);
        }
        r.put("payoff", Db.row(c, "select bk_core.ln_payoff(?) v from dual", id).get("v"));
        r.put("schedule", Db.rows(c, "select n, due_date, rate, principal, interest, payment, balance, status, paid, "
                + "paid_on, late_fee, late_booked from bk_ln_schedule where account_id = ? order by n", id));
        return r;
    }

    // ---------------------------------------------------------------------------------------------
    private Object fx(Connection c, Auth.User u, boolean get, String[] p, Map<String, String> q, Map<String, Object> in)
            throws SQLException {
        String list = "select code, name, decimals, spread_pct, active, mid, rate_day from bk_currency_v "
                + "order by case when code = bk_core.base_currency then 0 else 1 end, code";
        if (get && p.length == 1) {
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("base", Db.row(c, "select bk_core.base_currency v from dual").get("v"));
            r.put("currencies", Db.rows(c, list));
            return r;
        }
        if (get && is(p, "fx", "convert")) {
            String a = q.get("amount");
            if (a == null || q.get("from") == null || q.get("to") == null) {
                throw new Http.Fail(400, "missing", "amount, from, to");
            }
            BigDecimal amount;
            try {
                amount = new BigDecimal(a.replace(',', '.'));
            } catch (NumberFormatException e) {
                throw new Http.Fail(400, "bad_number", "amount: a number");
            }
            return Db.row(c, "select ? amount, upper(?) from_, upper(?) to_, bk_core.fx_convert(?, ?, ?) mid, "
                    + "bk_core.fx_convert(?, ?, ?, null, 'Y') customer from dual", amount, q.get("from"), q.get("to"),
                    amount, q.get("from"), q.get("to"), amount, q.get("from"), q.get("to"));
        }
        if (get && p.length == 2) {
            Map<String, Object> r = Db.row(c, "select code, name, decimals, spread_pct, active, mid, rate_day from bk_currency_v "
                    + "where code = upper(?)", p[1]);
            if (r == null) {
                throw new Http.Fail(404, "not_found", "Δεν υπάρχει νόμισμα " + p[1]);
            }
            r.put("rates", Db.rows(c, "select day, mid from bk_fx_rate where currency = upper(?) order by day desc "
                    + "fetch first ? rows only", p[1], Http.number(q, "days", 60, 1, 5000)));
            return r;
        }
        if (!get && p.length == 1) {
            need(u, "MANAGER");
            String active = Http.text(in, "active", false);
            Db.exec(c, "begin bk_core.set_currency(?, ?, ?, ?, ?); end;", Http.text(in, "code", true), Http.text(in, "name", true),
                    Http.decimal(in, "decimals", new BigDecimal(2)), Http.decimal(in, "spread_pct", new BigDecimal("0.5")),
                    active == null ? "Y" : active.toUpperCase());
            return fx(c, u, true, new String[]{"fx"}, Map.of(), Map.of());
        }
        if (!get && is(p, "fx", "*", "rates")) {
            need(u, "MANAGER");
            LocalDate d = Http.dateValue(in, "day");
            Db.exec(c, "begin bk_core.set_fx_rate(?, ?, ?); end;", p[1], d == null ? day(c) : d, Http.decimal(in, "mid", null));
            return fx(c, u, true, new String[]{"fx", p[1]}, Map.of(), Map.of());
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    // ---------------------------------------------------------------------------------------------
    private Object accounts(Connection c, Auth.User u, boolean get, String[] p, Map<String, String> q,
                            Map<String, Object> in) throws SQLException {
        if (get && p.length == 1) {
            String s = q.getOrDefault("q", "").trim();
            String st = q.getOrDefault("status", "").trim().toUpperCase();
            String br = q.getOrDefault("branch", "").trim();
            Object v = s.isEmpty() ? null : s;
            Object vs = st.isEmpty() ? null : st;
            Object vb = br.isEmpty() ? null : br;
            String from = " from bk_account a join bk_product p on p.id = a.product_id "
                    + "join bk_holder h on h.account_id = a.id and h.role = 'P' join bk_customer c on c.id = h.customer_id "
                    + "where (? is null or a.iban like '%' || replace(upper(?), ' ') || '%' or " + ai("c.name")
                    + " like '%' || " + ai("?") + " || '%' or c.afm = ? or c.code = upper(?)"
                    + " or exists (select 1 from bk_holder j join bk_customer jc on jc.id = j.customer_id "
                    + "where j.account_id = a.id and j.role = 'J' and (" + ai("jc.name") + " like '%' || " + ai("?")
                    + " || '%' or jc.afm = ?))) and (? is null or a.status = ?) and (? is null or a.branch_code = ?)";
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("total", Db.row(c, "select count(*) n" + from, v, v, v, v, v, v, v, vs, vs, vb, vb).get("n"));
            r.put("rows", Db.rows(c, "select a.id, a.iban, p.code product, a.name, a.status, a.currency, a.branch_code, a.balance, "
                    + "a.od_limit, a.accrued, c.id customer_id, c.name holder, (select count(*) from bk_holder j where j.account_id = a.id) "
                    + "holders" + from + " order by a.id offset ? rows fetch next ? rows only",
                    v, v, v, v, v, v, v, vs, vs, vb, vb, Http.number(q, "offset", 0, 0, Integer.MAX_VALUE), limit(q)));
            return r;
        }
        if (!get && p.length == 1) {
            Long cust = Http.longValue(in, "customer_id");
            String prod = Http.text(in, "product", true);
            long id = Db.fn(c, "bk_core.open_account(p_product_code => ?, p_customer_id => ?, p_od_limit => ?, p_name => ?, "
                    + "p_currency => ?, p_branch_code => ?)", prod, cust, Http.decimal(in, "od_limit", BigDecimal.ZERO),
                    Http.text(in, "name", false), Http.text(in, "currency", false), Http.text(in, "branch", false));
            return account(c, id);
        }
        if (p.length < 2) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
        }
        long id = Http.id(p[1]);
        if (get && p.length == 2) {
            accrue(c, id);
            return account(c, id);
        }
        if (get && is(p, "accounts", "*", "statement")) {
            return statement(c, id, q);
        }
        if (get && is(p, "accounts", "*", "interest")) {
            accrue(c, id);
            return interest(c, id, q);
        }
        if (get && is(p, "accounts", "*", "limits")) {
            account(c, id);
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("limits", Db.rows(c, "select * from bk_limits where account_id = ? order by "
                    + "instr('DEP WDR TRO TRI OUT INC', op), instr('BR WEB ATM', channel)", id));
            r.put("rules", rulesOf(c, id));
            return r;
        }
        if (get && is(p, "accounts", "*", "cards")) {
            account(c, id);
            return cardsOf(c, id);
        }
        if (!get && is(p, "accounts", "*", "cards")) {
            long card = Db.fn(c, "bk_core.new_card(?, ?)", id, Http.longValue(in, "customer_id"));
            String pin = Atm.newPin();
            Atm.setPin(c, card, pin);
            Map<String, Object> r = card(c, card);
            r.put("pin", pin);
            return r;
        }
        if (!get && is(p, "accounts", "*", "holders")) {
            Db.exec(c, "begin bk_core.add_holder(?, ?); end;", id, Http.longValue(in, "customer_id"));
            return account(c, id);
        }
        if (!get && is(p, "accounts", "*", "holders", "*", "remove")) {
            Db.exec(c, "begin bk_core.remove_holder(?, ?); end;", id, Http.id(p[3]));
            return account(c, id);
        }
        if (!get && is(p, "accounts", "*", "status")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.set_status(?, ?); end;", id, Http.text(in, "status", true));
            return account(c, id);
        }
        if (!get && is(p, "accounts", "*", "branch")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.set_account_branch(?, ?); end;", id, Http.text(in, "branch", true));
            return account(c, id);
        }
        if (!get && is(p, "accounts", "*", "od-limit")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.set_od_limit(?, ?); end;", id, Http.decimal(in, "od_limit", BigDecimal.ZERO));
            return account(c, id);
        }
        if (!get && is(p, "accounts", "*", "close")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.close_account(?); end;", id);
            return account(c, id);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    /** its interest up to the last day closed (bk_core.accrue: nothing when it is there already) */
    private static void accrue(Connection c, long id) throws SQLException {
        Map<String, Object> a = Db.row(c, "select status, opened_on from bk_account where id = ?", id);
        if (a != null && !"C".equals(a.get("status"))
                && LocalDate.parse((String) a.get("opened_on")).isBefore(day(c))) {
            Db.exec(c, "begin bk_core.accrue(?); end;", id);
        }
    }

    private static Map<String, Object> account(Connection c, long id) throws SQLException {
        Map<String, Object> r = Db.row(c, "select a.id, a.iban, a.name, p.code product, p.name product_name, p.kind, "
                + "p.day_basis, p.cap_every, p.tax_rate, p.od_rate, a.opened_on, a.closed_on, a.status, a.od_limit, "
                + "a.balance, round(a.accrued, 2) accrued, a.accrued_to, a.currency, p.currencies, a.branch_code, "
                + "(select b.name from bk_branch b where b.code = a.branch_code) branch_name, "
                + "case when a.status = 'O' then a.balance + a.od_limit else 0 end available, "
                + "bk_core.rate_of(a.product_id, bk_core.open_day, a.balance, a.currency) rate_now "
                + "from bk_account a join bk_product p on p.id = a.product_id where a.id = ?", id);
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει λογαριασμός " + id);
        }
        r.put("holders", Db.rows(c, "select c.id, c.code, c.name, c.afm, h.role from bk_holder h "
                + "join bk_customer c on c.id = h.customer_id where h.account_id = ? order by h.role desc, c.name", id));
        return r;
    }

    private static Map<String, Object> statement(Connection c, long id, Map<String, String> q) throws SQLException {
        Map<String, Object> a = account(c, id);
        LocalDate d = day(c);
        LocalDate to = Http.date(q, "to", d);
        LocalDate from = Http.date(q, "from", to.minusDays(30));
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("account", a);
        r.put("from", from.toString());
        r.put("to", to.toString());
        Object in = Db.row(c, "select nvl(sum(l.credit - l.debit), 0) v from bk_line l join bk_entry e on e.id = l.entry_id "
                + "where l.account_id = ? and e.book_date < ?", id, from).get("v");
        r.put("carry_in", in);
        List<Map<String, Object>> rows = Db.rows(c, "select s.entry_id, s.kind, l.op, e.channel, s.book_date, s.value_date, "
                + "s.descr, s.reversal_of, (select x.id from bk_entry x where x.reversal_of = s.entry_id) reversed_by, "
                + "s.debit, s.credit, s.balance, e.created_by, e.orig_amount, e.orig_currency, e.fx_rate "
                + "from bk_statement s join bk_entry e on e.id = s.entry_id "
                + "join bk_line l on l.id = s.line_id where s.account_id = ? and s.book_date between ? and ? "
                + "order by s.book_date, s.entry_id, s.line_id fetch first 3000 rows only", id, from, to);
        r.put("rows", rows);
        BigDecimal debit = BigDecimal.ZERO;
        BigDecimal credit = BigDecimal.ZERO;
        for (Map<String, Object> x : rows) {
            debit = debit.add((BigDecimal) x.get("debit"));
            credit = credit.add((BigDecimal) x.get("credit"));
        }
        r.put("debit", debit);
        r.put("credit", credit);
        r.put("carry_out", ((BigDecimal) in).add(credit).subtract(debit));
        return r;
    }

    private static Map<String, Object> interest(Connection c, long id, Map<String, String> q) throws SQLException {
        Map<String, Object> a = account(c, id);
        LocalDate d = day(c);
        LocalDate to = Http.date(q, "to", d);
        LocalDate from = Http.date(q, "from", to.minusDays(90));
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("account", a);
        r.put("from", from.toString());
        r.put("to", to.toString());
        r.put("stretches", Db.rows(c, "select day_from, day_to, balance, rate, days, year_days, interest from bk_accrual "
                + "where account_id = ? and day_to >= ? and day_from <= ? order by day_from", id, from, to));
        r.put("capitalized", Db.rows(c, "select day, gross, tax, gross - tax net, entry_id from bk_capital "
                + "where account_id = ? and day between ? and ? order by day", id, from, to));
        r.put("total", Db.row(c, "select nvl(sum(interest), 0) v from bk_accrual where account_id = ? and day_to >= ? "
                + "and day_from <= ?", id, from, to).get("v"));
        return r;
    }

    // ---------------------------------------------------------------------------------------------
    private static Object movement(Connection c, Map<String, Object> in) throws SQLException {
        String kind = String.valueOf(Http.text(in, "kind", true)).toUpperCase();
        Long acc = Http.longValue(in, "account_id");
        if (acc == null) {
            throw new Http.Fail(400, "missing", "account_id");
        }
        BigDecimal amount = Http.decimal(in, "amount", null);
        if (amount == null) {
            throw new Http.Fail(400, "missing", "amount");
        }
        String descr = Http.text(in, "descr", false);
        LocalDate vd = Http.dateValue(in, "value_date");
        String ch = Http.text(in, "channel", false);
        String channel = ch == null ? "BR" : ch.toUpperCase();
        String tail = ", p_descr => ?, p_value_date => ?, p_channel => ?)";
        long e = switch (kind) {
            case "DEP" -> Db.fn(c, "bk_core.deposit(p_account_id => ?, p_amount => ?" + tail, acc, amount, descr, vd, channel);
            case "WDR" -> Db.fn(c, "bk_core.withdraw(p_account_id => ?, p_amount => ?" + tail, acc, amount, descr, vd, channel);
            case "TRF" -> Db.fn(c, "bk_core.transfer(p_from_id => ?, p_to_id => ?, p_amount => ?" + tail, acc,
                    toAccount(c, Http.text(in, "to_account", true)), amount, descr, vd, channel);
            case "OUT" -> Db.fn(c, "bk_core.transfer_out(p_from_id => ?, p_amount => ?, p_iban_to => ?" + tail, acc, amount,
                    Http.text(in, "iban", true), descr, vd, channel);
            case "INC" -> Db.fn(c, "bk_core.transfer_in(p_to_id => ?, p_amount => ?, p_iban_from => ?" + tail, acc, amount,
                    Http.text(in, "iban", true), descr, vd, channel);
            default -> throw new Http.Fail(400, "bad_kind", "Κίνηση: DEP, WDR, TRF, OUT ή INC");
        };
        Map<String, Object> r = entry(c, e);
        r.put("balance", account(c, acc).get("balance"));
        return r;
    }

    /** the account of a transfer: its id or its IBAN */
    private static long toAccount(Connection c, String v) throws SQLException {
        String s = v.replace(" ", "").toUpperCase();
        Map<String, Object> r = s.startsWith("GR") ? Db.row(c, "select id from bk_account where iban = ?", s)
                : s.matches("\\d{1,18}") ? Db.row(c, "select id from bk_account where id = ?", Long.parseLong(s)) : null;
        if (r == null) {
            throw new Http.Fail(400, "BK-108", "Δεν υπάρχει λογαριασμός " + v + " στην τράπεζα");
        }
        return ((Number) r.get("id")).longValue();
    }

    private static Map<String, Object> entry(Connection c, long id) throws SQLException {
        Map<String, Object> r = Db.row(c, "select id, kind, channel, book_date, value_date, descr, reversal_of, "
                + "orig_amount, orig_currency, fx_rate, "
                + "(select x.id from bk_entry x where x.reversal_of = e.id) reversed_by, created_by, "
                + "to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') created_at from bk_entry e where id = ?", id);
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει εγγραφή " + id);
        }
        r.put("lines", Db.rows(c, "select l.id, l.account_id, a.iban, l.gl_code, g.name gl_name, l.op, l.currency, "
                + "l.debit, l.credit, l.base_debit, l.base_credit "
                + "from bk_line l left join bk_account a on a.id = l.account_id left join bk_gl g on g.code = l.gl_code "
                + "where l.entry_id = ? order by l.id", id));
        return r;
    }

    // ---------------------------------------------------------------------------------------------
    private static final String CARD_COLS = "select k.id, k.pan, k.account_id, k.customer_id, c.name holder, k.issued_on, "
            + "k.expires, k.status, case when k.pin_hash is null then 'N' else 'Y' end has_pin, k.pin_failed, "
            + "case when k.pin_failed >= " + Atm.PIN_TRIES + " then 'Y' else 'N' end pin_locked, "
            + "case when k.expires < bk_core.open_day then 'Y' else 'N' end expired "
            + "from bk_card k join bk_customer c on c.id = k.customer_id";

    private static List<Map<String, Object>> cardsOf(Connection c, long account) throws SQLException {
        return Db.rows(c, CARD_COLS + " where k.account_id = ? order by decode(k.status, 'C', 1, 0), k.id desc", account);
    }

    private static Map<String, Object> card(Connection c, long id) throws SQLException {
        Map<String, Object> r = Db.row(c, CARD_COLS + " where k.id = ?", id);
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει κάρτα " + id);
        }
        return r;
    }

    private Object cards(Connection c, Auth.User u, boolean get, String[] p, Map<String, Object> in) throws SQLException {
        if (!get && is(p, "cards", "pins")) {
            need(u, "MANAGER");
            return Atm.pinsForAll(c, Http.text(in, "pin", false), Boolean.TRUE.equals(in.get("all")));
        }
        if (!get && is(p, "cards", "*", "pin")) {
            long id = Http.id(p[1]);
            Map<String, Object> k = card(c, id);
            if ("C".equals(k.get("status"))) {
                throw new Http.Fail(400, "BK-134", "Η κάρτα είναι ακυρωμένη");
            }
            String pin = Atm.newPin();
            Atm.setPin(c, id, pin);
            Map<String, Object> r = card(c, id);
            r.put("pin", pin);
            return r;
        }
        if (!get && is(p, "cards", "*", "status")) {
            long id = Http.id(p[1]);
            String st = up(Http.text(in, "status", true));
            if (!"B".equals(st)) {
                need(u, "MANAGER");
            }
            Db.exec(c, "begin bk_core.set_card_status(?, ?); end;", id, st);
            return card(c, id);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    // ---------------------------------------------------------------------------------------------
    private static final String RULE_COLS = "r.id, r.product_id, p.code product, r.account_id, a.iban, r.op, r.channel, "
            + "r.allowed, r.min_amount, r.max_amount, r.day_amount, r.day_count, r.month_amount, r.month_count, "
            + "r.free_month, r.fee, r.min_balance, case when r.account_id is not null then 'ACCOUNT' "
            + "when r.product_id is not null then 'PRODUCT' else 'BANK' end lvl";
    private static final String RULE_FROM = " from bk_rule r left join bk_product p on p.id = r.product_id "
            + "left join bk_account a on a.id = r.account_id ";
    private static final String RULE_ORDER = " order by case when r.account_id is not null then 2 "
            + "when r.product_id is not null then 1 else 0 end, p.code, r.account_id, "
            + "instr('DEP WDR TRO TRI OUT INC', r.op), instr('* BR WEB ATM', r.channel)";

    private static List<Map<String, Object>> rulesOf(Connection c, long account) throws SQLException {
        return Db.rows(c, "select " + RULE_COLS + RULE_FROM + "where r.account_id = ? or r.product_id = "
                + "(select product_id from bk_account where id = ?) or (r.account_id is null and r.product_id is null)"
                + RULE_ORDER, account, account);
    }

    private Object rules(Connection c, Auth.User u, boolean get, String[] p, Map<String, String> q,
                         Map<String, Object> in) throws SQLException {
        if (get && p.length == 1) {
            String prod = q.get("product");
            String acc = q.get("account_id");
            String lvl = q.getOrDefault("level", "").toUpperCase();
            Object vp = prod == null || prod.isBlank() ? null : prod.toUpperCase();
            Object va = acc == null || acc.isBlank() ? null : Http.id(acc);
            Object vl = lvl.isEmpty() ? null : lvl;
            return Db.rows(c, "select * from (select " + RULE_COLS + ", instr('DEP WDR TRO TRI OUT INC', r.op) o1, "
                    + "instr('* BR WEB ATM', r.channel) o2" + RULE_FROM + ") r where (? is null or r.product = ?) "
                    + "and (? is null or r.account_id = ?) and (? is null or r.lvl = ?) "
                    + "order by decode(r.lvl, 'BANK', 0, 'PRODUCT', 1, 2), r.product, r.account_id, r.o1, r.o2",
                    vp, vp, va, va, vl, vl);
        }
        if (!get && p.length == 1) {
            need(u, "MANAGER");
            long id = Db.fn(c, "bk_core.set_rule(p_product_code => ?, p_account_id => ?, p_op => ?, p_channel => ?, "
                            + "p_allowed => ?, p_min_amount => ?, p_max_amount => ?, p_day_amount => ?, p_day_count => ?, "
                            + "p_month_amount => ?, p_month_count => ?, p_free_month => ?, p_fee => ?, p_min_balance => ?)",
                    Http.text(in, "product", false), Http.longValue(in, "account_id"), up(Http.text(in, "op", true)),
                    up(Http.text(in, "channel", false)), up(Http.text(in, "allowed", false)),
                    Http.decimal(in, "min_amount", null), Http.decimal(in, "max_amount", null),
                    Http.decimal(in, "day_amount", null), Http.decimal(in, "day_count", null),
                    Http.decimal(in, "month_amount", null), Http.decimal(in, "month_count", null),
                    Http.decimal(in, "free_month", null), Http.decimal(in, "fee", null),
                    Http.decimal(in, "min_balance", null));
            return Db.row(c, "select " + RULE_COLS + RULE_FROM + "where r.id = ?", id);
        }
        if (!get && is(p, "rules", "*", "remove")) {
            need(u, "MANAGER");
            Db.exec(c, "begin bk_core.remove_rule(?); end;", Http.id(p[1]));
            return Map.of("ok", true);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }

    private static String up(String s) {
        return s == null ? null : s.trim().toUpperCase();
    }

    // ---------------------------------------------------------------------------------------------
    private static final String USER_COLS = "select u.id, u.username, u.full_name, u.role, u.active, u.failed, u.branch_code, "
            + "case when u.failed >= " + Auth.MAX_FAILED + " then 'Y' else 'N' end locked, u.created_at, "
            + "(select to_char(max(s.created_at), 'YYYY-MM-DD HH24:MI') from bk_session s where s.user_id = u.id) last_login "
            + "from bk_user u";

    private Object users(Connection c, Auth.User me, boolean get, String[] p, Map<String, Object> in)
            throws SQLException {
        if (get && p.length == 1) {
            return Db.rows(c, USER_COLS + " order by u.username");
        }
        if (!get && p.length == 1) {
            long id = Auth.createUser(c, Http.text(in, "username", true), Http.text(in, "full_name", true),
                    Http.text(in, "role", true), Http.text(in, "password", true));
            String br = Http.text(in, "branch", false);
            if (br != null) {
                Db.exec(c, "begin bk_core.set_user_branch(?, ?); end;", Http.text(in, "username", true), br);
            }
            return Db.row(c, USER_COLS + " where u.id = ?", id);
        }
        if (!get && p.length == 2) {
            long id = Http.id(p[1]);
            Map<String, Object> old = Db.row(c, USER_COLS + " where u.id = ?", id);
            if (old == null) {
                throw new Http.Fail(404, "not_found", "Δεν υπάρχει χρήστης " + id);
            }
            String name = Http.text(in, "full_name", false);
            String role = in.containsKey("role") ? Auth.role(Http.text(in, "role", false)) : (String) old.get("role");
            String active = in.containsKey("active") ? up(Http.text(in, "active", false)) : (String) old.get("active");
            if (!"Y".equals(active) && !"N".equals(active)) {
                throw new Http.Fail(400, "bad_active", "Ενεργός: Y ή N");
            }
            if ("ADMIN".equals(old.get("role")) && "Y".equals(old.get("active"))
                    && (!"ADMIN".equals(role) || !"Y".equals(active))) {
                Object n = Db.row(c, "select count(*) n from bk_user where role = 'ADMIN' and active = 'Y' and id <> ?", id)
                        .get("n");
                if (((Number) n).intValue() == 0) {
                    throw new Http.Fail(400, "last_admin", "Μένει πάντα ένας ενεργός ADMIN");
                }
            }
            Db.exec(c, "update bk_user set full_name = nvl(?, full_name), role = ?, active = ? where id = ?",
                    name, role, active, id);
            if ("N".equals(active)) {
                Db.exec(c, "update bk_session set revoked = 'Y' where user_id = ?", id);
            }
            String br = Http.text(in, "branch", false);
            if (br != null) {
                Db.exec(c, "begin bk_core.set_user_branch(?, ?); end;", old.get("username"), br);
            }
            String pw = Http.text(in, "password", false);
            if (pw != null) {
                Auth.setPassword(c, id, pw);
            } else if (Boolean.TRUE.equals(in.get("unlock"))) {
                Db.exec(c, "update bk_user set failed = 0 where id = ?", id);
            }
            return Db.row(c, USER_COLS + " where u.id = ?", id);
        }
        throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
    }
}
