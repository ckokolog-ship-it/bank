package bk.api;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Base64;
import java.util.List;
import java.util.Map;

/**
 * The users of the pages (BK_USER) and their sessions (BK_SESSION). The password: PBKDF2-SHA256 with a salt of
 * its own (never kept itself); 5 wrong in a row: locked, until an ADMIN unlocks it or gives a new one. A login:
 * a token (32 random bytes) for 12 hours; the database keeps only its SHA-256. The roles, each with the
 * rights of the one before: TELLER, MANAGER, ADMIN.
 */
final class Auth {
    static final int ITERATIONS = 120_000;
    static final int MAX_FAILED = 5;
    static final List<String> ROLES = List.of("TELLER", "MANAGER", "ADMIN");
    private static final SecureRandom RANDOM = new SecureRandom();

    private Auth() {
    }

    record User(long id, String username, String fullName, String role) {
        boolean is(String r) {
            return ROLES.indexOf(role) >= ROLES.indexOf(r);
        }
    }

    static byte[] pbkdf2(String password, byte[] salt, int iterations) {
        try {
            PBEKeySpec spec = new PBEKeySpec(password.toCharArray(), salt, iterations, 256);
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
        } catch (java.security.GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    static byte[] sha256(String s) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    static void passwordOk(String p) {
        if (p == null || p.length() < 8) {
            throw new Http.Fail(400, "weak_password", "Ο κωδικός: τουλάχιστον 8 χαρακτήρες");
        }
    }

    static String role(String r) {
        String v = r == null ? "" : r.trim().toUpperCase();
        if (!ROLES.contains(v)) {
            throw new Http.Fail(400, "bad_role", "Ρόλος: TELLER, MANAGER ή ADMIN");
        }
        return v;
    }

    static long createUser(Connection c, String username, String fullName, String role, String password)
            throws SQLException {
        String u = username == null ? "" : username.trim().toLowerCase();
        if (!u.matches("[a-z0-9._-]{2,30}")) {
            throw new Http.Fail(400, "bad_username", "Όνομα χρήστη: 2 ως 30 πεζά γράμματα, ψηφία, . _ -");
        }
        if (fullName == null || fullName.isBlank()) {
            throw new Http.Fail(400, "missing", "Το ονοματεπώνυμο του χρήστη");
        }
        String r = role(role);
        passwordOk(password);
        if (Db.row(c, "select id from bk_user where username = ?", u) != null) {
            throw new Http.Fail(400, "exists", "Υπάρχει ήδη χρήστης " + u);
        }
        byte[] salt = new byte[16];
        RANDOM.nextBytes(salt);
        Db.exec(c, "insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter) values (?, ?, ?, ?, ?, ?)",
                u, fullName.trim(), r, pbkdf2(password, salt, ITERATIONS), salt, ITERATIONS);
        return userId(c, u);
    }

    static long userId(Connection c, String username) throws SQLException {
        Map<String, Object> r = Db.row(c, "select id from bk_user where username = ?",
                username == null ? "" : username.trim().toLowerCase());
        if (r == null) {
            throw new Http.Fail(404, "not_found", "Δεν υπάρχει χρήστης " + username);
        }
        return ((Number) r.get("id")).longValue();
    }

    /** a new password: unlocked, and its sessions ended */
    static void setPassword(Connection c, long userId, String password) throws SQLException {
        passwordOk(password);
        byte[] salt = new byte[16];
        RANDOM.nextBytes(salt);
        Db.exec(c, "update bk_user set pw_hash = ?, pw_salt = ?, pw_iter = ?, failed = 0 where id = ?",
                pbkdf2(password, salt, ITERATIONS), salt, ITERATIONS, userId);
        Db.exec(c, "update bk_session set revoked = 'Y' where user_id = ?", userId);
    }

    /** the token of a login (committed, a wrong password too: its count) */
    static Map<String, Object> login(Connection c, String username, String password, String client) throws SQLException {
        String u = username == null ? "" : username.trim().toLowerCase();
        Object[] row = null;
        try (var st = c.prepareStatement("select id, full_name, role, pw_hash, pw_salt, pw_iter, failed, active "
                + "from bk_user where username = ? for update")) {
            st.setString(1, u);
            try (var rs = st.executeQuery()) {
                if (rs.next()) {
                    row = new Object[]{rs.getLong(1), rs.getString(2), rs.getString(3), rs.getBytes(4), rs.getBytes(5),
                            rs.getInt(6), rs.getInt(7), rs.getString(8)};
                }
            }
        }
        if (row == null) {
            pbkdf2(password == null ? "" : password, new byte[16], ITERATIONS);     // (the same time)
            throw new Http.Fail(401, "bad_login", "Λάθος όνομα ή κωδικός");
        }
        long id = (Long) row[0];
        if ((Integer) row[6] >= MAX_FAILED) {
            c.rollback();
            throw new Http.Fail(423, "locked", "Ο χρήστης κλειδώθηκε μετά από " + MAX_FAILED
                    + " λάθος κωδικούς: τον ξεκλειδώνει ένας ADMIN");
        }
        byte[] h = pbkdf2(password == null ? "" : password, (byte[]) row[4], (Integer) row[5]);
        if (!MessageDigest.isEqual(h, (byte[]) row[3]) || !"Y".equals(row[7])) {
            Db.exec(c, "update bk_user set failed = failed + 1 where id = ?", id);
            c.commit();
            throw new Http.Fail(401, "bad_login", "Λάθος όνομα ή κωδικός");
        }
        byte[] t = new byte[32];
        RANDOM.nextBytes(t);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(t);
        Db.exec(c, "update bk_user set failed = 0 where id = ?", id);
        Db.exec(c, "delete from bk_session where expires_at < sysdate - 30");
        Db.exec(c, "insert into bk_session (token_hash, user_id, client, expires_at) values (?, ?, ?, sysdate + 12 / 24)",
                sha256(token), id, client == null ? null : client.substring(0, Math.min(60, client.length())));
        c.commit();
        return Map.of("token", token, "username", u, "full_name", row[1], "role", row[2]);
    }

    /** who calls, from its token; null: no session */
    static User check(Connection c, String token) throws SQLException {
        if (token == null || token.isBlank()) {
            return null;
        }
        Map<String, Object> r = Db.row(c, "select u.id, u.username, u.full_name, u.role from bk_session s "
                + "join bk_user u on u.id = s.user_id where s.token_hash = ? and s.revoked = 'N' "
                + "and s.expires_at > sysdate and u.active = 'Y' and u.failed < ?", sha256(token), MAX_FAILED);
        return r == null ? null : new User(((Number) r.get("id")).longValue(), (String) r.get("username"),
                (String) r.get("full_name"), (String) r.get("role"));
    }

    static void logout(Connection c, String token) throws SQLException {
        Db.exec(c, "update bk_session set revoked = 'Y' where token_hash = ?", sha256(token));
    }
}
