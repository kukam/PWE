#!/bin/bash
# Spusti web z webapps/ pres docker compose (engine z adresare PWE/ pracovni kopie, behove prostredi
# z image ghcr.io/kukam/pwe-<profil>:<vetev>, ladici sluzba z ghcr.io/kukam/pwe-debugger:<vetev>).
#
#   PWE/tools/run-webapp.sh <web> [profil] [prikaz compose a argumenty]      (make run WEB=... [PROFILE=...])
#
#   PWE/tools/run-webapp.sh mujweb.web                    # profil podle conf (mariadb.conf -> mariadb, jinak static), 'up'
#   PWE/tools/run-webapp.sh mujweb.web static up -d       # na pozadi
#   PWE/tools/run-webapp.sh eshop.web mariadb logs -f fcgi
#   PWE/tools/run-webapp.sh eshop.web mariadb restart fcgi   # po zmene .pm souboru
#   PWE/tools/run-webapp.sh eshop.web mariadb down -v     # zastavit a smazat DB volume
#   PWE_IMAGE_TAG=master PWE/tools/run-webapp.sh mujweb.web   # image jine vetve nez aktualni
#
# Profil: static | mariadb | mysql | postgres (= COMPOSE_PROFILES, vybere DB a image pwe-<profil>).
# Prvni argument za webem je profil, nebo uz prikaz docker compose (up, down, logs, restart, ps, config,
# exec, ...; pripadne globalni volba compose zacinajici pomlckou). Cokoli jineho - typicky preklep
# v profilu (PROFILE=oracle, PROFILE=Mariadb) - skonci chybou "Neznamy profil nebo prikaz", kod 2,
# misto aby se predalo docker compose jako prikaz.
# Pri vytvareni kontejneru (up, run, create) skript varuje "[run-webapp] POZOR", kdyz profil neodpovida webu:
#   - web ma conf/mariadb.conf, mysql.conf nebo postgres.conf a profil je static (pobezi bez databaze),
#   - web nema conf/<profil>.conf a profil je databazovy (databaze se spusti, web ji ale nepouzije).
# Web bezi na http://127.0.0.1:7778/ (nginx -> 3x fcgi). Koren repozitare se mountuje do /PWE, takze bezi
# aktualni pracovni kopie enginu (/PWE/PWE) i webu (/PWE/webapps/<web>); image kod enginu neobsahuji.
#
# Image: skript exportuje pro docker-compose.yml PWE_IMAGE_REGISTRY (vychozi ghcr.io/kukam) a
# PWE_IMAGE_TAG (vychozi = aktualni vetev gitu prevedena na tag) - obe z PWE/tools/lib/images.sh, tedy
# stejne image, jake sestavi make images a jake pouzivaji make test / check / cgi. Prime volani
# "docker compose up" bez techto promennych bere tag master.
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"
cd "$ROOT"

APP="${1:?Pouziti: PWE/tools/run-webapp.sh <web> [static|mariadb|mysql|postgres] [compose prikaz]}"
shift
APP="${APP#webapps/}"
APP="${APP%/}"
[ -f "webapps/$APP/conf/web.conf" ] || { echo "Web webapps/$APP neexistuje (conf/web.conf)" >&2; exit 2; }

PROFILE=""
if [ $# -gt 0 ]; then
    case "$1" in
        static | mariadb | mysql | postgres) PROFILE="$1"; shift ;;
    esac
fi
# Co zbylo, musi zacinat prikazem docker compose (nebo jeho globalni volbou) - jinak je to neznamy profil.
if [ $# -gt 0 ]; then
    case "$1" in
        -*) ;;
        alpha | attach | bridge | build | commit | config | cp | create | down | events | exec | export | help \
            | images | kill | logs | ls | pause | port | ps | publish | pull | push | restart | rm | run | scale \
            | start | stats | stop | top | unpause | up | version | volumes | wait | watch) ;;
        *)
            echo "Neznamy profil nebo prikaz '$1' (profily: static | mariadb | mysql | postgres; prikazy docker compose: up, down, logs, restart, ps, config, exec, ...)" >&2
            exit 2
            ;;
    esac
fi
if [ -z "$PROFILE" ]; then
    if [ -L "webapps/$APP/conf/database.conf" ]; then
        PROFILE="$(basename "$(readlink "webapps/$APP/conf/database.conf")" .conf)"
    elif [ -f "webapps/$APP/conf/mariadb.conf" ]; then PROFILE=mariadb
    elif [ -f "webapps/$APP/conf/mysql.conf" ]; then PROFILE=mysql
    elif [ -f "webapps/$APP/conf/postgres.conf" ]; then PROFILE=postgres
    else PROFILE=static
    fi
fi
case "$PROFILE" in
    static | mariadb | mysql | postgres) ;;
    *) echo "Neznamy profil $PROFILE (conf/database.conf webu $APP ukazuje na $PROFILE.conf; profily: static | mariadb | mysql | postgres)" >&2; exit 2 ;;
esac

mkdir -p "webapps/$APP/ramdisk/templates" "webapps/$APP/sessions" "webapps/$APP/uploadfile" "webapps/$APP/log"

[ $# -eq 0 ] && set -- up --remove-orphans

export PWE_WEBAPP="$APP"
export COMPOSE_PROFILES="$PROFILE"
PWE_IMAGE_REGISTRY="$(pwe_image_registry)"
PWE_IMAGE_TAG="$(pwe_image_tag)"
export PWE_IMAGE_REGISTRY PWE_IMAGE_TAG
echo "[run-webapp] web=$APP profil=$PROFILE registr=$PWE_IMAGE_REGISTRY tag=$PWE_IMAGE_TAG -> docker compose $*" >&2
# Varovani a rada jen u prikazu, ktere vytvareji kontejnery (image musi existovat, profil rozhoduje
# o databazi), ne u logs / restart / down.
case "$1" in
    up | run | create)
        DB_CONFS=""
        for db in mariadb mysql postgres; do
            if [ -f "webapps/$APP/conf/$db.conf" ]; then DB_CONFS="$DB_CONFS conf/$db.conf"; fi
        done
        if [ "$PROFILE" = static ]; then
            if [ -n "$DB_CONFS" ]; then
                echo "[run-webapp] POZOR: web $APP ma${DB_CONFS}, ale profil je static - pobezi bez databaze (image pwe-static nema databazove ovladace). Profil s databazi: PROFILE=mariadb | mysql | postgres" >&2
            fi
        elif [ ! -f "webapps/$APP/conf/$PROFILE.conf" ]; then
            echo "[run-webapp] POZOR: web $APP nema conf/$PROFILE.conf, ale profil je $PROFILE - databaze se spusti, web ji ale nepouzije (nastaveni profilu z docker-compose/docker-compose_$PROFILE.env s databazi pocita). Web bez databaze spoustej s profilem static" >&2
        fi
        for img in "pwe-$PROFILE" pwe-debugger; do
            pwe_image_missing_hint "$(pwe_image "$img")" run-webapp
        done
        ;;
esac
exec docker compose "$@"
