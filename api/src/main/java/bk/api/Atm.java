package bk.api;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.math.BigDecimal;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The ATM (the page /atm/): a card and its PIN, then its account, within the rules of the channel ATM. No login
 * of a user: the card is the login. Its PIN: PBKDF2-SHA256 (BK_CARD), 3 wrong in a row: locked (the counter
 * gives a new one). A session: for one card at one ATM, 2 minutes without a move and it ends (in memory: a
 * restart ends them all). Everything that moves money goes through BK_CORE (atm_withdraw, atm_deposit,
 * atm_transfer); each entry carries the code of the ATM (CREATED_BY).
 *
 * <pre>
 *   GET  /api/atm/                       the ATMs that work
 *   GET  /api/atm/{code}                 one: its name, if it has cash, the notes it gives (the highest first)
 *   POST /api/atm/{code}/login {pan, pin}   its token, the holder, the account
 *   POST /api/atm/{code}/balance         balance, available, what may be withdrawn today
 *   POST /api/atm/{code}/options {amount}    the ways the ATM can give it now (its notes): up to 4, the fewest
 *                                        notes first
 *   POST /api/atm/{code}/withdraw {amount, notes}   notes: {"50": 4, "20": 5} (none: the first way); the receipt
 *   POST /api/atm/{code}/deposit {amount}
 *   POST /api/atm/{code}/transfer {iban, amount}   to an account of the bank
 *   POST /api/atm/{code}/statement       the last 10 moves
 *   POST /api/atm/{code}/pin {pin}       a new PIN (4 digits)
 *   POST /api/atm/{code}/end             the card back
 * </pre>
 */
final class Atm {
    static final int PIN_TRIES = 3;
    static final long IDLE_MS = 120_000;
    private static final SecureRandom RANDOM = new SecureRandom();
    private final Db db;
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();

    /** a card at an ATM; its last move */
    private static final class Session {
        final long cardId;
        final String atm;
        volatile long seen = System.currentTimeMillis();

        Session(long cardId, String atm) {
            this.cardId = cardId;
            this.atm = atm;
        }
    }

    Atm(Db db) {
        this.db = db;
    }

    void register(HttpServer server) {
        server.createContext("/api/atm/", this::handle);
    }

    // ---------------------------------------------------------------------------------------------
    // the PIN (and the counter: a new one)
    static String newPin() {
        String p;
        do {
            p = String.format("%04d", RANDOM.nextInt(10_000));
        } while (p.chars().distinct().count() == 1 || "1234".equals(p));
        return p;
    }

    static void pinOk(String pin) {
        if (pin == null || !pin.matches("\\d{4}") || pin.chars().distinct().count() == 1 || "1234".equals(pin)) {
            throw new Http.Fail(400, "bad_pin", "Το PIN: 4 ψηφία, όχι όλα ίδια και όχι 1234");
        }
    }

    /** a PIN to a card: its hash; unlocked */
    static void setPin(Connection c, long cardId, String pin) throws SQLException {
        pinOk(pin);
        byte[] salt = new byte[16];
        RANDOM.nextBytes(salt);
        Db.exec(c, "update bk_card set pin_hash = ?, pin_salt = ?, pin_iter = ?, pin_failed = 0 where id = ?",
                Auth.pbkdf2(pin, salt, Auth.ITERATIONS), salt, Auth.ITERATIONS, cardId);
    }

    /**
     * a PIN to many cards at once (the cards of the demo have none): each active card, not expired, without a
     * PIN (p_all: with one too); the same PIN to all (p_pin) or a new one to each (null). The cards and their PIN
     * back: to be given to their holders
     */
    static List<Map<String, Object>> pinsForAll(Connection c, String pin, boolean all) throws SQLException {
        if (pin != null) {
            pinOk(pin);
        }
        List<Map<String, Object>> rows = Db.rows(c, "select k.id, k.pan, c.name holder, a.iban from bk_card k "
                + "join bk_customer c on c.id = k.customer_id join bk_account a on a.id = k.account_id "
                + "where k.status = 'A' and k.expires >= bk_core.open_day and a.status <> 'C' "
                + "and (? = 'Y' or k.pin_hash is null) order by k.id", all ? "Y" : "N");
        for (Map<String, Object> r : rows) {
            String p = pin != null ? pin : newPin();
            setPin(c, ((Number) r.get("id")).longValue(), p);
            r.put("pin", p);
        }
        return rows;
    }

    // ---------------------------------------------------------------------------------------------
    private void handle(HttpExchange ex) throws IOException {
        try {
            String raw = ex.getRequestURI().getRawPath();
            if (raw.contains("..") || raw.contains("%") || raw.contains("//")) {
                throw new Http.Fail(400, "bad_path", "bad path");
            }
            String method = ex.getRequestMethod();
            String[] p = raw.substring("/api/atm/".length()).split("/");
            Map<String, Object> in = "POST".equals(method) ? Http.body(ex) : Map.of();
            Object body;
            try (Connection c = db.connection()) {
                try {
                    body = route(c, ex, method, p, in);
                    c.commit();
                } catch (SQLException e) {
                    c.rollback();
                    throw Http.fromSql(e);
                } catch (RuntimeException e) {
                    c.rollback();
                    throw e;
                } finally {
                    Db.exec(c, "begin dbms_session.clear_identifier; end;");
                }
            }
            Http.send(ex, 200, body);
        } catch (Http.Fail f) {
            Http.send(ex, f.status, Http.error(f.code, f.getMessage()));
        } catch (SQLException e) {
            Http.Fail f = Http.fromSql(e);
            Http.send(ex, f.status, Http.error(f.code, f.getMessage()));
        } catch (Exception e) {
            System.err.println("== bk-api atm: " + e);
            Http.send(ex, 500, Http.error("error", "Το ATM δεν μπορεί να εξυπηρετήσει αυτή τη στιγμή"));
        } finally {
            ex.close();
        }
    }

    private Object route(Connection c, HttpExchange ex, String m, String[] p, Map<String, Object> in) throws SQLException {
        boolean get = "GET".equals(m);
        if (get && (p.length == 0 || p.length == 1 && p[0].isEmpty())) {
            return Db.rows(c, "select code, name, address from bk_atm where active = 'Y' order by code");
        }
        String code = p[0].toUpperCase();
        if (get && p.length == 1) {
            Map<String, Object> r = Db.row(c, "select code, name, address, active, "
                    + "case when cash > 0 then 'Y' else 'N' end cash_ok from bk_atm where code = ?", code);
            if (r == null) {
                throw new Http.Fail(404, "not_found", "Δεν υπάρχει ATM " + code);
            }
            r.put("notes", notes(c));
            r.put("max_notes", maxNotes(c));
            return r;
        }
        if (get || p.length != 2) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
        }
        Db.exec(c, "begin dbms_session.set_identifier(?); end;", code);
        if ("login".equals(p[1])) {
            return login(c, code, Http.text(in, "pan", true), Http.text(in, "pin", true));
        }
        String token = bearer(ex);
        Session s = token == null ? null : sessions.get(token);
        if (s == null || !s.atm.equals(code) || System.currentTimeMillis() - s.seen > IDLE_MS) {
            if (token != null) {
                sessions.remove(token);
            }
            throw new Http.Fail(401, "no_session", "Ο χρόνος τελείωσε: η κάρτα επιστράφηκε");
        }
        s.seen = System.currentTimeMillis();
        if ("end".equals(p[1])) {
            sessions.remove(token);
            return Map.of("ok", true);
        }
        long acc = Db.fn(c, "bk_core.card_account(?)", s.cardId);
        switch (p[1]) {
            case "balance" -> {
                return balance(c, acc, code);
            }
            case "options" -> {
                BigDecimal amount = amount(in);
                String o = (String) Db.row(c, "select bk_core.atm_options(?, ?) o from dual", code, amount).get("o");
                if (o == null) {
                    throw new Http.Fail(400, "BK-138", cannot(c, amount));
                }
                Map<String, Object> r = new LinkedHashMap<>();
                r.put("amount", amount);
                List<Map<String, Object>> ways = new java.util.ArrayList<>();
                for (String spec : o.split(";")) {
                    Map<String, Object> w = new LinkedHashMap<>();
                    Map<String, Integer> n = parse(spec);
                    w.put("notes", n);
                    w.put("pieces", n.values().stream().mapToInt(Integer::intValue).sum());
                    ways.add(w);
                }
                r.put("options", ways);
                r.put("max_notes", maxNotes(c));
                return r;
            }
            case "withdraw" -> {
                BigDecimal amount = amount(in);
                String spec = spec(in.get("notes"));
                if (spec == null) {          // the first way (none: the error of atm_withdraw, its cash first)
                    spec = (String) Db.row(c, "select regexp_substr(bk_core.atm_options(?, ?), '[^;]+') o from dual",
                            code, amount).get("o");
                }
                long e = Db.fn(c, "bk_core.atm_withdraw(?, ?, ?, ?)", code, s.cardId, amount, spec);
                Map<String, Object> r = receipt(c, e, acc, code);
                r.put("notes", parse(spec));
                return r;
            }
            case "deposit" -> {
                long e = Db.fn(c, "bk_core.atm_deposit(?, ?, ?)", code, s.cardId, amount(in));
                return receipt(c, e, acc, code);
            }
            case "transfer" -> {
                long e = Db.fn(c, "bk_core.atm_transfer(?, ?, ?, ?)", code, s.cardId, Http.text(in, "iban", true), amount(in));
                return receipt(c, e, acc, code);
            }
            case "statement" -> {
                Map<String, Object> r = new LinkedHashMap<>();
                r.put("iban", mask(iban(c, acc)));
                r.put("rows", Db.rows(c, "select * from (select s.book_date, s.descr, s.credit - s.debit amount, s.balance "
                        + "from bk_statement s where s.account_id = ? order by s.book_date desc, s.entry_id desc, s.line_id desc) "
                        + "where rownum <= 10", acc));
                r.put("balance", Db.row(c, "select balance from bk_account where id = ?", acc).get("balance"));
                return r;
            }
            case "pin" -> {
                setPin(c, s.cardId, Http.text(in, "pin", true));
                return Map.of("ok", true);
            }
            default -> throw new Http.Fail(404, "not_found", "Δεν υπάρχει αυτή η κλήση");
        }
    }

    private static String bearer(HttpExchange ex) {
        String h = ex.getRequestHeaders().getFirst("Authorization");
        return h != null && h.startsWith("Bearer ") ? h.substring(7).trim() : null;
    }

    private static BigDecimal amount(Map<String, Object> in) {
        BigDecimal a = Http.decimal(in, "amount", null);
        if (a == null) {
            throw new Http.Fail(400, "missing", "Το ποσό");
        }
        return a;
    }

    private Map<String, Object> login(Connection c, String code, String pan, String pin) throws SQLException {
        Map<String, Object> atm = Db.row(c, "select active from bk_atm where code = ?", code);
        if (atm == null || !"Y".equals(atm.get("active"))) {
            throw new Http.Fail(400, "BK-137", "Το ATM " + code + " δεν λειτουργεί");
        }
        String number = pan.replaceAll("[\\s-]", "");
        Object[] k = null;
        try (var st = c.prepareStatement("select id, pin_hash, pin_salt, pin_iter, pin_failed from bk_card where pan = ? for update")) {
            st.setString(1, number);
            try (var rs = st.executeQuery()) {
                if (rs.next()) {
                    k = new Object[]{rs.getLong(1), rs.getBytes(2), rs.getBytes(3), rs.getInt(4), rs.getInt(5)};
                }
            }
        }
        if (k == null) {
            throw new Http.Fail(401, "bad_card", "Η κάρτα δεν αναγνωρίστηκε");
        }
        long id = (Long) k[0];
        if (k[1] == null) {
            throw new Http.Fail(400, "no_pin", "Η κάρτα δεν έχει PIN ακόμη: το δίνει το κατάστημα");
        }
        int failed = (Integer) k[4];
        if (failed >= PIN_TRIES) {
            throw new Http.Fail(423, "pin_locked", "Το PIN κλειδώθηκε μετά από " + PIN_TRIES + " λάθη: νέο PIN στο κατάστημα");
        }
        byte[] h = Auth.pbkdf2(pin, (byte[]) k[2], (Integer) k[3]);
        if (!MessageDigest.isEqual(h, (byte[]) k[1])) {
            Db.exec(c, "update bk_card set pin_failed = pin_failed + 1 where id = ?", id);
            c.commit();
            int left = PIN_TRIES - failed - 1;
            if (left <= 0) {
                throw new Http.Fail(423, "pin_locked", "Λάθος PIN για " + PIN_TRIES + "η φορά: το PIN κλειδώθηκε, νέο PIN στο κατάστημα");
            }
            throw new Http.Fail(401, "bad_pin", "Λάθος PIN: " + (left == 1 ? "απομένει 1 προσπάθεια" : "απομένουν " + left + " προσπάθειες"));
        }
        Db.exec(c, "update bk_card set pin_failed = 0 where id = ?", id);
        long acc = Db.fn(c, "bk_core.card_account(?)", id);           // (blocked, expired: its BK error)
        byte[] t = new byte[24];
        RANDOM.nextBytes(t);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(t);
        sessions.values().removeIf(x -> System.currentTimeMillis() - x.seen > IDLE_MS);
        sessions.put(token, new Session(id, code));
        Map<String, Object> holder = Db.row(c, "select c.name from bk_card k join bk_customer c on c.id = k.customer_id "
                + "where k.id = ?", id);
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("token", token);
        r.put("holder", holder.get("name"));
        r.put("iban", mask(iban(c, acc)));
        r.put("idle_seconds", IDLE_MS / 1000);
        return r;
    }

    private static String iban(Connection c, long acc) throws SQLException {
        return (String) Db.row(c, "select iban from bk_account where id = ?", acc).get("iban");
    }

    /** an IBAN on a screen or a receipt: its last 4 digits only */
    static String mask(String iban) {
        return iban == null ? null : iban.substring(0, 4) + " •••• " + iban.substring(iban.length() - 4);
    }

    private static Map<String, Object> balance(Connection c, long acc, String code) throws SQLException {
        Map<String, Object> r = Db.row(c, "select a.iban, a.balance, case when a.status = 'O' then a.balance + a.od_limit "
                + "else 0 end available, nvl(bk_core.rule_value(a.id, 'WDR', 'ATM', 'ALLOWED'), 1) allowed, "
                + "bk_core.rule_value(a.id, 'WDR', 'ATM', 'MAX_AMOUNT') max_amount, "
                + "bk_core.rule_value(a.id, 'WDR', 'ATM', 'DAY_AMOUNT') day_amount, "
                + "bk_core.rule_used(a.id, 'WDR', 'ATM', 'DAY_AMOUNT') day_used, "
                + "(select cash from bk_atm where code = ?) atm_cash from bk_account a where a.id = ?", code, acc);
        BigDecimal can = (BigDecimal) r.get("available");
        if (((Number) r.get("allowed")).intValue() == 0) {
            can = BigDecimal.ZERO;
        }
        if (r.get("max_amount") != null) {
            can = can.min((BigDecimal) r.get("max_amount"));
        }
        if (r.get("day_amount") != null) {
            can = can.min(((BigDecimal) r.get("day_amount")).subtract((BigDecimal) r.get("day_used")));
        }
        can = can.min((BigDecimal) r.get("atm_cash"));
        can = can.max(BigDecimal.ZERO).divideToIntegralValue(BigDecimal.TEN).multiply(BigDecimal.TEN);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("iban", mask((String) r.get("iban")));
        out.put("balance", r.get("balance"));
        out.put("available", r.get("available"));
        out.put("withdraw_today", can.stripTrailingZeros().scale() < 0 ? can.setScale(0) : can.stripTrailingZeros());
        return out;
    }

    private static Map<String, Object> receipt(Connection c, long entry, long acc, String code) throws SQLException {
        Map<String, Object> r = Db.row(c, "select e.id entry_id, e.kind, e.descr, "
                + "to_char(e.created_at, 'DD/MM/YYYY HH24:MI') at, (select nvl(sum(l.debit), 0) from bk_line l "
                + "where l.entry_id = e.id and l.account_id = ? and l.op = 'FEE') fee from bk_entry e where e.id = ?", acc, entry);
        r.putAll(balance(c, acc, code));
        r.put("atm", Db.row(c, "select code, name, address from bk_atm where code = ?", code));
        return r;
    }

    /** the notes the ATMs give (the setting ATM_NOTES), the highest first */
    static List<Integer> notes(Connection c) throws SQLException {
        String v = (String) Db.row(c, "select nvl(max(value), '20,50') v from bk_setting where name = 'ATM_NOTES'").get("v");
        List<Integer> l = new java.util.ArrayList<>();
        for (String x : v.split(",")) {
            l.add(Integer.parseInt(x.trim()));
        }
        l.sort(java.util.Comparator.reverseOrder());
        return l;
    }

    static int maxNotes(Connection c) throws SQLException {
        Object v = Db.row(c, "select nvl(max(value), '40') v from bk_setting where name = 'ATM_MAX_NOTES'").get("v");
        return Integer.parseInt(String.valueOf(v));
    }

    private static String cannot(Connection c, BigDecimal amount) throws SQLException {
        List<Integer> n = notes(c);
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < n.size(); i++) {
            s.append(i == 0 ? "" : i == n.size() - 1 ? " και " : ", ").append(n.get(i));
        }
        return "Το ATM δεν μπορεί να δώσει " + amount.stripTrailingZeros().toPlainString()
                + " € με χαρτονομίσματα των " + s + " € (ή δεν έχει τόσα τώρα)";
    }

    /** '50:4,20:5' as {"50": 4, "20": 5} */
    static Map<String, Integer> parse(String spec) {
        Map<String, Integer> n = new LinkedHashMap<>();
        for (String p : spec.split(",")) {
            String[] kv = p.split(":");
            n.put(kv[0], Integer.parseInt(kv[1]));
        }
        return n;
    }

    /** the notes asked: {"50": 4, "20": 5} (or '50:4,20:5') as '50:4,20:5' (a note of 0 pieces left out); null: none */
    @SuppressWarnings("unchecked")
    static String spec(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof String s) {
            return s.isBlank() ? null : s.replace(" ", "");
        }
        if (!(v instanceof Map<?, ?> m)) {
            throw new Http.Fail(400, "bad_notes", "Τα χαρτονομίσματα: {\"50\": 4, \"20\": 5}");
        }
        StringBuilder s = new StringBuilder();
        for (Map.Entry<String, Object> e : ((Map<String, Object>) m).entrySet()) {
            long k;
            long n;
            try {
                k = new BigDecimal(e.getKey()).longValueExact();
                n = new BigDecimal(String.valueOf(e.getValue())).longValueExact();
            } catch (NumberFormatException | ArithmeticException x) {
                throw new Http.Fail(400, "bad_notes", "Τα χαρτονομίσματα: ακέραιοι αριθμοί");
            }
            if (n < 0) {
                throw new Http.Fail(400, "bad_notes", "Τα χαρτονομίσματα: από 0 και πάνω");
            }
            if (n > 0) {
                s.append(s.length() == 0 ? "" : ",").append(k).append(':').append(n);
            }
        }
        if (s.length() == 0) {
            throw new Http.Fail(400, "BK-138", "Κανένα χαρτονόμισμα");
        }
        return s.toString();
    }
}
