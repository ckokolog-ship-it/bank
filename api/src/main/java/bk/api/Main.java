package bk.api;

import com.sun.net.httpserver.HttpServer;

import java.io.Console;
import java.net.InetSocketAddress;
import java.sql.Connection;
import java.util.concurrent.Executors;

/**
 * bk-api: the REST service and the pages of the bank. Its settings come from the environment (no password in
 * a file of the repo or in an argument):
 *
 * <pre>
 *   BK_API_BIND      the address it listens on (127.0.0.1: only this computer; 0.0.0.0: the network)
 *   BK_API_PORT      its port (8091)
 *   BK_DB_URL        the database (jdbc:oracle:thin:/@BK_DB: the alias of a wallet; or
 *                    jdbc:oracle:thin:@//localhost:1521/FREEPDB1 with BK_DB_USER and BK_DB_PASSWORD)
 *   BK_TNS_ADMIN     the folder of tnsnames.ora and sqlnet.ora; BK_WALLET the folder of the wallet
 *   BK_DB_USER, BK_DB_PASSWORD   without a wallet: user and password
 * </pre>
 *
 * The users of the pages (BK_USER), from the command line, the password asked (twice, not shown):
 *
 * <pre>
 *   java -jar bk-api.jar --add-user admin ADMIN "Όνομα Επώνυμο"
 *   java -jar bk-api.jar --password admin          (a new password, and unlocked)
 * </pre>
 */
public final class Main {
    private Main() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            System.exit(command(args));
        }
        String bind = env("BK_API_BIND", "127.0.0.1");
        int port = Integer.parseInt(env("BK_API_PORT", "8091"));
        Db db = Db.fromEnvironment();
        HttpServer server = HttpServer.create(new InetSocketAddress(bind, port), 64);
        new Api(db).register(server);
        Web.register(server);
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> server.stop(1)));
        System.out.println("== bk-api on http://" + bind + ":" + port + "/  (the pages; the REST: /api/)");
    }

    private static int command(String[] a) throws Exception {
        boolean add = "--add-user".equals(a[0]) && a.length >= 3;
        boolean reset = "--password".equals(a[0]) && a.length == 2;
        if (!add && !reset) {
            System.err.println("java -jar bk-api.jar --add-user <username> TELLER|MANAGER|ADMIN [\"full name\"]");
            System.err.println("java -jar bk-api.jar --password <username>");
            return 2;
        }
        Console con = System.console();
        if (con == null) {
            System.err.println("== a terminal is needed (the password is asked)");
            return 2;
        }
        char[] p1 = con.readPassword("Κωδικός του %s: ", a[1]);
        char[] p2 = con.readPassword("Ξανά: ");
        if (p1 == null || !java.util.Arrays.equals(p1, p2)) {
            System.err.println("== not the same");
            return 1;
        }
        Db db = Db.fromEnvironment();
        try (Connection c = db.connection()) {
            if (add) {
                long id = Auth.createUser(c, a[1], a.length > 3 ? a[3] : a[1], a[2], new String(p1));
                System.out.println("== user " + a[1] + " (" + a[2].toUpperCase() + "): " + id);
            } else {
                Auth.setPassword(c, Auth.userId(c, a[1]), new String(p1));
                System.out.println("== the password of " + a[1] + ": changed, unlocked");
            }
            c.commit();
            return 0;
        } catch (Http.Fail f) {
            System.err.println("== " + f.getMessage());
            return 1;
        }
    }

    static String env(String name, String fallback) {
        String v = System.getenv(name);
        return v == null || v.isBlank() ? fallback : v;
    }
}
