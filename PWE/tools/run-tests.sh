#!/bin/bash
# Spusti testy enginu PWE (PWE/t/*.t) uvnitr kontejneru s kompletnimi Perl zavislostmi.
#
#   PWE/tools/run-tests.sh                      # vsechny testy (make test)
#   PWE/tools/run-tests.sh t/03-validate.t      # jeden test (cesta relativne k adresari enginu PWE/, ne ke koreni repozitare)
#   PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:master PWE/tools/run-tests.sh    # jiny image (cele jmeno vcetne tagu)
#   PWE_IMAGE_TAG=master PWE/tools/run-tests.sh                            # image nastroju jine vetve
#   PWE_TEST_LOCK_WAIT=0 PWE/tools/run-tests.sh                            # necekat na jiny bezici beh (kod 2)
#
# Image: vychozi je image nastroju ghcr.io/kukam/pwe-debugger:<aktualni vetev gitu> (pwe_tool_image
# z PWE/tools/lib/images.sh; ma vsechny databazove ovladace). Zmena: PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG,
# nebo PWE_TEST_IMAGE = uplne prepsani. Image sestavi make images (PWE/tools/build-images.sh).
# Sada projde i v samotnem pwe-base (tak ji spousti CI) - testy databazove ovladace nepotrebuji.
#
# Koren repozitare se mountuje do /PWE (engine je tedy /PWE/PWE a je i pracovnim adresarem). Image pwe-* maji zapecene
# PWE_CONF_pwe_core (uz v pwe-base) a image webu navic PWE_CONF_pwe_home sveho webu - vsechny PWE_CONF_* se pred
# spustenim testu odstrani. Pro jistotu se odstrani i FCGI_SOCKET_PATH (v image zapecena neni, maji ji az kontejnery
# compose stacku z docker-compose/docker-compose_common.env; engine by s ni misto jednoho CGI requestu poslouchal na socketu).
# Entrypoint image se obchazi (--entrypoint bash), testy si pracovni adresare fixture webu pripravuji samy.
#
# Zamek pracovni kopie: testy sdileji docasna data (PWE/t/fixtures/app*/ramdisk, webapps/example*.web/ramdisk),
# takze dva soubezne behy nad TOUZ pracovni kopii by si je navzajem prepisovaly a oba selhaly. Beh si proto
# zalozi adresar PWE/t/.run-tests.lock (uvnitr soubor pid s cislem procesu tohoto skriptu) a na konci ho smaze
# (trap EXIT, INT, TERM). Zamek plati pro kazdy beh, i pro jediny test.
#   - Zamek drzi jiny bezici beh: skript ceka, az skonci (jednou vypise, na co ceka), nejvys
#     PWE_TEST_LOCK_WAIT sekund (vychozi 600); pak skonci kodem 2. PWE_TEST_LOCK_WAIT=0 = necekat, hned kod 2.
#   - Opusteny zamek (proces z pid uz nebezi nebo to neni run-tests.sh, napr. po kill -9 ci restartu
#     stroje): beh ho prevezme.
#   - Zamek nejde zalozit z jineho duvodu (souborovy system jen pro cteni, prava): beh pokracuje bez zamku
#     s varovanim.
# Navratovy kod skriptu = navratovy kod prove (docker run se proto nespousti pres exec - trap by se neprovedl).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
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

# lock_acquire - zalozi zamek pracovni kopie, pripadne na nej pocka (viz hlavicka). Vraci 0 i tehdy,
# kdyz zamek zalozit nejde (beh bez zamku); pri vyprseni cekani konci skript kodem 2.
lock_acquire() {
    local waited=0 nopid=0 announced=0 pid
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
        if lock_stale "$pid" "$nopid" && lock_takeover "$nopid"; then
            LOCKED=1
            if [ -n "$pid" ]; then
                echo "[run-tests] prevzat opusteny zamek $LOCK (beh s PID $pid uz nebezi)" >&2
            else
                echo "[run-tests] prevzat opusteny zamek $LOCK (bez souboru pid)" >&2
            fi
            return 0
        fi
        # Zamek bez pid: nejdriv par sekund pockat, jestli pid pribude (cerstvy zamek), nebo zamek zustane
        # opusteny - do cekani na jiny beh (PWE_TEST_LOCK_WAIT) se to nepocita.
        if [ -n "$pid" ] || [ "$nopid" -ge "$LOCK_NOPID_GRACE" ]; then
            if [ "$waited" -ge "$LOCK_WAIT" ]; then
                if [ "$LOCK_WAIT" -eq 0 ]; then
                    echo "[run-tests] nad touto pracovni kopii uz bezi jiny beh testu (PID ${pid:-?}, zamek $LOCK) a PWE_TEST_LOCK_WAIT=0 - koncim" >&2
                else
                    echo "[run-tests] jiny beh testu (PID ${pid:-?}) neskoncil ani po $LOCK_WAIT s - koncim. Delsi cekani: PWE_TEST_LOCK_WAIT=<sekundy>; zamek, ktery uz nikomu nepatri, smaz: rm -rf $LOCK" >&2
                fi
                exit 2
            fi
            if [ "$announced" = 0 ]; then
                announced=1
                echo "[run-tests] nad touto pracovni kopii bezi jiny beh testu (PID ${pid:-?}, zamek $LOCK) - cekam, az skonci (nejvys $LOCK_WAIT s; PWE_TEST_LOCK_WAIT=0 = necekat)" >&2
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
    unset FCGI_SOCKET_PATH
    for v in $(env | grep "^PWE_CONF_" | cut -d= -f1); do unset "$v"; done
    exec prove -I/PWE/PWE -I/PWE/PWE/t/lib "$@"' -- "${ARGS[@]}" || RC=$?
exit "$RC"
