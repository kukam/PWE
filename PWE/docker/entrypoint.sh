#!/bin/bash
# Entrypoint image PWE. Stage base (PWE/docker/Dockerfile) ho instaluje do /usr/local/bin/entrypoint.sh
# a dedi ho vsechny image z pwe-base odvozene: zavislostni image pwe-mariadb, pwe-mysql, pwe-postgres a
# pwe-debugger i image webu vcetne image vzorovych webu pwe-example-* (Dockerfile webu ENTRYPOINT
# nenastavuje a web zadnou vlastni kopii tohoto souboru nema).
#
# V adresari webu (aktualni adresar obsahuje conf/web.conf - WORKDIR image webu, working_dir sluzby
# v docker-compose.yml) pred spustenim prikazu:
#   1. podle PWE_PROFILE (mariadb | mysql | postgres) nasmeruje conf/database.conf -> <profil>.conf,
#      pokud conf/<profil>.conf existuje. Existujici symlink nahradi, bezny soubor conf/database.conf
#      (vlastni konfigurace webu) neprepisuje. S profilem static a bez PWE_PROFILE se nic nemeni.
#   2. vytvori pracovni adresare ramdisk/templates, sessions, uploadfile a log.
# Chyby zapisu se ignoruji: web namountovany jen pro cteni (read-only root FS) nesmi shodit start,
# engine si chybejici adresar ohlasi sam, az ho bude potrebovat.
#
# Start se NIKDY neprerusi. Kdyz ale PWE_PROFILE neodpovida stavu webu, vypise se na stderr jednoradkove
# varovani "[entrypoint] VAROVANI: ...":
#   - PWE_PROFILE je neprazdny a neni static | mariadb | mysql | postgres (preklep, velka pismena),
#   - databazovy profil a conf/<profil>.conf neexistuje,
#   - conf/database.conf se nepodarilo nasmerovat (conf/ jen pro cteni) a na profil neukazuje,
#   - profil static a v conf/ zustal symlink database.conf (engine by nacetl databazi jineho profilu),
#   - conf/database.conf ukazuje na konfiguraci profilu, ale image nema jeho ovladac databaze (napr.
#     -e PWE_PROFILE=postgres v image z pwe-mariadb, databazovy profil v image z pwe-base): engine by na to
#     prisel az pri pripojovani k databazi. Profily mariadb a mysql potrebuji DBD::mysql (pwe-mariadb,
#     pwe-mysql), postgres DBD::Pg (pwe-postgres); pwe-debugger ma oba, pwe-base zadny.
# Jedno varovani se profilu netyka:
#   - jako server (je nastavena FCGI_SOCKET_PATH) se spousti vzorovy web zapeceny v image - image
#     pwe-example-static | pwe-example-mariadb | pwe-example-mysql | pwe-example-postgres, nebo jiny image
#     sestaveny Dockerfilem vzoroveho webu. Vzorovy web je ukazka: kazdy navstevnik v nem ma skupinu admin
#     vcetne generatoru kodu pweCreator, do verejneho provozu nepatri. Rozpozna se bez zvlastni znacky
#     v image (image vzorovych webu stavi stejna sablona Dockerfile jako kazdy jiny web):
#       1. adresar webu se jmenuje example.web nebo example-db.web (jmena vzorovych webu repozitare enginu),
#       2. engine je zapeceny v image, neni to pracovni kopie repozitare: v koreni enginu (PWE_CONF_pwe_core,
#          vychozi /PWE/PWE) je pwe.fcgi a NENI tam docker/entrypoint.sh (zdroj tohoto skriptu). Dockerfile
#          webu adresar PWE/docker do image nekopiruje, pracovni kopie ho ma vzdy - ve vyvojovem stacku
#          (mount repozitare do /PWE) a v nastrojich se proto nevaruje.
#     Jednorazovy request v rezimu CGI (bez FCGI_SOCKET_PATH) a jine prikazy (perl -v, sh) varovani take
#     nevypisuji. Vlastni web pojmenovany example.web nebo example-db.web by varovani dostal take - tato
#     jmena patri vzorovym webum.
#
# Mimo adresar webu (napr. docker run pwe-base perl -v) jen spusti prikaz.

# Vypise varovani na stderr: vzdy jeden radek (ridici znaky v hodnotach se nahradi mezerou).
warn() {
    local msg="$*"
    msg="${msg//[[:cntrl:]]/ }"
    echo "[entrypoint] VAROVANI: ${msg}" >&2
    return 0
}

# Vypise soucasny stav conf/database.conf (do textu varovani).
database_conf_state() {
    local link="conf/database.conf"
    if [ -L "${link}" ]; then
        echo "conf/database.conf ukazuje na $(readlink "${link}")"
    elif [ -e "${link}" ]; then
        echo "conf/database.conf je bezny soubor"
    else
        echo "conf/database.conf neexistuje"
    fi
}

# Nasmeruje conf/database.conf na konfiguraci profilu. Symlink se vymenuje atomicky (novy symlink
# pod docasnym jmenem + prejmenovani), aby ostatni repliky sluzby fcgi nad stejnym adresarem
# nikdy nevidely stav bez conf/database.conf.
link_database_conf() {
    local target="${PWE_PROFILE}.conf"
    local link="conf/database.conf"
    local tmp

    if [ ! -L "${link}" ] && [ -e "${link}" ]; then
        return 0                                                 # bezny soubor: neprepisovat
    fi

    if [ ! -f "conf/${target}" ]; then
        warn "PWE_PROFILE=${PWE_PROFILE}, ale conf/${target} neexistuje - conf/database.conf se nenastavuje ($(database_conf_state))"
        return 0
    fi

    if [ -L "${link}" ] && [ "$(readlink "${link}")" = "${target}" ]; then
        return 0                                                 # uz ukazuje na spravny profil
    fi

    tmp="$(mktemp -u "conf/.database.conf.XXXXXX" 2>/dev/null)"
    if [ -n "${tmp}" ] && ln -s "${target}" "${tmp}" 2>/dev/null; then
        mv -Tf "${tmp}" "${link}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null
    fi

    # Zapis se nepovedl (conf/ jen pro cteni)? Varuje se jen tehdy, kdyz vysledny stav profilu
    # neodpovida - symlink mohla mezitim nastavit jina replika nad stejnym adresarem.
    if [ ! -L "${link}" ] || [ "$(readlink "${link}")" != "${target}" ]; then
        warn "conf/database.conf se nepodarilo nasmerovat na ${target} (PWE_PROFILE=${PWE_PROFILE}; neni adresar conf/ jen pro cteni?) - $(database_conf_state)"
    fi
    return 0
}

# Varuje, kdyz conf/database.conf ukazuje na konfiguraci profilu, ale image nema ovladac databaze, ktery
# engine pro profil pouziva (mariadb a mysql: DBD::mysql, postgres: DBD::Pg). Vlastni konfigurace webu
# (bezny soubor conf/database.conf) a symlink na jiny profil se nekontroluji - o tech profil nerozhoduje.
check_database_driver() {
    local link="conf/database.conf"
    local driver images

    if [ ! -L "${link}" ] || [ ! -f "${link}" ] || [ "$(readlink "${link}")" != "${PWE_PROFILE}.conf" ]; then
        return 0
    fi
    case "${PWE_PROFILE}" in
        postgres) driver="DBD::Pg";    images="pwe-postgres a pwe-debugger" ;;
        *)        driver="DBD::mysql"; images="pwe-mariadb, pwe-mysql a pwe-debugger" ;;
    esac
    # Bez prikazu perl se nekontroluje nic (prikaz kontejneru pak selze sam a srozumitelneji).
    if ! command -v perl >/dev/null 2>&1 || perl -M"${driver}" -e 1 >/dev/null 2>&1; then
        return 0
    fi
    warn "PWE_PROFILE=${PWE_PROFILE}, ale image nema ovladac databaze ${driver} (maji ho ${images}) - engine se k databazi nepripoji"
    return 0
}

# Varuje, kdyz se jako server spousti vzorovy web zapeceny v image (pwe-example-*; rozpoznani viz zahlavi):
# adresar webu example.web nebo example-db.web, engine v image a ne z pracovni kopie repozitare (v koreni
# enginu je pwe.fcgi a neni docker/entrypoint.sh) a start serveru (engine je server jen s FCGI_SOCKET_PATH,
# bez ni obslouzi jeden request a skonci).
check_sample_web() {
    local web="${PWD##*/}"
    local core="${PWE_CONF_pwe_core:-/PWE/PWE}"
    core="${core%/}"
    case "${web}" in
        example.web | example-db.web) ;;
        *) return 0 ;;
    esac
    if [ -z "${FCGI_SOCKET_PATH:-}" ] || [ ! -f "${core}/pwe.fcgi" ] || [ -e "${core}/docker/entrypoint.sh" ]; then
        return 0
    fi
    warn "bezi vzorovy web ${web} zapeceny v image (ukazka: kazdy navstevnik ma skupinu admin vcetne generatoru kodu pweCreator) - neni urcen pro verejny provoz; image vlastniho webu stav podle webapps/<web>/Dockerfile"
    return 0
}

if [ -f conf/web.conf ]; then
    case "${PWE_PROFILE:-}" in
        mariadb | mysql | postgres)
            link_database_conf
            check_database_driver
            ;;
        static)
            if [ -L conf/database.conf ]; then
                warn "PWE_PROFILE=static, ale $(database_conf_state) - symlink zustava a engine nacte databazovou konfiguraci jineho profilu"
            fi
            ;;
        "") ;;
        *)
            warn "neznamy PWE_PROFILE='${PWE_PROFILE}' (platne hodnoty: static, mariadb, mysql, postgres) - conf/database.conf se nenastavuje ($(database_conf_state))"
            ;;
    esac

    for dir in ramdisk/templates sessions uploadfile log; do
        mkdir -p "${dir}" 2>/dev/null || true
    done

    check_sample_web
fi

exec "$@"
