#!/bin/bash
# Jeden HTTP request na web v CGI rezimu (PWE/pwe.fcgi bez FastCGI socketu), spusteny v kontejneru
# s Perl zavislostmi enginu (koren repozitare v /PWE, engine v /PWE/PWE = PWE_CONF_pwe_core).
# Vypise HTTP hlavicky + telo odpovedi; log enginu jde na STDERR.
#
#   PWE/tools/pwe-cgi.sh <web> ['page=default&func=default'] [volby]        (make cgi WEB=... Q=...)
#
#   PWE/tools/pwe-cgi.sh mujweb.web
#   PWE/tools/pwe-cgi.sh mujweb.web 'page=kontakt&func=default'
#   PWE/tools/pwe-cgi.sh mujweb.web --post 'page=kontakt&func=form&email=a@b.cz'   # POST: page/func patri do tela!
#   PWE/tools/pwe-cgi.sh mujweb.web --script /assets/javascript/pwe.js            # staticky soubor (z enginu)
#   PWE/tools/pwe-cgi.sh mujweb.web 'page=default' --cookie 'PWE-MUJWEB-WEB=C0...' --loglevel 4
#
# Volby: --post DATA   telo POST (application/x-www-form-urlencoded)
#        --cookie C    hlavicka Cookie (session)
#        --script S    SCRIPT_FILENAME (vychozi /pwe.fcgi; cesta /assets/... vrati soubor)
#        --loglevel N  PWE_CONF_log_loglevel (0-4, vychozi 1)
#        Kazda volba vyzaduje hodnotu (i prazdnou: --post ''); chybejici hodnota = chyba, kod 2.
#
# Pokud bezi compose stack projektu pwe (sit pwe_default) s TIMTO webem, kontejner se k jeho siti pripoji
# a web s databazi dosahne na sluzby mariadb/mysql/postgres (prihlaseni z DB_NAME/DB_USER/DB_USER_PASSWORD,
# vychozi pwe/pwe/pwe). Ktery web ve stacku bezi, se pozna z pracovniho adresare sluzby fcgi (nebo
# debugger): /PWE/webapps/<web>. Bezi-li stack JINEHO webu, k jeho siti ani databazi se skript nepripoji -
# engine by do cizi databaze zapsal migrace tohoto webu (conf/<db>.dbversion) a poskodil jeji schema:
#   - web s conf/database.conf (pouziva databazi): skonci chybou, kod 2 (spust make run WEB=<web>),
#   - web bez conf/database.conf: request probehne bez site stacku, s upozornenim [pwe-cgi].
# Kdyz sit existuje, ale sluzba fcgi ani debugger nebezi, web stacku urcit nejde a request bezi take bez site.
#
# Image: vychozi je image nastroju ghcr.io/kukam/pwe-debugger:<aktualni vetev gitu> (pwe_tool_image
# z PWE/tools/lib/images.sh; ma ovladace vsech tri databazi). Zmena: PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG,
# nebo PWE_TEST_IMAGE = uplne prepsani (cele jmeno vcetne tagu). Image sestavi make images.
# Entrypoint image se obchazi (--entrypoint bash): pracovni adresare webu zaklada tento skript a
# conf/database.conf se nemeni (plati ten z pracovni kopie).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"
IMAGE="$(pwe_tool_image)"

APP="${1:?Pouziti: PWE/tools/pwe-cgi.sh <web> ['page=X&func=Y'] [--post DATA] [--cookie C] [--script S] [--loglevel N]}"
shift
APP="${APP#webapps/}"
APP="${APP%/}"
[ -f "$ROOT/webapps/$APP/conf/web.conf" ] || { echo "Web webapps/$APP neexistuje (conf/web.conf)" >&2; exit 2; }

# need_value <volba a zbyle argumenty> - volba musi mit hodnotu (jinak by "shift 2" pod set -e
# ukoncil skript kodem 1 bez jedine hlasky).
need_value() {
    [ $# -ge 2 ] || { echo "Volba $1 vyzaduje hodnotu (volby: --post DATA, --cookie C, --script S, --loglevel N)" >&2; exit 2; }
}

QS="page=default&func=default"
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then QS="$1"; shift; fi
POST=""; COOKIE=""; SCRIPT="/pwe.fcgi"; LOGLEVEL=1; METHOD=GET
while [ $# -gt 0 ]; do
    case "$1" in
        --post)     need_value "$@"; POST="$2"; METHOD=POST; shift 2 ;;
        --cookie)   need_value "$@"; COOKIE="$2"; shift 2 ;;
        --script)   need_value "$@"; SCRIPT="$2"; shift 2 ;;
        --loglevel) need_value "$@"; LOGLEVEL="$2"; shift 2 ;;
        *) echo "Neznama volba $1 (volby: --post DATA, --cookie C, --script S, --loglevel N)" >&2; exit 2 ;;
    esac
done
POST_LEN=$(printf '%s' "$POST" | wc -c | tr -d ' ')

# Sit a databaze compose stacku jen tehdy, kdyz stack patri tomuto webu (viz hlavicka).
NET=()
DBENV=()
if docker network inspect pwe_default >/dev/null 2>&1; then
    CID="$(docker ps -q --filter label=com.docker.compose.project=pwe --filter label=com.docker.compose.service=fcgi 2>/dev/null | head -1)"
    [ -n "$CID" ] || CID="$(docker ps -q --filter label=com.docker.compose.project=pwe --filter label=com.docker.compose.service=debugger 2>/dev/null | head -1)"
    RUNNING=""
    [ -n "$CID" ] && RUNNING="$(docker inspect --format '{{.Config.WorkingDir}}' "$CID" 2>/dev/null || true)"
    RUNNING="${RUNNING%/}"
    RUNNING="${RUNNING##*/}"
    if [ -z "$RUNNING" ]; then
        echo "[pwe-cgi] sit pwe_default existuje, ale sluzba fcgi ani debugger nebezi - web stacku nelze urcit, request pobezi bez site stacku (spusteni: make run WEB=$APP)" >&2
    elif [ "$RUNNING" = "$APP" ]; then
        NET=(--network pwe_default)
        DBENV=(-e "PWE_CONF_dbi_db1_database=${DB_NAME:-pwe}" -e "PWE_CONF_dbi_db1_login=${DB_USER:-pwe}" -e "PWE_CONF_dbi_db1_password=${DB_USER_PASSWORD:-pwe}")
    elif [ -e "$ROOT/webapps/$APP/conf/database.conf" ] || [ -L "$ROOT/webapps/$APP/conf/database.conf" ]; then
        echo "[pwe-cgi] bezi stack webu $RUNNING, ne $APP - k jeho siti a databazi se nepripojuji (zapsaly by se do ni migrace webu $APP). Web $APP pouziva databazi (conf/database.conf), spust jeho stack: make run WEB=$APP" >&2
        exit 2
    else
        echo "[pwe-cgi] bezi stack webu $RUNNING, ne $APP - k jeho siti a databazi se nepripojuji, request pobezi bez site stacku" >&2
    fi
fi
USERARG=()
[ "$(uname -s)" = "Linux" ] && USERARG=(--user "$(id -u):$(id -g)")
pwe_image_missing_hint "$IMAGE" pwe-cgi

printf '%s' "$POST" | docker run --rm -i --entrypoint bash "${NET[@]}" "${USERARG[@]}" \
    -v "$ROOT":/PWE -w "/PWE/webapps/$APP" \
    -e "QS=$QS" -e "METHOD=$METHOD" -e "SCRIPT=$SCRIPT" -e "COOKIE=$COOKIE" -e "LOGLEVEL=$LOGLEVEL" -e "POST_LEN=$POST_LEN" \
    "${DBENV[@]}" "$IMAGE" -c '
        mkdir -p ramdisk/templates sessions uploadfile log
        DB=$(env | grep "^PWE_CONF_dbi_" || true)
        EXTRA=()
        [ -n "$COOKIE" ] && EXTRA+=("HTTP_COOKIE=$COOKIE")
        if [ "$METHOD" = "POST" ]; then EXTRA+=("CONTENT_TYPE=application/x-www-form-urlencoded" "CONTENT_LENGTH=$POST_LEN"); fi
        exec env -i PATH="$PATH" PERL5LIB="$PWD:/PWE/PWE" PWE_CONF_pwe_home="$PWD/" PWE_CONF_pwe_core=/PWE/PWE/ \
            PWE_CONF_log_loglevel="$LOGLEVEL" PWE_CONF_log_logout=STDERR \
            SCRIPT_FILENAME="$SCRIPT" REQUEST_METHOD="$METHOD" QUERY_STRING="$QS" \
            REMOTE_ADDR=127.0.0.1 HTTP_HOST=localhost SERVER_NAME=localhost HTTP_USER_AGENT=pwe-cgi \
            "${EXTRA[@]}" $DB perl /PWE/PWE/pwe.fcgi'
