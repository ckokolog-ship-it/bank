package bk.api;

import oracle.ucp.jdbc.PoolDataSource;
import oracle.ucp.jdbc.PoolDataSourceFactory;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;

/** The database of the bank: a pool of connections (UCP), the queries with bind variables, the rows as maps. */
final class Db implements AutoCloseable {
    private final PoolDataSource pool;

    private Db(PoolDataSource pool) {
        this.pool = pool;
    }

    static Db fromEnvironment() throws SQLException {
        PoolDataSource p = PoolDataSourceFactory.getPoolDataSource();
        p.setConnectionFactoryClassName("oracle.jdbc.pool.OracleDataSource");
        p.setURL(Main.env("BK_DB_URL", "jdbc:oracle:thin:/@BK_DB"));
        Properties props = new Properties();
        String tns = System.getenv("BK_TNS_ADMIN");
        if (tns != null && !tns.isBlank()) {
            props.setProperty("oracle.net.tns_admin", tns);
            props.setProperty("oracle.net.wallet_location",
                    "(SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY="
                            + Main.env("BK_WALLET", tns + java.io.File.separator + "forms_wallet") + ")))");
        }
        String user = System.getenv("BK_DB_USER");
        if (user != null && !user.isBlank()) {
            p.setUser(user);
            p.setPassword(System.getenv("BK_DB_PASSWORD"));
        }
        p.setConnectionProperties(props);
        p.setInitialPoolSize(1);
        p.setMinPoolSize(1);
        p.setMaxPoolSize(8);
        p.setValidateConnectionOnBorrow(true);
        return new Db(p);
    }

    Connection connection() throws SQLException {
        Connection c = pool.getConnection();
        c.setAutoCommit(false);
        return c;
    }

    /** the rows of a query: column (lower case) to value; numbers BigDecimal, dates text (ISO) */
    static List<Map<String, Object>> rows(Connection c, String sql, Object... binds) throws SQLException {
        try (PreparedStatement st = c.prepareStatement(sql)) {
            bind(st, 1, binds);
            try (ResultSet rs = st.executeQuery()) {
                ResultSetMetaData md = rs.getMetaData();
                List<Map<String, Object>> out = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    for (int k = 1; k <= md.getColumnCount(); k++) {
                        row.put(md.getColumnLabel(k).toLowerCase(Locale.ROOT), value(rs, k, md.getColumnType(k)));
                    }
                    out.add(row);
                }
                return out;
            }
        }
    }

    /** a block of PL/SQL with its binds (in only) */
    static void exec(Connection c, String plsql, Object... binds) throws SQLException {
        try (java.sql.CallableStatement st = c.prepareCall(plsql)) {
            bind(st, 1, binds);
            st.execute();
        }
    }

    /** a function of PL/SQL that gives a number back: fn(c, "bk_core.deposit(p_account_id => ?, ...)", ...) */
    static long fn(Connection c, String call, Object... binds) throws SQLException {
        try (java.sql.CallableStatement st = c.prepareCall("begin ? := " + call + "; end;")) {
            st.registerOutParameter(1, java.sql.Types.NUMERIC);
            bind(st, 2, binds);
            st.execute();
            return st.getLong(1);
        }
    }

    /** the first row of a query (null: none) */
    static Map<String, Object> row(Connection c, String sql, Object... binds) throws SQLException {
        List<Map<String, Object>> r = rows(c, sql, binds);
        return r.isEmpty() ? null : r.get(0);
    }

    private static void bind(PreparedStatement st, int from, Object[] binds) throws SQLException {
        for (int i = 0; i < binds.length; i++) {
            Object b = binds[i];
            if (b == null) {
                st.setNull(from + i, java.sql.Types.VARCHAR);
            } else if (b instanceof java.time.LocalDate d) {
                st.setDate(from + i, Date.valueOf(d));
            } else if (b instanceof byte[] raw) {
                st.setBytes(from + i, raw);
            } else {
                st.setObject(from + i, b);
            }
        }
    }

    private static Object value(ResultSet rs, int k, int type) throws SQLException {
        switch (type) {
            case java.sql.Types.NUMERIC, java.sql.Types.DECIMAL, java.sql.Types.INTEGER, java.sql.Types.BIGINT -> {
                BigDecimal n = rs.getBigDecimal(k);
                if (n == null) {
                    return null;
                }
                n = n.stripTrailingZeros();
                return n.scale() < 0 ? n.setScale(0) : n;       // 100, not 1E+2
            }
            case java.sql.Types.DATE, java.sql.Types.TIMESTAMP -> {
                Timestamp t = rs.getTimestamp(k);
                if (t == null) {
                    return null;
                }
                String s = t.toLocalDateTime().toString();
                return s.endsWith("T00:00") ? s.substring(0, 10) : s;
            }
            default -> {
                return rs.getString(k);
            }
        }
    }

    @Override
    public void close() {
        // the pool closes with the process (UCP has no close of its own data source)
    }
}
