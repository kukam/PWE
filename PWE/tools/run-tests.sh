#!/bin/bash
# Spusti testy enginu PWE (PWE/t/*.t) uvnitr kontejneru s kompletnimi Perl zavislostmi.
#
#   PWE/tools/run-tests.sh                      # vsechny testy (make test)
#   PWE/tools/run-tests.sh t/03-validate.t      # jeden test (cesta relativne k adresari enginu PWE/, ne ke koreni repozitare)
#   PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:latest PWE/tools/run-tests.sh    # jiny image (cele jmeno vcetne tagu)
#   PWE_IMAGE_TAG=latest PWE/tools/run-tests.sh                            # image nastroju s jinym tagem nez verze pracovni kopie
#   PWE_TEST_LOCK_WAIT=0 PWE/tools/run-tests.sh                            # necekat na jiny bezici beh (kod 2)
#
# Image: vychozi je image nastroju ghcr.io/kukam/pwe-debugger:<verze enginu z PWE/VERSION> (pwe_tool_image
# z PWE/tools/lib/images.sh; ma vsechny databazove ovladace, na gitu ani vetvi nezavisi). Zmena:
# PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG (napr. latest), nebo PWE_TEST_IMAGE = uplne prepsani (tag se pak nezjistuje).
# Image sestavi make images (PWE/tools/build-images.sh).
# Sada projde i v samotnem pwe-base (tak ji spousti CI) - testy databazove ovladace nepotrebuji.
#
# Koren repozitare se mountuje do /PWE (engine je tedy /PWE/PWE a je i pracovnim adresarem): zavislostni image kod
# enginu ani web neobsahuji, v image webu (PWE_TEST_IMAGE=.../pwe-example-static:...) je mount prekryje. Vsechny image
# maji zapecene PWE_CONF_pwe_core (uz v pwe-base), image webu vcetne pwe-example-* navic PWE_CONF_pwe_home sveho webu
# a PWE_PROFILE - vsechny PWE_CONF_* i PWE_PROFILE se pred spustenim testu odstrani. Pro jistotu se odstrani
# i FCGI_SOCKET_PATH (v image zapecena neni, maji ji az kontejnery compose stacku z
# docker-compose/docker-compose_common.env; engine by s ni misto jednoho CGI requestu poslouchal na socketu).
# Entrypoint image se obchazi (--entrypoint bash), testy si pracovni adresare fixture webu pripravuji samy.
#
# Zamek pracovni kopie: testy sdileji docasna data (PWE/t/fixtures/app*/ramdisk, webapps/example*.web/ramdisk),
# takze dva soubezne behy nad TOUZ pracovni kopii by si je navzajem prepisovaly a oba selhaly. Beh si proto
# zalozi adresar PWE/t/.run-tests.lock (uvnitr soubor pid s cislem procesu tohoto skriptu) a na konci ho smaze
# (trap EXIT, INT, TERM). Zamek plati pro kazdy beh, i pro jediny test.
#   - Zamek drzi jiny bezici beh: skript ceka, az skonci (jednou vypise, na co ceka), nejvys
#     PWE_TEST_LOCK_WAIT sekund (vychozi 600); pak skonci kodem 2. PWE_TEST_LOCK_WAIT=0 = necekat, hned kod 2.
#   - Opusteny zamek (proces z pid uz nebezi nebo to neni run-tests.sh, napr. po kill -9 ci restartu
#     stroje): beh ho prevezme. Znacku prebirani (adresar takeover v zamku), ktera zbyla po behu ukoncenem
#     uprostred prebirani, po par sekundach smaze a zamek prevezme.
#   - Zamek nejde zalozit, nebo opusteny zamek nejde prevzit, protoze se do adresare neda zapisovat
#     (souborovy system jen pro cteni, prava): beh pokracuje bez zamku s varovanim.
#   - Opusteny zamek nejde prevzit z jineho duvodu: beh to zkousi po dobu PWE_TEST_LOCK_WAIT a pak skonci
#     kodem 2 s hlaskou, ze zamek je opusteny (ne ze bezi jiny beh) a jak ho smazat.
# Navratovy kod skriptu = navratovy kod prove (docker run se proto nespousti pres exec - trap by se neprovedl).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/images.sh disable=SC1091
. "$ROOT/PWE/tools/lib/images.sh"
IMAGE="$(pwe_tool_image)"
echo "[run-tests] image $IMAGE" >&2
pwe_image_missing_hint "$IMAGE" run-tests
ARGS=("$@")
[ ${#ARGS[@]} -eq 0 ] && ARGS=(-r t)

LOCK="$ROOT/PWE/t/.run-tests.lock"
LOCK_WAIT="${PWE_TEST_LOCK_WAIT:-600}"
case "$LOCK_WAIT" in
    '' | *[!0123456789]*) echo "[run-tests] PWE_TEST_LOCK_WAIT='$LOCK_WAIT' neni cele nezaporne cislo (sekundy cekani na zamek, 0 = necekat)" >&2; exit 2 ;;
esac
LOCKED=0
LOCK_NOPID_GRACE=5
LOCK_TAKEOVER_GRACE=3

# lock_holder - vypise PID ze zamku; prazdny vystup = soubor pid (jeste) neexistuje nebo neobsahuje cislo.
lock_holder() {
    local pid=""
    [ -f "$LOCK/pid" ] && pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    case "$pid" in
        '' | *[!0123456789]*) pid="" ;;
    esac
    printf '%s\n' "$pid"
}

# lock_stale <pid> <pocet po sobe jdoucich kontrol bez pid> - vraci 0, kdyz je zamek opusteny:
#   - zamek nema soubor pid dele nez LOCK_NOPID_GRACE kontrol po sekunde (beh ukonceny mezi mkdir a zapisem
#     pid; kratke okno bez pid ma i kazdy cerstve zalozeny zamek, proto ne hned),
#   - proces s danym cislem nebezi, nebo to neni run-tests.sh: po padu ci restartu stroje dostane cislo
#     opusteneho zamku casem jiny program (i tento skript) a beh by na nej cekal az do vyprseni.
#     Program se zjistuje pres ps; kdyz ps chybi nebo nic nevrati, rozhoduje jen kill -0.
lock_stale() {
    local cmd
    if [ -z "$1" ]; then
        [ "$2" -ge "$LOCK_NOPID_GRACE" ]
        return
    fi
    [ "$1" = "$$" ] && return 0
    cmd="$(ps -p "$1" -o command= 2>/dev/null || true)"
    case "$cmd" in
        *run-tests*) return 1 ;;
        '') kill -0 "$1" 2>/dev/null && return 1 ;;
    esac
    return 0
}

# lock_takeover <pocet kontrol bez pid> - prevezme opusteny zamek. Znacka $LOCK/takeover (mkdir je
# atomicky) zaruci, ze zamek prevezme jen jeden z cekajicich; pod znackou se stav overi znovu, protoze
# zamek mohl mezitim prevzit (a zapsat do nej sve pid) nekdo jiny. Vraci 0 = zamek je nas.
lock_takeover() {
    mkdir "$LOCK/takeover" 2>/dev/null || return 1
    if lock_stale "$(lock_holder)" "$1" && echo $$ > "$LOCK/pid"; then
        rmdir "$LOCK/takeover" 2>/dev/null || true
        return 0
    fi
    rmdir "$LOCK/takeover" 2>/dev/null || true
    return 1
}

# lock_release - smaze zamek, pokud ho drzi tento proces (v souboru pid je jeho cislo, nebo pid jeste
# nestihl zapsat). Vola se z trapu, navratovy kod skriptu nemeni.
# shellcheck disable=SC2329   # funkce se vola neprimo, z trap EXIT
lock_release() {
    local holder
    if [ "$LOCKED" = 1 ]; then
        LOCKED=0
        holder="$(lock_holder)"
        if [ -z "$holder" ] || [ "$holder" = "$$" ]; then
            rm -f "$LOCK/pid"
            rmdir "$LOCK" 2>/dev/null || true
        fi
    fi
    return 0
}

# lock_stale_why <pid> - vypise (do hlasek), proc je zamek opusteny.
lock_stale_why() {
    if [ -n "$1" ]; then
        printf '%s\n' "beh s PID $1 uz nebezi"
    else
        printf '%s\n' "bez souboru pid"
    fi
}

# lock_acquire - zalozi zamek pracovni kopie, pripadne na nej pocka (viz hlavicka). Vraci 0 i tehdy,
# kdyz zamek zalozit nebo prevzit nejde, protoze se do adresare neda zapisovat (beh bez zamku); pri
# vyprseni cekani konci skript kodem 2.
lock_acquire() {
    local waited=0 nopid=0 stuck=0 announced="" pid state
    while :; do
        if mkdir "$LOCK" 2>/dev/null; then
            LOCKED=1
            echo $$ > "$LOCK/pid"
            return 0
        fi
        if [ ! -d "$LOCK" ]; then
            echo "[run-tests] POZOR: zamek $LOCK nejde zalozit (souborovy system jen pro cteni?) - pokracuji bez zamku, soubezny beh testu nad touto pracovni kopii muze selhat" >&2
            return 0
        fi
        pid="$(lock_holder)"
        if [ -z "$pid" ]; then nopid=$((nopid + 1)); else nopid=0; fi
        state=held
        if lock_stale "$pid" "$nopid"; then
            if lock_takeover "$nopid"; then
                LOCKED=1
                echo "[run-tests] prevzat opusteny zamek $LOCK ($(lock_stale_why "$pid"))" >&2
                return 0
            fi
            # Opusteny zamek se prevzit nepodarilo - neni to bezici beh, na ktery ma smysl cekat.
            state=stale
            if [ -d "$LOCK" ] && [ ! -w "$LOCK" ]; then
                echo "[run-tests] POZOR: opusteny zamek $LOCK ($(lock_stale_why "$pid")) nejde prevzit - do adresare se neda zapisovat (souborovy system jen pro cteni, prava) - pokracuji bez zamku, soubezny beh testu nad touto pracovni kopii muze selhat" >&2
                return 0
            fi
            # Prvni neuspechy: zamek nejspis prave prebira jiny beh (trva to zlomek sekundy) - pristi
            # kontrola uvidi jeho pid. Do cekani na jiny beh (PWE_TEST_LOCK_WAIT) se to nepocita.
            stuck=$((stuck + 1))
            if [ "$stuck" -lt "$LOCK_TAKEOVER_GRACE" ]; then
                sleep 1
                continue
            fi
            # Znacka prebirani, ktera tu je i po LOCK_TAKEOVER_GRACE kontrolach, zbyla po behu ukoncenem
            # uprostred prebirani: smazat a zkusit to hned znovu.
            if [ -d "$LOCK/takeover" ] && rmdir "$LOCK/takeover" 2>/dev/null; then
                echo "[run-tests] smazana znacka prebirani $LOCK/takeover (zbyla po prerusenem behu)" >&2
                stuck=0
                continue
            fi
        else
            stuck=0
        fi
        # Zamek bez pid: nejdriv par sekund pockat, jestli pid pribude (cerstvy zamek), nebo zamek zustane
        # opusteny - do cekani na jiny beh (PWE_TEST_LOCK_WAIT) se to nepocita.
        if [ -n "$pid" ] || [ "$nopid" -ge "$LOCK_NOPID_GRACE" ]; then
            if [ "$waited" -ge "$LOCK_WAIT" ]; then
                if [ "$state" = stale ]; then
                    echo "[run-tests] zamek $LOCK je opusteny ($(lock_stale_why "$pid")), ale nejde prevzit - koncim. Smaz ho: rm -rf $LOCK" >&2
                elif [ "$LOCK_WAIT" -eq 0 ]; then
                    echo "[run-tests] nad touto pracovni kopii uz bezi jiny beh testu (PID ${pid:-?}, zamek $LOCK) a PWE_TEST_LOCK_WAIT=0 - koncim" >&2
                else
                    echo "[run-tests] jiny beh testu (PID ${pid:-?}) neskoncil ani po $LOCK_WAIT s - koncim. Delsi cekani: PWE_TEST_LOCK_WAIT=<sekundy>; zamek, ktery uz nikomu nepatri, smaz: rm -rf $LOCK" >&2
                fi
                exit 2
            fi
            if [ "$announced" != "$state" ]; then
                announced="$state"
                if [ "$state" = stale ]; then
                    echo "[run-tests] zamek $LOCK je opusteny ($(lock_stale_why "$pid")), ale nejde prevzit - zkousim to dal (nejvys $LOCK_WAIT s; PWE_TEST_LOCK_WAIT=0 = necekat)" >&2
                else
                    echo "[run-tests] nad touto pracovni kopii bezi jiny beh testu (PID ${pid:-?}, zamek $LOCK) - cekam, az skonci (nejvys $LOCK_WAIT s; PWE_TEST_LOCK_WAIT=0 = necekat)" >&2
                fi
            fi
            waited=$((waited + 1))
        fi
        sleep 1
    done
}

trap lock_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
lock_acquire

RC=0
# --init: prove neni PID 1, takze Ctrl-C (SIGINT) testy opravdu ukonci
docker run --rm --init --entrypoint bash -v "$ROOT":/PWE -w /PWE/PWE "$IMAGE" -c '
    unset FCGI_SOCKET_PATH PWE_PROFILE
    for v in $(env | grep "^PWE_CONF_" | cut -d= -f1); do unset "$v"; done
    exec prove -I/PWE/PWE -I/PWE/PWE/t/lib "$@"' -- "${ARGS[@]}" || RC=$?
exit "$RC"
