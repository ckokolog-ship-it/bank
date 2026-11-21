# bk-api

Η υπηρεσία REST και οι σελίδες της τράπεζας: Java 17 ή νεότερη, με τον `HttpServer` του JDK και JDBC (ojdbc11, UCP). Οδηγίες: [docs/ODIGIES_WEB.md](../docs/ODIGIES_WEB.md).

```
./mvnw -q -B package -DskipTests         το jar: target/bk-api.jar
sudo ./install_service.sh                 ως υπηρεσία στο Linux (systemd), θύρα 8091
```
