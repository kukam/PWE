#!/bin/bash
# Entrypoint image PWE. Stage base (PWE/docker/Dockerfile) ho instaluje do /usr/local/bin/entrypoint.sh
# a dedi ho vsechny image z pwe-base odvozene: profilove image, debugger i image webu (Dockerfile webu
# ENTRYPOINT nenastavuje a web zadnou vlastni kopii tohoto souboru nema).
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
#   - profil static a v conf/ zustal symlink database.conf (engine by nacetl databazi jineho profilu).
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

if [ -f conf/web.conf ]; then
    case "${PWE_PROFILE:-}" in
        mariadb | mysql | postgres)
            link_database_conf
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
fi

exec "$@"
