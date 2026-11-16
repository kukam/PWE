#!/bin/bash
# Kourove kontroly image PWE: kazdy image obsahuje to, co ma, a nic, co mit nema.
#
#   PWE/tools/smoke-images.sh [--platform <platforma>] [--pull never|always] [--tree|--no-tree] [jmeno image ...]
#
#   PWE/tools/smoke-images.sh                              # vsech 9 image z lokalniho Dockeru (po make images)
#   PWE/tools/smoke-images.sh pwe-base pwe-example-static  # jen vybrane image (lze psat i base, mariadb, example-static...)
#   PWE/tools/smoke-images.sh --platform linux/arm64       # image jine platformy (na stroji amd64 bezi v emulaci QEMU)
#   PWE/tools/smoke-images.sh --pull always                # image z registru misto lokalnich
#   PWE_IMAGE_TAG=latest PWE/tools/smoke-images.sh --pull always --platform linux/arm64   # publikovany image s tagem latest
#                                                          # (bez srovnani s pracovni kopii, viz --tree)
#
# Image (bez jmena = vsechny; pwe_image_names v PWE/tools/lib/images.sh):
#   zavislostni image   pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger - jen knihovny, zadny kod enginu, zadny web
#   vzorove weby        pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres
#                       = zavislostni image + engine + vzorovy web (example.web nad pwe-base, example-db.web nad pwe-<profil>)
# Kontroluji se vzdy v tomto poradi (zavislostni image pred vzorovymi, ktere se s nimi srovnavaji), kazdy jednou.
# Registr a tag urcuje PWE/tools/lib/images.sh: PWE_IMAGE_REGISTRY (vychozi ghcr.io/kukam) a PWE_IMAGE_TAG
# (vychozi = verze enginu z PWE/VERSION; kazdy image ma tagy <verze> a latest). Stejny skript spousti pipeline
# .github/workflows/images.yml nad cerstve sestavenymi image pred publikaci (linux/amd64 i linux/arm64).
#
# Volby:
#   --platform P    platforma kontejneru (docker run --platform), napr. linux/arm64; bez volby vychozi platforma
#                   Dockeru. U linux/amd64 a linux/arm64 se overuje, ze kontejner na ni opravdu bezi.
#   --pull never    (vychozi) kontroluje se jen to, co je v lokalnim Dockeru - nikdy se potichu nestahne starsi
#                   image z registru. Chybejici image = FAIL a jeho dalsi kontroly se preskoci.
#   --pull always   kazdy image se pred kontrolou stahne z registru (docker pull). POZOR: nahradi lokalni image
#                   pod stejnym tagem.
#   --tree          srovnani image s pracovni kopii se provede vzdy - pro image sestaveny z teto pracovni kopie,
#                   u ktereho to skript sam nepozna (napr. --pull always hned po publikaci, nebo tag latest).
#   --no-tree       srovnani s pracovni kopii se neprovede nikdy.
#                   Bez techto voleb se srovnava jen image, ktery pracovni kopii odpovida: mistni image
#                   (--pull never) s tagem = verze pracovni kopie (obsah PWE/VERSION; stary image = FAIL).
#                   Image s jinym tagem (PWE_IMAGE_TAG: jina verze, latest) a image stazeny z registru
#                   (--pull always) by srovnani hlasilo jako chybny, i kdyz je v poradku: misto nej se
#                   vypise "SKIP <image>: ..." a u vzorovych image se overi jen vnitrni soulad (VERSION tvaru
#                   X.Y.Z = popisek version).
#                   Srovnava se OBSAH souboru (kontrolni soucet a velikost), ne jen jejich seznam: image
#                   sestaveny pred posledni zmenou enginu, vzoroveho webu nebo entrypointu = FAIL (make images).
#
# Co se kontroluje (prikazy bezi pres entrypoint image, bez site):
#   vsechny image   kontejner se spusti; Perl moduly zakladu jdou nacist; programy a soubory zakladu existuji
#                   (/usr/bin/sass, /usr/bin/identify, /usr/bin/convert, openssl, casova zona Europe/Prague);
#                   popisek title = jmeno image. Jen u image, ktery odpovida pracovni kopii (viz --tree):
#                   /usr/local/bin/entrypoint.sh = PWE/docker/entrypoint.sh pracovni kopie.
#   zavislostni image (pwe-base, pwe-mariadb, pwe-mysql, pwe-postgres, pwe-debugger)
#                   v image NENI kod enginu (/PWE/PWE neexistuje) ani zadny web (/PWE/webapps je prazdny);
#                   ENV PWE_CONF_pwe_core=/PWE/PWE a zadne PWE_CONF_pwe_home ani PWE_PROFILE; popisek version
#                   je prazdny (verzi enginu nesou jen image, ktere engine obsahuji)
#   pwe-base        convert a identify nad skutecnym obrazkem, sass prelozi scss, openssl a TZ funguji;
#                   zadny ovladac databaze
#   pwe-mariadb     DBD::mysql a DBD::MariaDB;   pwe-mysql   DBD::mysql;   pwe-postgres   DBD::Pg
#                   (a zadny ovladac jineho profilu)
#   pwe-debugger    vsechny tri ovladace, Perl::LanguageServer >= 2.6.2, perlcritic, perltidy, curl
#   image vzorovych webu (pwe-example-static, pwe-example-mariadb, pwe-example-mysql, pwe-example-postgres)
#                   vychazi ze zavislostniho image tehoz tagu (pwe-base, pwe-<profil>): jeho vrstvy jsou zacatkem
#                   vrstev image (jen kdyz se zaklad kontroluje v tomtez behu; jinak SKIP);
#                   ovladace databaze sveho zakladu (pwe-example-static zadny);
#                   engine: perl -c pwe.fcgi; obsah /PWE (jen LICENSE, PWE a webapps) a /PWE/PWE (bez t/ a
#                   docker/); popisky title a version = VERSION v image. Jen u image, ktery odpovida pracovni
#                   kopii: VERSION a popisek version = PWE/VERSION; soubory enginu v image (seznam i obsah) =
#                   pracovni kopie PWE/ bez t/, docker/ a bez toho, co vynechava .dockerignore (stary image nebo
#                   polozka enginu mimo COPY v Dockerfile webu = FAIL);
#                   vzorovy web (pwe-example-static: example.web, ostatni: example-db.web) tak, jak ho zalozilo
#                   sestaveni: ENV PWE_CONF_pwe_home a PWE_PROFILE, pracovni adresar, soubory webu, prazdne
#                   pracovni adresare, conf/database.conf -> <profil>.conf (pwe-example-static zadny),
#                   v /PWE/webapps nic dalsiho; bez varovani entrypointu. Kontejner te kontroly bezi
#                   s --read-only jen proto, aby entrypoint nemohl nic zalozit (adresare a symlink tak musi
#                   pochazet ze sestaveni) - engine se v ni nespousti. U image, ktery odpovida pracovni kopii,
#                   navic soubory vzoroveho webu (seznam i obsah) = pracovni kopie;
#                   entrypoint pri startu serveru (FCGI_SOCKET_PATH) varuje, ze bezi vzorovy web (ukazka, kde je
#                   kazdy navstevnik ve skupine admin - neni urcena pro verejny provoz)
#   pwe-example-static
#                   vychozi prikaz image obslouzi jeden request v rezimu CGI a vrati stranku vzoroveho webu
#                   (HTML, bez chyby v logu) - jednou bezne a jednou s korenovym souborovym systemem jen pro
#                   cteni: --read-only a tmpfs pres pracovni adresare webu (ramdisk, sessions, uploadfile, log),
#                   do kterych engine zapisuje. Jen s --read-only, bez zapisovatelnych pracovnich adresaru,
#                   engine request neobslouzi.
#   pwe-example-mariadb, pwe-example-mysql, pwe-example-postgres
#                   bez databaze (kontroly bezi bez site) se overi jen to, co bez ni jde: vychozi prikaz image
#                   nacte konfiguraci profilu a ovladac a skonci az na pripojeni k databazi
#                   ("Connect to <profil> dbid:db1 ..." a "Unable connect to db1"). Beh s --read-only se
#                   u databazovych profilu neoveruje: bez databaze engine skonci driv, nez do pracovnich
#                   adresaru zapise, takze by kontrola prosla i bez nich a nic by nerekla.
#
# Vystup: jeden radek na kontrolu, "OK   <image>: <popis>" nebo "FAIL <image>: <popis>" a pod nim odsazeny
# duvod (vystup prikazu); "SKIP <image>: <popis>" = kontrola se neprovadi (duvod pod nim). V GitHub Actions
# se k selhani prida anotace ::error a k preskocene kontrole ::warning.
# Navratovy kod: 0 = vsechny kontroly prosly, 1 = aspon jedna selhala, 2 = spatne pouziti nebo chybi docker.
set -u
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/images.sh disable=SC1091
. "$ROOT/PWE/tools/lib/images.sh"

# Vsechny image v poradi kontrol: zavislostni image, pak image vzorovych webu (pwe_image_names).
ALL_IMAGES="$(pwe_image_names all | tr '\n' ' ')"
ALL_IMAGES="${ALL_IMAGES% }"

# Vzorovy web, ktery image vzoroveho webu obsahuje (pwe-example-static bez databaze, ostatni s databazi).
STATIC_WEB="example.web"
DB_WEB="example-db.web"

# Polozky korene enginu (PWE/), ktere do image nepatri: testy, sestaveni zavislostnich image a nastroje
# pro vyvojare (bezi na hostiteli nebo nad namountovanym repozitarem, engine je za behu nepotrebuje). Stejny seznam ma
# PWE::ToolEnv::engine_image_excludes (hlida PWE/t/21-image-tools.t); Dockerfile webu je nekopiruje.
ENGINE_EXCLUDES="t docker tools"

# Perl moduly, ktere musi jit nacist v pwe-base a tim i ve vsech ostatnich image (jadro enginu, e-maily,
# knihovny slibene kodu webu). Seznam odpovida balickum stage base v PWE/docker/Dockerfile.
BASE_MODULES=(
    CGI::Fast Template Class::Inspector Class::MOP JSON JSON::XS DBI
    Mail::RFC822::Address Cz::Cstocs LWP::MediaTypes IO::Socket::SSL Net::SSLeay Authen::SASL
    Image::Magick Crypt::OpenSSL::RSA URI HTML::Parser
)

# Nejnizsi verze jazykoveho serveru v pwe-debugger (= ARG PERL_LANGUAGESERVER_MIN v PWE/docker/Dockerfile).
LANGUAGESERVER_MIN="2.6.2"

usage() {
    sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

PLATFORM=""
PULL="never"
TREE="auto"
IMAGES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            if [ $# -lt 2 ]; then echo "--platform vyzaduje hodnotu, napr. linux/arm64" >&2; exit 2; fi
            PLATFORM="$2"; shift 2 ;;
        --platform=*) PLATFORM="${1#--platform=}"; shift ;;
        --pull)
            if [ $# -lt 2 ]; then echo "--pull vyzaduje hodnotu never nebo always" >&2; exit 2; fi
            PULL="$2"; shift 2 ;;
        --pull=*)     PULL="${1#--pull=}"; shift ;;
        --tree)       TREE="always"; shift ;;
        --no-tree)    TREE="never"; shift ;;
        -h | --help)  usage; exit 0 ;;
        -*)           echo "Neznama volba $1 (napoveda: $0 --help)" >&2; exit 2 ;;
        *)
            # jmeno image, nebo jmeno bez predpony "pwe-" (= cil sestaveni: base, mariadb, example-static...)
            name="$1"
            case " $ALL_IMAGES " in
                *" $name "*) ;;
                *" pwe-$name "*) name="pwe-$name" ;;
                *)
                    case "$1" in
                        pwe) echo "Image pwe (jen engine) byl zrusen: engine je soucasti image webu (pwe-example-*). Image: $ALL_IMAGES" >&2 ;;
                        static | pwe-static) echo "Image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, vzorovy web bez databaze je pwe-example-static. Image: $ALL_IMAGES" >&2 ;;
                        *) echo "Neznamy image $1 (image: $ALL_IMAGES)" >&2 ;;
                    esac
                    exit 2
                    ;;
            esac
            IMAGES+=("$name")
            shift
            ;;
    esac
done
case "$PULL" in
    never | always) ;;
    *) echo "--pull: neplatna hodnota '$PULL' (never nebo always)" >&2; exit 2 ;;
esac
case "$PLATFORM" in
    "") ;;
    -* | *[!abcdefghijklmnopqrstuvwxyz0123456789/._-]* | */ | /*)
        echo "--platform: neplatna hodnota '$PLATFORM' (napr. linux/amd64 nebo linux/arm64)" >&2; exit 2 ;;
    */*) ;;
    *) echo "--platform: neplatna hodnota '$PLATFORM' (napr. linux/amd64 nebo linux/arm64)" >&2; exit 2 ;;
esac
# Poradi kontrol je vzdy poradi ALL_IMAGES (zavislostni image pred image vzorovych webu - ty se s nimi
# srovnavaji), kazdy image jednou, i kdyz je na prikazove radce v jinem poradi nebo vickrat.
if [ ${#IMAGES[@]} -eq 0 ]; then
    read -r -a IMAGES <<< "$ALL_IMAGES"
else
    SELECTED=" ${IMAGES[*]} "
    IMAGES=()
    for name in $ALL_IMAGES; do
        case "$SELECTED" in
            *" $name "*) IMAGES+=("$name") ;;
        esac
    done
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[smoke-images] chybi prikaz docker" >&2
    exit 2
fi

REGISTRY="$(pwe_image_registry)"
TAG="$(pwe_image_tag)" || exit 2
VERSION="$(pwe_image_version)" || exit 2

# Srovnani image s pracovni kopii (PWE/VERSION, soubory enginu a vzoroveho webu, entrypoint) ma smysl jen u image,
# ktery z ni pochazi: --tree ho vynuti, --no-tree vypne, jinak se srovnava mistni image (--pull never) s tagem,
# pod kterym image stavi tato pracovni kopie (verze z PWE/VERSION - stejne jako build-images.sh). Tag latest
# ma sice kazde sestaveni taky, ale v lokalnim Dockeru muze byt i stazeny z registru - bez --tree se nesrovnava.
COMPARE_TREE=1
TREE_WHY=""
case "$TREE" in
    always) ;;
    never)
        COMPARE_TREE=0
        TREE_WHY="volba --no-tree"
        ;;
    *)
        if [ "$PULL" = "always" ]; then
            COMPARE_TREE=0
            TREE_WHY="image se stahuje z registru (--pull always) a nemusi pochazet z teto pracovni kopie"
        elif [ "$TAG" != "$VERSION" ]; then
            COMPARE_TREE=0
            TREE_WHY="tag $TAG neni verze teto pracovni kopie ($VERSION) - image jine verze, nebo tag, ktery z ni pochazet nemusi"
        fi
        ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/smoke-images.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Spolecne volby docker run: jen lokalni image (pripadne docker pull dela image_ready), bez site.
RUN_ARGS=(--rm --pull never --network none)
[ -n "$PLATFORM" ] && RUN_ARGS+=(--platform "$PLATFORM")

CHECKS=0
FAILED=0
SKIPPED=0

# ok <image> <popis>
ok() {
    CHECKS=$((CHECKS + 1))
    echo "OK   $1: $2"
}

# fail <image> <popis> [duvod] - duvod (i vice radku) se vypise odsazeny pod radek FAIL
fail() {
    CHECKS=$((CHECKS + 1))
    FAILED=$((FAILED + 1))
    echo "FAIL $1: $2"
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" | sed 's/^/       /'
    fi
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::error title=Kourova kontrola $1${PLATFORM:+ ($PLATFORM)}::$2"
    fi
    return 0
}

# skip <image> <popis> [duvod] - kontrola se neprovadi (nepocita se mezi kontroly ani mezi selhani);
# duvod se vypise odsazeny pod radek SKIP
skip() {
    SKIPPED=$((SKIPPED + 1))
    echo "SKIP $1: $2"
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" | sed 's/^/       /'
    fi
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::warning title=Kourova kontrola $1${PLATFORM:+ ($PLATFORM)} preskocena::$2"
    fi
    return 0
}

# image_ref <image> - cele jmeno image vcetne registru a tagu
image_ref() {
    printf '%s/%s:%s\n' "$REGISTRY" "$1" "$TAG"
}

# image_label <image> <popisek> - hodnota popisku image (prazdna, kdyz popisek chybi)
image_label() {
    docker image inspect --format "{{ index .Config.Labels \"$2\" }}" "$(image_ref "$1")" 2>/dev/null || true
}

# check <image> <popis> <prikaz...> - prikaz musi v kontejneru z image uspet; bezi pres entrypoint image
# (mimo adresar webu jen preda rizeni), takze overuje i ten. Duvod selhani = vystup prikazu.
check() {
    local name="$1" desc="$2" out rc
    shift 2
    out="$(docker run "${RUN_ARGS[@]}" "$(image_ref "$name")" "$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "${out:-prikaz skoncil kodem $rc bez vystupu}"
    fi
}

# machine_of <platforma> - vypise, co ma na platforme vratit uname -m (prazdne = neoveruje se)
machine_of() {
    case "$1" in
        linux/amd64 | linux/amd64/*) echo "x86_64" ;;
        linux/arm64 | linux/arm64/*) echo "aarch64" ;;
        *) echo "" ;;
    esac
}

# image_ready <image> - pripravi image (--pull always: docker pull) a overi, ze je v lokalnim Dockeru,
# ze se z nej kontejner spusti a ze bezi na pozadovane platforme. Vraci 1, kdyz dalsi kontroly image
# nemaji smysl (image chybi nebo nejde spustit) - misto rady stejnych selhani je pak jen jedno.
image_ready() {
    local name="$1" ref out rc machine want id
    ref="$(image_ref "$name")"
    if [ "$PULL" = "always" ]; then
        if [ -n "$PLATFORM" ]; then
            out="$(docker pull --platform "$PLATFORM" "$ref" 2>&1)"
        else
            out="$(docker pull "$ref" 2>&1)"
        fi
        rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "$name" "docker pull $ref" "$out"
            return 1
        fi
    elif ! docker image inspect "$ref" >/dev/null 2>&1; then
        fail "$name" "image je v lokalnim Dockeru" \
            "$ref neni v lokalnim Dockeru (sestaveni: make images; image z registru: --pull always)"
        return 1
    fi

    machine="$(docker run "${RUN_ARGS[@]}" "$ref" uname -m 2> "$TMP/run.err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        out="$(cat "$TMP/run.err")"
        fail "$name" "kontejner se spusti pres entrypoint image" "${out:-docker run skoncil kodem $rc bez vystupu}"
        return 1
    fi
    want="$(machine_of "$PLATFORM")"
    if [ -n "$want" ] && [ "$machine" != "$want" ]; then
        fail "$name" "kontejner bezi na platforme $PLATFORM" "uname -m vratil '$machine', ocekavano '$want'"
        return 1
    fi
    id="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null | cut -c1-19)"
    ok "$name" "kontejner se spusti pres entrypoint image ($machine, ${id:-id neznamo})"
    return 0
}

# Perl: vsechny moduly z argumentu jdou nacist (vypise kazdy, ktery nejde, a proc) ...
# (shellcheck SC2016: perl a sh v apostrofech se maji rozvinout az v kontejneru, ne tady)
# shellcheck disable=SC2016
PERL_HAS='my @bad;
for my $m (@ARGV) {
    next if eval "require $m; 1";
    my ($why) = $@ =~ /\A([^\n(]*)/;
    $why =~ s/\s+\z//;
    push @bad, "modul $m nejde nacist: $why";
}
if (@bad) { print "$_\n" for @bad; exit 1 }'
# ... a zadny z nich v image neni
# shellcheck disable=SC2016
PERL_HASNT='my @bad = grep { eval "require $_; 1" } @ARGV;
if (@bad) { print "modul $_ v image byt nema\n" for @bad; exit 1 }'

# check_base_common <image> - co ma pwe-base a tim i kazdy image z nej odvozeny
check_base_common() {
    local name="$1"
    check "$name" "Perl moduly zakladu (${#BASE_MODULES[@]}: CGI::Fast ... HTML::Parser)" \
        perl -e "$PERL_HAS" "${BASE_MODULES[@]}"
    # shellcheck disable=SC2016
    check "$name" "programy a soubory zakladu (sass, identify, convert, openssl, zoneinfo Europe/Prague)" sh -c '
        rc=0
        for f in /usr/bin/sass /usr/bin/identify /usr/bin/convert; do
            [ -x "$f" ] || { echo "chybi program $f"; rc=1; }
        done
        command -v openssl >/dev/null 2>&1 || { echo "chybi program openssl"; rc=1; }
        [ -s /usr/share/zoneinfo/Europe/Prague ] || { echo "chybi /usr/share/zoneinfo/Europe/Prague (tzdata)"; rc=1; }
        exit $rc'
}

# check_base_function - programy zakladu opravdu funguji (staci jednou, v pwe-base)
check_base_function() {
    # shellcheck disable=SC2016
    check pwe-base "identify a convert nad skutecnym obrazkem (Libs/Pics.pm)" sh -c '
        set -e
        /usr/bin/convert -size 32x16 xc:red /tmp/smoke.png
        /usr/bin/convert /tmp/smoke.png -geometry 16x8 -quality 80 /tmp/smoke.jpg
        out="$(/usr/bin/identify /tmp/smoke.jpg)"
        case "$out" in
            *" JPEG 16x8 "*) ;;
            *) echo "identify vratil: $out"; exit 1 ;;
        esac'
    # shellcheck disable=SC2016
    check pwe-base "sass prelozi scss (Pages/css)" sh -c '
        set -e
        printf "a { b { c: d; } }\n" > /tmp/smoke.scss
        out="$(/usr/bin/sass -C --scss --style=compressed /tmp/smoke.scss)"
        case "$out" in
            *"a b{c:d}"*) ;;
            *) echo "sass vratil: $out"; exit 1 ;;
        esac'
    # shellcheck disable=SC2016
    check pwe-base "openssl version a TZ=Europe/Prague (CET/CEST)" sh -c '
        set -e
        openssl version >/dev/null
        zone="$(TZ=Europe/Prague date +%Z)"
        case "$zone" in
            CET | CEST) ;;
            *) echo "TZ=Europe/Prague dava zonu $zone, ocekavano CET nebo CEST"; exit 1 ;;
        esac'
}

# check_no_drivers <image> [ovladac ...] - image bez ovladacu databazi; bez seznamu zadny ze tri ovladacu,
# se seznamem zadny z vyjmenovanych (ovladace jinych profilu)
check_no_drivers() {
    local name="$1"
    shift
    if [ $# -eq 0 ]; then
        check "$name" "bez ovladacu databazi" perl -e "$PERL_HASNT" DBD::mysql DBD::MariaDB DBD::Pg
    else
        check "$name" "bez ovladacu jinych profilu ($*)" perl -e "$PERL_HASNT" "$@"
    fi
}

# check_no_engine <image> - zavislostni image neobsahuje kod enginu: /PWE/PWE v nem vubec neni (engine dostava
# mountem repozitare, nebo ho prida image webu)
check_no_engine() {
    # shellcheck disable=SC2016
    check "$1" "bez kodu enginu (/PWE/PWE v image neni)" sh -c '
        [ ! -e /PWE/PWE ] || { echo "/PWE/PWE v zavislostnim image byt nema, je tam: $(ls -A /PWE/PWE 2>/dev/null | tr "\n" " ")"; exit 1; }'
}

# check_no_web <image> - zavislostni image neobsahuje zadny web (/PWE/webapps je prazdny adresar; weby maji jen
# image webu)
check_no_web() {
    # shellcheck disable=SC2016
    check "$1" "bez webu (/PWE/webapps je prazdny)" sh -c '
        found="$(ls -A /PWE/webapps 2>/dev/null | tr "\n" " ")"
        [ -z "$found" ] || { echo "v /PWE/webapps byt nic nema, je tam: $found"; exit 1; }'
}

# check_deps_env <image> - prostredi zavislostniho image: koren enginu z pwe-base, zadne nastaveni webu
# (PWE_CONF_pwe_home a PWE_PROFILE nastavuje az image webu nebo compose)
check_deps_env() {
    # shellcheck disable=SC2016
    check "$1" "ENV: PWE_CONF_pwe_core=/PWE/PWE, zadne PWE_CONF_pwe_home ani PWE_PROFILE" sh -c '
        rc=0
        [ "${PWE_CONF_pwe_core:-}" = /PWE/PWE ] || { echo "PWE_CONF_pwe_core je \"${PWE_CONF_pwe_core:-}\", ocekavano /PWE/PWE"; rc=1; }
        [ -z "${PWE_CONF_pwe_home+x}" ] || { echo "PWE_CONF_pwe_home v zavislostnim image byt nema (je \"$PWE_CONF_pwe_home\")"; rc=1; }
        [ -z "${PWE_PROFILE+x}" ] || { echo "PWE_PROFILE v zavislostnim image byt nema (je \"$PWE_PROFILE\")"; rc=1; }
        exit $rc'
}

# check_deps_labels <image> - popisky zavislostniho image: title = jmeno image, version prazdna (verzi enginu
# nesou jen image, ktere engine obsahuji; digest zavislostniho image se tak meni jen se zavislostmi)
check_deps_labels() {
    local name="$1" title version reason=""
    title="$(image_label "$name" org.opencontainers.image.title)"
    version="$(image_label "$name" org.opencontainers.image.version)"
    if [ "$title" != "$name" ]; then
        reason="popisek org.opencontainers.image.title je '$title', ocekavano '$name'"
    fi
    if [ -n "$version" ]; then
        reason="${reason:+$reason
}popisek org.opencontainers.image.version je '$version', ocekavan prazdny (zavislostni image engine neobsahuje)"
    fi
    if [ -z "$reason" ]; then
        ok "$name" "popisky image: title=$name, version prazdna"
    else
        fail "$name" "popisky image: title=$name, version prazdna" "$reason"
    fi
}

# check_deps_only <image> - co plati pro kazdy zavislostni image: zadny engine, zadny web, zadne nastaveni webu
check_deps_only() {
    check_no_engine "$1"
    check_no_web "$1"
    check_deps_env "$1"
    check_deps_labels "$1"
}

# dockerignore_filter <soubor .dockerignore> - ze seznamu cest na vstupu (relativne ke koreni repozitare)
# vypusti ty, ktere .dockerignore vynechava z kontextu buildu. Vzory: * (bez lomitka), ? , ** (i pres
# lomitka), vzor adresare plati i pro jeho obsah, "!" vraci cestu zpet, posledni odpovidajici vzor vyhrava.
dockerignore_filter() {
    awk -v ignorefile="$1" '
        function to_regex(p,    out, i, n, c) {
            out = ""
            n = length(p)
            i = 1
            while (i <= n) {
                c = substr(p, i, 1)
                if (c == "*") {
                    if (substr(p, i, 3) == "**/") { out = out "(.*/)?"; i += 3 }
                    else if (substr(p, i, 2) == "**") { out = out ".*"; i += 2 }
                    else { out = out "[^/]*"; i++ }
                } else if (c == "?") {
                    out = out "[^/]"; i++
                } else if (index(".+()|^$\\{}", c) > 0) {
                    out = out "\\" c; i++
                } else {
                    out = out c; i++
                }
            }
            return "^" out "(/.*)?$"
        }
        BEGIN {
            n = 0
            while ((getline line < ignorefile) > 0) {
                sub(/\r$/, "", line)
                if (line ~ /^#/) continue
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                neg = 0
                if (substr(line, 1, 1) == "!") { neg = 1; line = substr(line, 2); sub(/^[ \t]+/, "", line) }
                sub(/^\.\//, "", line)
                sub(/^\/+/, "", line)
                sub(/\/+$/, "", line)
                if (line == "") continue
                n++
                re[n] = to_regex(line)
                negate[n] = neg
            }
        }
        {
            skip = 0
            for (i = 1; i <= n; i++) if ($0 ~ re[i]) skip = !negate[i]
            if (!skip) print
        }'
}

# sums_list <predpona> - vystup prikazu cksum na vstupu ("<soucet> <velikost> <cesta>") prevede na serazene
# radky "<cesta><TAB><soucet> <velikost>"; z cesty odstrani uvodni "./" a pak predponu (prazdna = zadna).
sums_list() {
    awk -v prefix="$1" '{
        crc = $1; size = $2
        sub(/^[0-9]+ [0-9]+ /, "")
        sub(/^\.\//, "")
        if (prefix != "" && index($0, prefix) == 1) $0 = substr($0, length(prefix) + 1)
        print $0 "\t" crc " " size
    }' | LC_ALL=C sort
}

# tree_sums <predpona> - ze seznamu cest na vstupu (relativne ke koreni repozitare, jedna na radek) udela
# seznam jako sums_list: kontrolni soucet a velikost souboru v pracovni kopii. Prazdny vstup = prazdny vystup.
tree_sums() {
    local prefix="$1"
    cat > "$TMP/tree.paths"
    if [ ! -s "$TMP/tree.paths" ]; then
        return 0
    fi
    (cd "$ROOT" && tr '\n' '\0' < "$TMP/tree.paths" | xargs -0 cksum 2>/dev/null) | sums_list "$prefix"
}

# list_head <soubor> - nejvys 20 radku souboru odsazenych o dve mezery, pak pocet zbylych
list_head() {
    local total
    total="$(wc -l < "$1" | tr -d '[:space:]')"
    sed -n '1,20s/^/  /p' "$1"
    if [ "$total" -gt 20 ]; then echo "  ... a dalsich $((total - 20))"; fi
}

# compare_lists <image> <popis> <odkud je seznam z pracovni kopie> - srovna soubory v pracovni kopii
# ($TMP/tree.lst) a v image ($TMP/image.lst); oba seznamy maji radky "<cesta><TAB><soucet> <velikost>"
# (sums_list). Shoda seznamu i obsahu = OK s poctem souboru; jinak FAIL a vypis, co v image chybi, co je
# navic a co ma jiny obsah.
compare_lists() {
    local name="$1" desc="$2" source="$3" reason=""
    awk -F '\t' -v only_tree="$TMP/only-tree.lst" -v only_image="$TMP/only-image.lst" -v differ="$TMP/differ.lst" '
        BEGIN { printf "" > only_tree; printf "" > only_image; printf "" > differ }
        FILENAME == ARGV[1] { tree[$1] = $2; next }
        { image[$1] = $2 }
        END {
            for (p in tree) {
                if (!(p in image)) print p >> only_tree
                else if (tree[p] != image[p]) print p >> differ
            }
            for (p in image) if (!(p in tree)) print p >> only_image
        }' "$TMP/tree.lst" "$TMP/image.lst"
    for f in only-tree only-image differ; do
        LC_ALL=C sort -o "$TMP/$f.lst" "$TMP/$f.lst"
    done
    if [ ! -s "$TMP/only-tree.lst" ] && [ ! -s "$TMP/only-image.lst" ] && [ ! -s "$TMP/differ.lst" ] && [ -s "$TMP/tree.lst" ]; then
        ok "$name" "$desc: $(wc -l < "$TMP/tree.lst" | tr -d '[:space:]') souboru"
        return 0
    fi
    if [ ! -s "$TMP/tree.lst" ]; then
        reason="v pracovni kopii $source nejsou zadne soubory"
    fi
    if [ -s "$TMP/only-tree.lst" ]; then
        reason="${reason:+$reason
}v image chybi (jsou v pracovni kopii; image je starsi, nebo polozku nekopiruje Dockerfile webu):
$(list_head "$TMP/only-tree.lst")"
    fi
    if [ -s "$TMP/only-image.lst" ]; then
        reason="${reason:+$reason
}v image navic (v pracovni kopii nejsou, nebo do image nepatri - t/, docker/, .dockerignore; image je starsi, nebo je chyba v Dockerfile webu):
$(list_head "$TMP/only-image.lst")"
    fi
    if [ -s "$TMP/differ.lst" ]; then
        reason="${reason:+$reason
}v image maji jiny obsah nez v pracovni kopii (image je starsi nez posledni zmena - sestav znovu: make images):
$(list_head "$TMP/differ.lst")"
    fi
    fail "$name" "$desc" "$reason"
}

# image_file_sums <image> <adresar v image> <popis> - do $TMP/image.raw vypise kontrolni soucty souboru
# (a cilu symlinku) v adresari image, jak je dava cksum: "<soucet> <velikost> ./<cesta>". Vraci 1 (a hlasi
# FAIL), kdyz vypis selze.
image_file_sums() {
    local name="$1" dir="$2" desc="$3" out rc
    # shellcheck disable=SC2016
    docker run "${RUN_ARGS[@]}" "$(image_ref "$name")" sh -c 'cd "$1" && find . \( -type f -o -type l \) -exec cksum {} +' sh "$dir" \
        > "$TMP/image.raw" 2> "$TMP/image.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        out="$(cat "$TMP/image.err")"
        fail "$name" "$desc" "${out:-vypis souboru v image skoncil kodem $rc bez vystupu}"
        return 1
    fi
    return 0
}

# check_entrypoint_file <image> - vstupni skript v image je PWE/docker/entrypoint.sh z pracovni kopie (obsah).
# Entrypoint ma kazdy image ze zakladu pwe-base: rozdil = image (nebo jeho zaklad) je starsi nez posledni zmena.
check_entrypoint_file() {
    local name="$1" desc="entrypoint v image (/usr/local/bin/entrypoint.sh) = PWE/docker/entrypoint.sh pracovni kopie" have want rc
    want="$(cksum < "$ROOT/PWE/docker/entrypoint.sh" 2>/dev/null | awk '{ print $1 " " $2 }')"
    have="$(docker run "${RUN_ARGS[@]}" "$(image_ref "$name")" cksum /usr/local/bin/entrypoint.sh 2> "$TMP/entry.err")"
    rc=$?
    have="$(printf '%s\n' "$have" | awk 'NR == 1 { print $1 " " $2 }')"
    if [ "$rc" -ne 0 ] || [ -z "$have" ]; then
        fail "$name" "$desc" "$(cat "$TMP/entry.err")
kontrolni soucet /usr/local/bin/entrypoint.sh se v image nepodarilo spocitat (kod $rc)"
    elif [ -n "$want" ] && [ "$have" = "$want" ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "obsah se lisi (cksum v image: ${have}, v pracovni kopii: ${want:-soubor nejde precist}) - image je starsi nez posledni zmena entrypointu; sestav znovu: make images"
    fi
}

# check_tree_skip <image> <co se nesrovnava> - image neodpovida pracovni kopii (jiny tag, image z registru,
# --no-tree): srovnani se preskoci jednim radkem SKIP
check_tree_skip() {
    skip "$1" "srovnani s pracovni kopii ($2)" "$TREE_WHY${3:+; $3} (vynuceni srovnani: --tree)"
}

# engine_find_prune - vypise cast prikazu find, ktera v pracovni kopii vynecha polozky enginu mimo image
# (ENGINE_EXCLUDES): "( -path PWE/t -o -path PWE/docker ) -prune -o"
ENGINE_PRUNE=()
engine_find_prune() {
    local x first=1
    ENGINE_PRUNE=(\()
    for x in $ENGINE_EXCLUDES; do
        if [ "$first" = 1 ]; then first=0; else ENGINE_PRUNE+=(-o); fi
        ENGINE_PRUNE+=(-path "PWE/$x")
    done
    ENGINE_PRUNE+=(\) -prune -o)
}
engine_find_prune

# check_engine_files <image> - soubory enginu v image (seznam i obsah) musi odpovidat pracovni kopii: PWE/ bez
# t/ (testy) a docker/ (sestaveni zavislostnich image) a bez toho, co z kontextu buildu vynechava .dockerignore.
# Odhali polozku enginu, kterou Dockerfile webu nekopiruje, i image sestaveny ze starsiho stavu.
check_engine_files() {
    local name="$1" desc="soubory enginu v /PWE/PWE = pracovni kopie PWE/ (seznam i obsah; bez t/, docker/ a .dockerignore)"
    image_file_sums "$name" /PWE/PWE "$desc" || return 0
    sums_list "" < "$TMP/image.raw" > "$TMP/image.lst"
    (cd "$ROOT" && find PWE "${ENGINE_PRUNE[@]}" \( -type f -o -type l \) -print) \
        | dockerignore_filter "$ROOT/.dockerignore" | tree_sums "PWE/" > "$TMP/tree.lst"
    compare_lists "$name" "$desc" "$ROOT/PWE"
}

# check_web_files <image> <web> - soubory vzoroveho webu v image (seznam i obsah) musi odpovidat pracovni kopii
# webapps/<web> bez toho, co vynechava .dockerignore (docasne adresare, conf/database.conf, conf/local.env).
# Symlink conf/database.conf v image zaklada az Dockerfile webu - do srovnani se nepocita (jeho pritomnost
# overuje check_sample_web).
check_web_files() {
    local name="$1" web="$2" desc
    desc="soubory vzoroveho webu v /PWE/webapps/$web = pracovni kopie webapps/$web (seznam i obsah; bez .dockerignore)"
    image_file_sums "$name" "/PWE/webapps/$web" "$desc" || return 0
    sums_list "" < "$TMP/image.raw" | LC_ALL=C grep -v '^conf/database\.conf	' > "$TMP/image.lst"
    (cd "$ROOT" && find "webapps/$web" \( -type f -o -type l \) -print 2>/dev/null) \
        | dockerignore_filter "$ROOT/.dockerignore" | tree_sums "webapps/$web/" > "$TMP/tree.lst"
    compare_lists "$name" "$desc" "$ROOT/webapps/$web"
}

# check_engine_labels <image> <verze> <odkud verze je> - popisky image s enginem: title a verze enginu (tag
# <verze> nesmi ukazovat na jiny kod); commit a cas buildu se jen vypisuji (lokalni build z rozpracovaneho
# stromu commit nema)
check_engine_labels() {
    local name="$1" want="$2" source="$3" title version revision created reason=""
    title="$(image_label "$name" org.opencontainers.image.title)"
    version="$(image_label "$name" org.opencontainers.image.version)"
    if [ "$title" != "$name" ]; then
        reason="popisek org.opencontainers.image.title je '$title', ocekavano '$name'"
    fi
    if [ "$version" != "$want" ]; then
        reason="${reason:+$reason
}popisek org.opencontainers.image.version je '$version', ocekavano '$want' ($source)"
    fi
    revision="$(image_label "$name" org.opencontainers.image.revision)"
    created="$(image_label "$name" org.opencontainers.image.created)"
    if [ -z "$reason" ]; then
        ok "$name" "popisky image: title=$name, version=$want (revision=${revision:-neuvedena}, created=${created:-neuveden})"
    else
        fail "$name" "popisky image: title=$name, version=$want" "$reason"
    fi
}

# check_engine_version <image> - verze enginu v image (/PWE/PWE/VERSION) a popisky image. Image, ktery odpovida
# pracovni kopii (COMPARE_TREE), se s ni srovna: VERSION a popisek version = PWE/VERSION, soubory enginu.
# U ostatnich (image jine verze, tag latest, image z registru) se overi jen vnitrni soulad image: VERSION ma
# tvar X.Y.Z a popisek version rika totez.
check_engine_version() {
    local name="$1" image_version out rc
    image_version="$(docker run "${RUN_ARGS[@]}" "$(image_ref "$name")" cat /PWE/PWE/VERSION 2> "$TMP/version.err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        out="$(cat "$TMP/version.err")"
        fail "$name" "verze enginu v image (/PWE/PWE/VERSION)" "${out:-cteni /PWE/PWE/VERSION skoncilo kodem $rc bez vystupu}"
        return 0
    fi
    image_version="$(printf '%s' "$image_version" | tr -d '[:space:]')"

    if [ "$COMPARE_TREE" = 1 ]; then
        if [ "$image_version" = "$VERSION" ]; then
            ok "$name" "VERSION = $VERSION (PWE/VERSION pracovni kopie)"
        else
            fail "$name" "VERSION = $VERSION (PWE/VERSION pracovni kopie)" "v image je verze $image_version, v pracovni kopii $VERSION"
        fi
        check_engine_labels "$name" "$VERSION" "PWE/VERSION"
        check_engine_files "$name"
        return 0
    fi

    if [[ "$image_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "$name" "VERSION v image = $image_version (tvar X.Y.Z)"
    else
        fail "$name" "VERSION v image ma tvar X.Y.Z" "v image je verze '$image_version'"
    fi
    check_engine_labels "$name" "$image_version" "VERSION v image"
}

# image_layers <image> - vypise vrstvy image (RootFS.Layers), jednu na radek; navratovy kod = kod dockeru
image_layers() {
    docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$(image_ref "$1")" 2>/dev/null | LC_ALL=C grep -v '^$'
}

# check_base_layers <image vzoroveho webu> <zakladni image> - image vzoroveho webu vychazi ze zavislostniho
# image tehoz tagu: vrstvy zakladu jsou zacatkem jeho vrstev. Rozdil = image nepochazeji z jednoho sestaveni
# (vzorovy image sestaven nad starsim zakladem, nebo po zmene zakladu sestaven jen nektery cil). Srovnava se
# jen tehdy, kdyz se v tomto behu kontroluje i zaklad (ten je pak overeny a pri --pull always cerstve
# stazeny); jinak SKIP.
READY_IMAGES=" "
check_base_layers() {
    local name="$1" base="$2" desc n
    desc="vychazi z image $base tehoz tagu (vrstvy zakladu jsou zacatkem vrstev image)"
    case " ${IMAGES[*]} " in
        *" $base "*) ;;
        *)
            skip "$name" "$desc" "image $base se v tomto behu nekontroluje (srovnani: spust bez vyberu image, nebo pridej $base)"
            return 0
            ;;
    esac
    case "$READY_IMAGES" in
        *" $base "*) ;;
        *)
            skip "$name" "$desc" "image $base neni k dispozici (viz jeho kontroly vyse)"
            return 0
            ;;
    esac
    image_layers "$base" > "$TMP/base.layers"
    image_layers "$name" > "$TMP/image.layers"
    n="$(wc -l < "$TMP/base.layers" | tr -d '[:space:]')"
    if [ "$n" -gt 0 ] && [ "$(wc -l < "$TMP/image.layers" | tr -d '[:space:]')" -gt "$n" ] \
        && [ "$(head -n "$n" "$TMP/image.layers")" = "$(cat "$TMP/base.layers")" ]; then
        ok "$name" "$desc: $n vrstev zakladu"
    else
        fail "$name" "$desc" "vrstvy image $(image_ref "$base") nejsou zacatkem vrstev image $(image_ref "$name") - image nepochazeji z jednoho sestaveni; sestav znovu vsechny: make images
vrstvy zakladu ($n):
$(list_head "$TMP/base.layers")
vrstvy image:
$(list_head "$TMP/image.layers")"
    fi
}

# check_engine <image> - kontroly kodu enginu v image vzoroveho webu
check_engine() {
    local name="$1"
    check "$name" "perl -c pwe.fcgi" perl -c /PWE/PWE/pwe.fcgi
    # (SC2086: seznam ENGINE_EXCLUDES se ma rozdelit na jednotlive argumenty)
    # shellcheck disable=SC2016,SC2086
    check "$name" "obsah /PWE (LICENSE, PWE, webapps) a /PWE/PWE (soubory a adresare enginu, bez t/, docker/ a tools/)" sh -c '
        rc=0
        cd /PWE/PWE || { echo "chybi adresar /PWE/PWE"; exit 1; }
        for f in pwe.fcgi debug.cgi VERSION favicon.ico README.md CHANGELOG.md /PWE/LICENSE; do
            [ -f "$f" ] || { echo "chybi soubor $f"; rc=1; }
        done
        for d in Libs Pages Sites Services Entities templates assets; do
            [ -d "$d" ] || { echo "chybi adresar $d"; rc=1; }
        done
        for x in "$@"; do
            [ ! -e "$x" ] || { echo "/PWE/PWE/$x v image byt nema"; rc=1; }
        done
        others="$(ls -A /PWE | grep -v -x -e LICENSE -e PWE -e webapps | tr "\n" " ")"
        [ -z "$others" ] || { echo "v /PWE je krome LICENSE, PWE a webapps jeste: $others"; rc=1; }
        exit $rc' sh $ENGINE_EXCLUDES
    check_engine_version "$name"
}

# check_sample_web <image vzoroveho webu> <web> <profil> - vzorovy web v image tak, jak ho zalozilo sestaveni.
# Kontejner bezi s korenovym souborovym systemem jen pro cteni (--read-only) jen proto, aby entrypoint nemohl
# nic zalozit: pracovni adresare a symlink conf/database.conf tak musi byt v image uz ze sestaveni. Engine
# se tu NESPOUSTI - kontrola nerika, ze image s --read-only obslouzi request (to overuje
# check_static_request ro: s --read-only musi byt pracovni adresare webu zapisovatelne, napr. tmpfs).
check_sample_web() {
    local name="$1" web="$2" profile="$3" out rc desc
    desc="vzorovy web $web ze sestaveni (--read-only: entrypoint nic nezalozi): ENV, pracovni adresar, soubory, pracovni adresare, conf/database.conf, bez varovani entrypointu"
    # shellcheck disable=SC2016
    out="$(docker run "${RUN_ARGS[@]}" --read-only "$(image_ref "$name")" sh -c '
        web="$1"; profile="$2"; home="/PWE/webapps/$web"; rc=0
        [ "${PWE_CONF_pwe_home:-}" = "$home" ] || { echo "PWE_CONF_pwe_home je \"${PWE_CONF_pwe_home:-}\", ocekavano $home"; rc=1; }
        [ "${PWE_CONF_pwe_core:-}" = /PWE/PWE ] || { echo "PWE_CONF_pwe_core je \"${PWE_CONF_pwe_core:-}\", ocekavano /PWE/PWE"; rc=1; }
        [ "${PWE_PROFILE:-}" = "$profile" ] || { echo "PWE_PROFILE je \"${PWE_PROFILE:-}\", ocekavano $profile"; rc=1; }
        [ "$(pwd)" = "$home" ] || { echo "pracovni adresar je $(pwd), ocekavano $home"; rc=1; }
        others="$(ls -A /PWE/webapps 2>/dev/null | grep -v -x -F "$web" | tr "\n" " ")"
        [ -z "$others" ] || { echo "v /PWE/webapps je krome $web jeste: $others"; rc=1; }
        for f in conf/web.conf Pages/default/default.pm Sites/Default/Default.pm; do
            [ -f "$home/$f" ] || { echo "chybi soubor $home/$f"; rc=1; }
        done
        for d in ramdisk/templates sessions uploadfile log; do
            if [ ! -d "$home/$d" ]; then echo "chybi pracovni adresar $home/$d (ma vzniknout pri sestaveni)"; rc=1
            elif [ -n "$(ls -A "$home/$d")" ]; then echo "pracovni adresar $home/$d neni prazdny (docasna data z pracovni kopie v image)"; rc=1
            fi
        done
        [ ! -e "$home/conf/local.env" ] || { echo "$home/conf/local.env v image byt nema"; rc=1; }
        link="$home/conf/database.conf"
        if [ "$profile" = static ]; then
            if [ -e "$link" ] || [ -L "$link" ]; then echo "web bez databaze nema mit conf/database.conf"; rc=1; fi
        else
            [ -f "$home/conf/$profile.conf" ] || { echo "chybi $home/conf/$profile.conf"; rc=1; }
            target="$(readlink "$link" 2>/dev/null || true)"
            [ "$target" = "$profile.conf" ] || { echo "conf/database.conf ukazuje na \"$target\", ocekavano $profile.conf"; rc=1; }
        fi
        exit $rc' sh "$web" "$profile" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "${out:-prikaz skoncil kodem $rc bez vystupu}"
    fi
    check_sample_warning "$name" "$web"
    if [ "$COMPARE_TREE" = 1 ]; then
        check_web_files "$name" "$web"
    fi
}

# check_sample_warning <image vzoroveho webu> <web> - entrypoint pri startu serveru (nastavena FCGI_SOCKET_PATH)
# varuje, ze bezi vzorovy web zapeceny v image: ukazka, kde ma kazdy navstevnik skupinu admin - neni urcena
# pro verejny provoz. Misto enginu se spousti "true": varovani vypisuje entrypoint jeste pred prikazem,
# server se tak nemusi startovat ani zastavovat. Ocekava se prave jeden radek - prave toto varovani.
check_sample_warning() {
    local name="$1" web="$2" desc out rc prefix
    desc="entrypoint pri startu serveru (FCGI_SOCKET_PATH) varuje, ze bezi vzorovy web $web (neni urcen pro verejny provoz)"
    prefix="[entrypoint] VAROVANI: bezi vzorovy web $web "
    out="$(docker run "${RUN_ARGS[@]}" -e FCGI_SOCKET_PATH=:7779 "$(image_ref "$name")" true 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "${out#"$prefix"}" != "$out" ] && [ "${out%$'\n'*}" = "$out" ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "ocekavan jediny radek \"${prefix}...\" a kod 0; kod $rc, vystup:
${out:-(zadny)}"
    fi
}

# readonly_args <web> - do pole RO_ARGS da volby docker run pro beh s korenovym souborovym systemem jen pro
# cteni: --read-only a tmpfs pres pracovni adresare webu, do kterych engine zapisuje (adresare zalozene pri
# sestaveni slouzi jako pripojne body). Jen s --read-only, bez nich, engine neobslouzi ani jeden request.
RO_ARGS=()
readonly_args() {
    local home="/PWE/webapps/$1" dir
    RO_ARGS=(--read-only)
    for dir in ramdisk sessions uploadfile log; do
        RO_ARGS+=(--tmpfs "$home/$dir")
    done
}

# run_default_cmd <image> [volby docker run ...] - spusti VYCHOZI prikaz image (CMD perl /PWE/PWE/pwe.fcgi pres
# entrypoint) s prostredim jednoho requestu: bez FCGI_SOCKET_PATH engine obslouzi jeden request v rezimu CGI
# a skonci. Stdout jde do $TMP/cgi.out, stderr do $TMP/cgi.err; vraci navratovy kod kontejneru.
# (${1+"$@"}: prazdny seznam voleb nesmi pod set -u skoncit chybou ani ve starsim bash.)
run_default_cmd() {
    local name="$1"
    shift
    docker run "${RUN_ARGS[@]}" -e REQUEST_METHOD=GET -e "QUERY_STRING=page=default&func=default" -e SCRIPT_FILENAME=/pwe.fcgi \
        -e REMOTE_ADDR=127.0.0.1 -e HTTP_HOST=localhost -e SERVER_NAME=localhost -e HTTP_USER_AGENT=smoke-images ${1+"$@"} \
        "$(image_ref "$name")" > "$TMP/cgi.out" 2> "$TMP/cgi.err"
}

# cgi_output - vystup posledniho run_default_cmd do duvodu selhani (zkraceny stdout a stderr)
cgi_output() {
    echo "stdout (prvnich 15 radku):"
    sed -n '1,15s/^/  /p' "$TMP/cgi.out"
    echo "stderr (prvnich 15 radku):"
    sed -n '1,15s/^/  /p' "$TMP/cgi.err"
}

# check_static_request <image> [ro] - image vzoroveho webu bez databaze: vychozi prikaz image vrati stranku
# vzoroveho webu (jeden request CGI). S argumentem "ro" bezi kontejner s korenovym souborovym systemem jen
# pro cteni a s pracovnimi adresari webu jako tmpfs (readonly_args): overuje, ze image v tomto rezimu request
# opravdu obslouzi a ze engine nezapisuje jinam nez do pracovnich adresaru.
check_static_request() {
    local name="$1" mode="${2:-}" desc rc reason=""
    if [ "$mode" = ro ]; then
        desc="vychozi prikaz image s korenovym souborovym systemem jen pro cteni (--read-only, pracovni adresare webu jako tmpfs): jeden request v rezimu CGI vrati stranku vzoroveho webu $STATIC_WEB"
        readonly_args "$STATIC_WEB"
        run_default_cmd "$name" "${RO_ARGS[@]}"
    else
        desc="vychozi prikaz image: jeden request v rezimu CGI vrati stranku vzoroveho webu $STATIC_WEB"
        run_default_cmd "$name"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        reason="engine skoncil kodem $rc"
    fi
    if ! LC_ALL=C grep -qi '^Content-Type: text/html' "$TMP/cgi.out"; then
        reason="${reason:+$reason
}odpoved nema hlavicku Content-Type: text/html"
    fi
    if LC_ALL=C grep -qi '^Status: [45]' "$TMP/cgi.out"; then
        reason="${reason:+$reason
}odpoved ma chybovy stav: $(LC_ALL=C grep -i '^Status: ' "$TMP/cgi.out" | head -1 | tr -d '\r')"
    fi
    if ! LC_ALL=C grep -q '</html>' "$TMP/cgi.out"; then
        reason="${reason:+$reason
}telo odpovedi neni kompletni HTML (chybi </html>)"
    fi
    if LC_ALL=C grep -q -F -e '[E]' -e '[entrypoint] VAROVANI' "$TMP/cgi.err"; then
        reason="${reason:+$reason
}engine nebo entrypoint zapsal chybu na stderr"
    fi
    if [ "$mode" = ro ] && LC_ALL=C grep -q -i 'read-only file system' "$TMP/cgi.err"; then
        reason="${reason:+$reason
}zapis mimo pracovni adresare webu (ramdisk, sessions, uploadfile, log) - na stderr je \"Read-only file system\""
    fi
    if [ -z "$reason" ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "$reason
$(cgi_output)"
    fi
}

# check_db_start <image vzoroveho webu> <profil> - databazovy profil bez databaze (kontroly bezi bez site):
# vychozi prikaz image musi dojit az k pripojeni k databazi - nacist web, konfiguraci profilu
# (conf/database.conf -> <profil>.conf) i ovladac - a teprve na nem skoncit. Jeden pokus o pripojeni
# (trayconnect=1), at se neceka.
check_db_start() {
    local name="$1" profile="$2" desc rc reason=""
    desc="vychozi prikaz image bez databaze: engine nacte konfiguraci a ovladac profilu $profile a skonci az na pripojeni"
    run_default_cmd "$name" -e PWE_CONF_dbi_db1_trayconnect=1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        reason="engine skoncil kodem 0, bez databaze ma start selhat"
    fi
    if ! LC_ALL=C grep -q "Connect to $profile dbid:db1 " "$TMP/cgi.err"; then
        reason="${reason:+$reason
}v logu chybi pokus o pripojeni \"Connect to $profile dbid:db1 ...\" (konfigurace profilu se nenacetla?)"
    fi
    if ! LC_ALL=C grep -q 'Unable connect to db1' "$TMP/cgi.err"; then
        reason="${reason:+$reason
}engine neskoncil hlaskou \"Unable connect to db1\""
    fi
    if LC_ALL=C grep -q -e 'install_driver' -e "Can't locate" -e '\[entrypoint\] VAROVANI' "$TMP/cgi.err"; then
        reason="${reason:+$reason
}chybi ovladac databaze nebo modul, nebo varuje entrypoint"
    fi
    if [ -z "$reason" ]; then
        ok "$name" "$desc"
    else
        fail "$name" "$desc" "$reason
$(cgi_output)"
    fi
}

# check_example <image vzoroveho webu> <web> <profil> <zakladni image> - kontroly image vzoroveho webu:
# zaklad, engine, vzorovy web a vychozi prikaz image
check_example() {
    local name="$1" web="$2" profile="$3" base="$4"
    check_base_layers "$name" "$base"
    check_engine "$name"
    check_sample_web "$name" "$web" "$profile"
    if [ "$profile" = static ]; then
        check_static_request "$name"
        check_static_request "$name" ro
    else
        check_db_start "$name" "$profile"
    fi
}

# check_image <image> - vsechny kontroly jednoho image
check_image() {
    local name="$1"
    image_ready "$name" || return 0
    READY_IMAGES="$READY_IMAGES$name "
    check_base_common "$name"
    case "$name" in
        pwe-base)
            check_base_function
            check_no_drivers pwe-base
            check_deps_only pwe-base
            ;;
        pwe-mariadb)
            check pwe-mariadb "DBD::mysql a DBD::MariaDB" perl -e "$PERL_HAS" DBD::mysql DBD::MariaDB
            check_no_drivers pwe-mariadb DBD::Pg
            check_deps_only pwe-mariadb
            ;;
        pwe-mysql)
            check pwe-mysql "DBD::mysql" perl -e "$PERL_HAS" DBD::mysql
            check_no_drivers pwe-mysql DBD::MariaDB DBD::Pg
            check_deps_only pwe-mysql
            ;;
        pwe-postgres)
            check pwe-postgres "DBD::Pg" perl -e "$PERL_HAS" DBD::Pg
            check_no_drivers pwe-postgres DBD::mysql DBD::MariaDB
            check_deps_only pwe-postgres
            ;;
        pwe-debugger)
            check pwe-debugger "ovladace vsech databazi" perl -e "$PERL_HAS" DBD::mysql DBD::MariaDB DBD::Pg
            # rozsireni "Perl" pro VS Code (richterger.perl) chce jazykovy server aspon ve sve verzi
            # shellcheck disable=SC2016
            check pwe-debugger "Perl::LanguageServer >= $LANGUAGESERVER_MIN" perl -Mversion -e '
                my ($min) = @ARGV;
                if (!eval { require Perl::LanguageServer; 1 }) { print "modul Perl::LanguageServer nejde nacist\n"; exit 1 }
                my $v = Perl::LanguageServer->VERSION;
                if (version->parse($v) < version->parse($min)) { print "Perl::LanguageServer $v je starsi nez $min\n"; exit 1 }' \
                "$LANGUAGESERVER_MIN"
            # shellcheck disable=SC2016
            check pwe-debugger "perlcritic, perltidy a curl" sh -c '
                rc=0
                for p in perlcritic perltidy curl; do
                    "$p" --version >/dev/null 2>&1 || { echo "program $p chybi nebo nejde spustit"; rc=1; }
                done
                exit $rc'
            check_deps_only pwe-debugger
            ;;
        pwe-example-static)
            check_no_drivers pwe-example-static
            check_example pwe-example-static "$STATIC_WEB" static pwe-base
            ;;
        pwe-example-mariadb)
            check pwe-example-mariadb "DBD::mysql a DBD::MariaDB" perl -e "$PERL_HAS" DBD::mysql DBD::MariaDB
            check_example pwe-example-mariadb "$DB_WEB" mariadb pwe-mariadb
            ;;
        pwe-example-mysql)
            check pwe-example-mysql "DBD::mysql" perl -e "$PERL_HAS" DBD::mysql
            check_example pwe-example-mysql "$DB_WEB" mysql pwe-mysql
            ;;
        pwe-example-postgres)
            check pwe-example-postgres "DBD::Pg" perl -e "$PERL_HAS" DBD::Pg
            check_example pwe-example-postgres "$DB_WEB" postgres pwe-postgres
            ;;
    esac
    # srovnani s pracovni kopii, ktere se tyka kazdeho image: vstupni skript (ma ho uz pwe-base)
    if [ "$COMPARE_TREE" = 1 ]; then
        check_entrypoint_file "$name"
    else
        case "$name" in
            pwe-example-*) check_tree_skip "$name" "PWE/VERSION, soubory enginu a vzoroveho webu, entrypoint" "overuje se jen vnitrni soulad image" ;;
            *)             check_tree_skip "$name" "entrypoint" ;;
        esac
    fi
    return 0
}

if [ "$COMPARE_TREE" = 1 ]; then TREE_INFO="ano"; else TREE_INFO="ne"; fi
echo "[smoke-images] registr=$REGISTRY tag=$TAG verze=$VERSION platforma=${PLATFORM:-vychozi} pull=$PULL srovnani-s-pracovni-kopii=$TREE_INFO image=${IMAGES[*]}" >&2

for image in "${IMAGES[@]}"; do
    check_image "$image"
done

SKIP_INFO=""
if [ "$SKIPPED" -gt 0 ]; then SKIP_INFO=" (preskoceno: $SKIPPED)"; fi
if [ "$FAILED" -gt 0 ]; then
    echo "[smoke-images] FAIL: selhalo $FAILED z $CHECKS kontrol$SKIP_INFO" >&2
    exit 1
fi
echo "[smoke-images] OK: $CHECKS kontrol$SKIP_INFO" >&2
exit 0
