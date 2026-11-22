#!/bin/bash
# install_service.sh -- the REST service and the pages of the bank (bk-api.jar) as a service of systemd on
# Linux (forms1, Oracle Linux 9, as the mm-api of the mini market): it starts with the server, after the
# database, and again by itself if it stops. As root, from the checkout of the repo (its owner: oracle):
#
#   sudo ./install_service.sh                     install, or update (the jar built again: after a git pull)
#   sudo ./install_service.sh --port 8091 --bind 0.0.0.0
#   sudo ./install_service.sh --no-build          the jar of target/ as it is
#   sudo ./install_service.sh --password          the password of the user BANK again (asked)
#   sudo ./install_service.sh --add-user admin ADMIN "Όνομα Επώνυμο"    a user of the pages (its password asked)
#   sudo ./install_service.sh --card-pins [--same] [--all]   a PIN to the cards without one (the demo: all of them):
#                                                 a new one each (a list: card, account, holder, PIN), or --same:
#                                                 one PIN to all (asked); --all: every card, a new PIN
#   ./install_service.sh --status                 the service, and /api/health
#   sudo ./install_service.sh --uninstall
#
# The database: BK_DB_URL (jdbc:oracle:thin:@//localhost:1521/FREEPDB1), the user BANK, its password asked
# once (not shown) and kept in /etc/bk-api.env (root only, 600: systemd reads it; never in the repo). The
# service: bk-api (systemctl status bk-api; its log: journalctl -u bk-api), run as oracle, started by
# /u01/app/oracle/scripts/bk-api.sh (SELinux: bin_t, as the mm-api). Its folder: /u01/app/oracle/bk-api.
# --bind 0.0.0.0 (the default): the network too, plain HTTP with the login of the pages: only a network you
# trust. The build: ./mvnw as oracle (the first time it may download Maven and the driver: the internet).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=bk-api
PORT=8091
BIND=0.0.0.0
BUILD=1
MODE=install
OWNER=${BK_OWNER:-oracle}
HOME_DIR=${BK_API_HOME:-/u01/app/oracle/bk-api}
UNITS=${BK_UNITS:-/etc/systemd/system}
SCRIPTS=${BK_SCRIPTS:-/u01/app/oracle/scripts}
ENVF=${BK_ENV_FILE:-/etc/bk-api.env}
DB_URL=${BK_DB_URL:-jdbc:oracle:thin:@//localhost:1521/FREEPDB1}
ADD=()
while [ $# -gt 0 ]; do
  case $1 in
    --port) PORT=${2:?--port <n>}; shift ;;
    --bind) BIND=${2:?--bind <address>}; shift ;;
    --no-build) BUILD= ;;
    --status) MODE=status ;;
    --password) MODE=password ;;
    --add-user) MODE=add-user; shift; ADD=("$@"); break ;;
    --card-pins) MODE=card-pins; shift; ADD=("$@"); break ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "== unknown: $1 (--help)"; exit 2 ;;
  esac
  shift
done
die() { echo "== $*" >&2; exit 1; }

health() {
  local k r
  for k in $(seq 30); do
    if r=$(curl -fs --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/api/health"); then
      echo "== http://127.0.0.1:$PORT/api/health: $r"; return 0
    fi
    [ "$k" = 1 ] && echo "== waiting for the service (some seconds)"
    sleep 2
  done
  echo "== no answer on port $PORT yet: journalctl -u $NAME -n 50"
  return 1
}

# the password of BANK, asked (not shown), into the file of the environment of the service
ask_password() {
  local p1 p2
  read -rsp "Ο κωδικός του χρήστη BANK της βάσης: " p1; echo
  read -rsp "Ξανά: " p2; echo
  [ -n "$p1" ] && [ "$p1" = "$p2" ] || die "empty, or not the same"
  ( umask 077
    printf 'BK_DB_URL=%s\nBK_DB_USER=bank\nBK_DB_PASSWORD=%s\n' "$DB_URL" "$p1" > "$ENVF" )
  chown root:root "$ENVF"; chmod 600 "$ENVF"
  echo "== $ENVF (root only)"
}

# the JDK: 17 or later (the JDK 21 of the forms)
find_jdk() {
  JDK=${JAVA_HOME:-}
  [ -x "${JDK:-}/bin/java" ] || JDK=$(find /usr/lib/jvm -maxdepth 1 -name "jdk-21*" 2>/dev/null | sort | tail -1)
  [ -x "${JDK:-}/bin/java" ] || JDK=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
  [ -x "$JDK/bin/java" ] || die "no Java: JAVA_HOME=<a JDK 17 or later>"
}

if [ "$MODE" = status ]; then
  systemctl status $NAME --no-pager -n 5 2>/dev/null || echo "== the service $NAME is not installed"
  systemctl is-active --quiet $NAME && health
  exit 0
fi
[ "$(id -u)" = 0 ] || die "as root: sudo $0 $*"

if [ "$MODE" = uninstall ]; then
  systemctl disable --now $NAME 2>/dev/null
  rm -f "$UNITS/$NAME.service" "$SCRIPTS/$NAME.sh"
  systemctl daemon-reload
  if systemctl is-active --quiet firewalld; then
    firewall-cmd -q --permanent --remove-port="$PORT/tcp" 2>/dev/null && firewall-cmd -q --reload
  fi
  echo "== the service $NAME removed (its folder stays: $HOME_DIR; the password: $ENVF, rm it if not needed)"
  exit 0
fi

if [ "$MODE" = password ]; then
  ask_password
  systemctl is-active --quiet $NAME && systemctl restart $NAME && health
  exit 0
fi

if [ "$MODE" = add-user ] || [ "$MODE" = card-pins ]; then
  [ "$MODE" = card-pins ] || [ ${#ADD[@]} -ge 2 ] || die "--add-user <username> TELLER|MANAGER|ADMIN [\"full name\"]"
  [ -f "$ENVF" ] || die "no $ENVF: sudo $0 first (the install)"
  [ -f "$HOME_DIR/bk-api.jar" ] || die "no $HOME_DIR/bk-api.jar: sudo $0 first (the install)"
  find_jdk
  set -a; . "$ENVF"; set +a          # (the name: UTF-8, whatever the locale of the terminal)
  exec runuser -u "$OWNER" -- env LC_ALL=C.UTF-8 BK_DB_URL="$BK_DB_URL" BK_DB_USER="$BK_DB_USER" BK_DB_PASSWORD="$BK_DB_PASSWORD" \
    "$JDK/bin/java" -jar "$HOME_DIR/bk-api.jar" "--$MODE" "${ADD[@]}"
fi

find_jdk
[ -f "$ENVF" ] || ask_password

JAR=$HERE/target/bk-api.jar
if [ -n "$BUILD" ]; then
  echo "== mvnw package, as $OWNER (the jar of the service)"
  runuser -u "$OWNER" -- env JAVA_HOME="$JDK" bash -c "cd '$HERE' && ./mvnw -q -B clean package -DskipTests" ||
    die "mvnw package failed (the messages above; the folder $HERE must be $OWNER's)"
fi
[ -f "$JAR" ] || die "no $JAR (without --no-build: it is built)"

# the service stopped while its jar changes; then the jar into its folder
systemctl is-active --quiet $NAME && { echo "== stop $NAME"; systemctl stop $NAME; }
GROUP=$(id -gn "$OWNER")
install -d -o "$OWNER" -g "$GROUP" -m 750 "$HOME_DIR"
install -o "$OWNER" -g "$GROUP" -m 640 "$JAR" "$HOME_DIR/bk-api.jar" || die "the jar not copied into $HOME_DIR"
runuser -u "$OWNER" -- test -r "$HOME_DIR/bk-api.jar" || die "$OWNER cannot read $HOME_DIR/bk-api.jar (ls -la $HOME_DIR)"
# the start through a script in the folder of the scripts of systemd (SELinux: bin_t there): java started by
# systemd directly stays in the domain of systemd, which may not read the jar under /u01
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/$NAME.sh" <<END
#!/bin/bash
# made by install_service.sh (bank): the start of the service $NAME
exec "$JDK/bin/java" -Xmx384m -jar "$HOME_DIR/bk-api.jar"
END
chmod 755 "$SCRIPTS/$NAME.sh"
command -v restorecon > /dev/null && restorecon -R "$SCRIPTS" "$HOME_DIR" 2> /dev/null
cat > "$UNITS/$NAME.service" <<END
# made by install_service.sh: run it again to change it
[Unit]
Description=Bank API (bk-api): the REST service and the pages, port $PORT ($BIND)
After=network-online.target oracle-free-26ai.service
Wants=network-online.target oracle-free-26ai.service
StartLimitIntervalSec=10min
StartLimitBurst=5

[Service]
User=$OWNER
WorkingDirectory=$HOME_DIR
EnvironmentFile=$ENVF
Environment=JAVA_HOME=$JDK
Environment=BK_API_PORT=$PORT
Environment=BK_API_BIND=$BIND
ExecStart=$SCRIPTS/$NAME.sh
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
END
systemctl daemon-reload
systemctl reset-failed $NAME 2> /dev/null
systemctl enable $NAME > /dev/null 2>&1
if [ "$BIND" != 127.0.0.1 ] && systemctl is-active --quiet firewalld; then
  firewall-cmd -q --permanent --add-port="$PORT/tcp" && firewall-cmd -q --reload && echo "== firewalld: $PORT/tcp open"
fi
systemctl start $NAME || die "the start failed: journalctl -u $NAME -n 50"
if health; then
  echo "== the service $NAME runs: http://$(hostname -f 2>/dev/null || hostname):$PORT/  (systemctl status $NAME)"
  echo "== a user of the pages, if none yet: sudo $0 --add-user admin ADMIN \"Όνομα Επώνυμο\""
else
  journalctl -u $NAME -n 15 --no-pager 2> /dev/null | sed 's/^/   /'
  if command -v ausearch > /dev/null && ausearch -m avc -ts recent 2> /dev/null | grep -q "$NAME\\|java"; then
    echo "== [!] SELinux refused something (ausearch -m avc -ts recent): ls -laZ $SCRIPTS $HOME_DIR"
  fi
  exit 1
fi
