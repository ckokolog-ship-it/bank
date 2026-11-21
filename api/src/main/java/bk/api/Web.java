package bk.api;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Map;

/**
 * The pages of the bank (resources/web): index.html, app.js, app.css, at http://host:8091/web/ (they speak to
 * /api/ with the token of their login); the ATM: atm.html, atm.js, atm.css at /atm/ (to /api/atm/, a card and
 * its PIN). Only these files, only GET; a Content-Security-Policy of this server
 * only.
 */
final class Web {
    private static final Map<String, String> FILES = Map.of(
            "index.html", "text/html; charset=utf-8",
            "app.js", "text/javascript; charset=utf-8",
            "app.css", "text/css; charset=utf-8",
            "atm.html", "text/html; charset=utf-8",
            "atm.js", "text/javascript; charset=utf-8",
            "atm.css", "text/css; charset=utf-8");
    private static final String CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            + "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";

    private Web() {
    }

    static void register(HttpServer server) {
        server.createContext("/", Web::handle);
    }

    private static void handle(HttpExchange ex) throws IOException {
        try {
            String path = ex.getRequestURI().getPath();
            if (!"GET".equals(ex.getRequestMethod()) && !"HEAD".equals(ex.getRequestMethod())) {
                ex.getResponseHeaders().set("Allow", "GET");
                ex.sendResponseHeaders(405, -1);
                return;
            }
            if ("/".equals(path) || "/web".equals(path)) {
                ex.getResponseHeaders().set("Location", "/web/");
                ex.sendResponseHeaders(302, -1);
                return;
            }
            if ("/atm".equals(path)) {
                ex.getResponseHeaders().set("Location", "/atm/");
                ex.sendResponseHeaders(302, -1);
                return;
            }
            String name = path.startsWith("/web/") ? path.substring("/web/".length())
                    : path.startsWith("/atm/") ? path.substring("/atm/".length()) : null;
            if ("".equals(name)) {
                name = path.startsWith("/atm/") ? "atm.html" : "index.html";
            }
            if (name != null && path.startsWith("/atm/") != name.startsWith("atm.")) {
                name = null;                                     // (each page its own folder)
            }
            String type = name == null ? null : FILES.get(name);
            InputStream in = type == null ? null : Web.class.getResourceAsStream("/web/" + name);
            if (in == null) {
                byte[] b = "not found".getBytes(java.nio.charset.StandardCharsets.UTF_8);
                ex.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
                ex.sendResponseHeaders(404, b.length);
                try (OutputStream o = ex.getResponseBody()) {
                    o.write(b);
                }
                return;
            }
            byte[] b;
            try (in) {
                b = in.readAllBytes();
            }
            var h = ex.getResponseHeaders();
            h.set("Content-Type", type);
            h.set("Content-Security-Policy", CSP);
            h.set("X-Content-Type-Options", "nosniff");
            h.set("Referrer-Policy", "no-referrer");
            h.set("X-Frame-Options", "DENY");
            h.set("Cache-Control", "no-cache");
            if ("HEAD".equals(ex.getRequestMethod())) {
                ex.sendResponseHeaders(200, -1);
                return;
            }
            ex.sendResponseHeaders(200, b.length);
            try (OutputStream o = ex.getResponseBody()) {
                o.write(b);
            }
        } finally {
            ex.close();
        }
    }
}
