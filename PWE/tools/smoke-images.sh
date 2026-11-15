#!/bin/bash
# Kourove kontroly image PWE: kazdy image obsahuje to, co ma, a nic, co mit nema.
#
#   PWE/tools/smoke-images.sh [--platform <platforma>] [--pull never|always] [jmeno image ...]
#
#   PWE/tools/smoke-images.sh                              # vsech 7 image z lokalniho Dockeru (po make images)
#   PWE/tools/smoke-images.sh pwe pwe-debugger             # jen vybrane image (lze psat i base, mariadb, debugger...)
#   PWE/tools/smoke-images.sh --platform linux/arm64       # image jine platformy (na stroji amd64 bezi v emulaci QEMU)
#   PWE/tools/smoke-images.sh --pull always                # image z registru misto lokalnich
#   PWE_IMAGE_TAG=master PWE/tools/smoke-images.sh --pull always --platform linux/arm64   # publikovany image jine vetve
#
# Image: pwe-base pwe pwe-static pwe-mariadb pwe-mysql pwe-postgres pwe-debugger (bez jmena = vsechny).
# Registr a tag urcuje PWE/tools/lib/images.sh: PWE_IMAGE_REGISTRY (vychozi ghcr.io/kukam) a PWE_IMAGE_TAG
# (vychozi = aktualni vetev gitu). Stejny skript spousti pipeline .github/workflows/images.yml nad cerstve
# sestavenymi image pred publikaci (linux/amd64 i linux/arm64).
#
# Volby:
#   --platform P    platforma kontejneru (docker run --platform), napr. linux/arm64; bez volby vychozi platforma
#                   Dockeru. U linux/amd64 a linux/arm64 se overuje, ze kontejner na ni opravdu bezi.
#   --pull never    (vychozi) kontroluje se jen to, co je v lokalnim Dockeru - nikdy se potichu nestahne starsi
#                   image z registru. Chybejici image = FAIL a jeho dalsi kontroly se preskoci.
#   --pull always   kazdy image se pred kontrolou stahne z registru (docker pull). POZOR: nahradi lokalni image
#                   pod stejnym tagem.
#
# Co se kontroluje (prikazy bezi pres entrypoint image, bez site):
#   vsechny image   kontejner se spusti; Perl moduly zakladu jdou nacist; programy a soubory zakladu existuji
#                   (/usr/bin/sass, /usr/bin/identify, /usr/bin/convert, openssl, casova zona Europe/Prague)
#   pwe-base        convert a identify nad skutecnym obrazkem, sass prelozi scss, openssl a TZ funguji;
#                   zadny ovladac databaze
#   pwe             perl -c pwe.fcgi; obsah /PWE/PWE (bez t/ a docker/); VERSION a popisky image odpovidaji
#                   PWE/VERSION; seznam souboru enginu v image = pracovni kopie PWE/ bez t/, docker/ a bez toho,
#                   co vynechava .dockerignore (stary image nebo soubor mimo COPY v Dockerfile = FAIL)
#   pwe-static      zadny ovladac databaze
#   pwe-mariadb     DBD::mysql a DBD::MariaDB;   pwe-mysql   DBD::mysql;   pwe-postgres   DBD::Pg
#   pwe-debugger    vsechny tri ovladace, Perl::LanguageServer >= 2.6.2, perlcritic, perltidy, curl
#   vse krome pwe   v image neni kod enginu (/PWE/PWE/pwe.fcgi)
#
# Vystup: jeden radek na kontrolu, "OK   <image>: <popis>" nebo "FAIL <image>: <popis>" a pod nim odsazeny
# duvod (vystup prikazu). V GitHub Actions se k selhani prida anotace ::error.
# Navratovy kod: 0 = vsechny kontroly prosly, 1 = aspon jedna selhala, 2 = spatne pouziti nebo chybi docker.
set -u
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/images.sh disable=SC1091
. "$ROOT/PWE/tools/lib/images.sh"

ALL_IMAGES="pwe-base pwe pwe-static pwe-mariadb pwe-mysql pwe-postgres pwe-debugger"

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
        -h | --help)  usage; exit 0 ;;
        -*)           echo "Neznama volba $1 (napoveda: $0 --help)" >&2; exit 2 ;;
        *)
            case "$1" in
                base | static | mariadb | mysql | postgres | debugger) name="pwe-$1" ;;
                *) name="$1" ;;
            esac
            case " $ALL_IMAGES " in
                *" $name "*) IMAGES+=("$name") ;;
                *) echo "Neznamy image $1 (image: $ALL_IMAGES)" >&2; exit 2 ;;
            esac
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
if [ ${#IMAGES[@]} -eq 0 ]; then
    read -r -a IMAGES <<< "$ALL_IMAGES"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[smoke-images] chybi prikaz docker" >&2
    exit 2
fi

REGISTRY="$(pwe_image_registry)"
TAG="$(pwe_image_tag)" || exit 2
VERSION="$(tr -d '[:space:]' < "$ROOT/PWE/VERSION")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/smoke-images.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Spolecne volby docker run: jen lokalni image (pripadne docker pull dela image_ready), bez site.
RUN_ARGS=(--rm --pull never --network none)
[ -n "$PLATFORM" ] && RUN_ARGS+=(--platform "$PLATFORM")

CHECKS=0
FAILED=0

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

# check_no_drivers <image> - image bez ovladacu databazi
check_no_drivers() {
    check "$1" "bez ovladacu databazi" perl -e "$PERL_HASNT" DBD::mysql DBD::MariaDB DBD::Pg
}

# check_no_engine <image> - kod enginu je jen v image pwe (jinde se mountuje nebo kopiruje pres COPY --from)
check_no_engine() {
    check "$1" "bez kodu enginu" sh -c '
        [ ! -e /PWE/PWE/pwe.fcgi ] || { echo "/PWE/PWE/pwe.fcgi v image byt nema"; exit 1; }'
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

# list_head <soubor> - nejvys 20 radku souboru odsazenych o dve mezery, pak pocet zbylych
list_head() {
    local total
    total="$(wc -l < "$1" | tr -d '[:space:]')"
    sed -n '1,20s/^/  /p' "$1"
    if [ "$total" -gt 20 ]; then echo "  ... a dalsich $((total - 20))"; fi
}

# check_pwe_files - seznam souboru enginu v image pwe musi odpovidat pracovni kopii: PWE/ bez t/ (testy)
# a docker/ (build image) a bez toho, co z kontextu buildu vynechava .dockerignore. Odhali adresar nebo
# soubor enginu, ktery chybi ve vyctu COPY v PWE/docker/Dockerfile, i image sestaveny ze starsiho stavu.
check_pwe_files() {
    local desc="soubory enginu v /PWE/PWE = pracovni kopie PWE/ (bez t/, docker/ a .dockerignore)" out rc reason
    # shellcheck disable=SC2016
    docker run "${RUN_ARGS[@]}" "$(image_ref pwe)" sh -c 'cd /PWE/PWE && find . \( -type f -o -type l \) -print' \
        > "$TMP/image.raw" 2> "$TMP/image.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        out="$(cat "$TMP/image.err")"
        fail pwe "$desc" "${out:-vypis souboru v image skoncil kodem $rc bez vystupu}"
        return 0
    fi
    sed 's#^\./##' "$TMP/image.raw" | LC_ALL=C sort > "$TMP/image.lst"
    (cd "$ROOT" && find PWE \( -path PWE/t -o -path PWE/docker \) -prune -o \( -type f -o -type l \) -print) \
        | dockerignore_filter "$ROOT/.dockerignore" | sed 's#^PWE/##' | LC_ALL=C sort > "$TMP/tree.lst"
    LC_ALL=C comm -23 "$TMP/tree.lst" "$TMP/image.lst" > "$TMP/only-tree.lst"
    LC_ALL=C comm -13 "$TMP/tree.lst" "$TMP/image.lst" > "$TMP/only-image.lst"
    if [ ! -s "$TMP/only-tree.lst" ] && [ ! -s "$TMP/only-image.lst" ] && [ -s "$TMP/tree.lst" ]; then
        ok pwe "$desc: $(wc -l < "$TMP/tree.lst" | tr -d '[:space:]') souboru"
        return 0
    fi
    reason=""
    if [ ! -s "$TMP/tree.lst" ]; then
        reason="v pracovni kopii $ROOT/PWE nejsou zadne soubory enginu"
    fi
    if [ -s "$TMP/only-tree.lst" ]; then
        reason="${reason:+$reason
}v image chybi (jsou v pracovni kopii; image je starsi, nebo cesta neni ve vyctu COPY v PWE/docker/Dockerfile):
$(list_head "$TMP/only-tree.lst")"
    fi
    if [ -s "$TMP/only-image.lst" ]; then
        reason="${reason:+$reason
}v image navic (v pracovni kopii nejsou, nebo do image nepatri - t/, docker/, .dockerignore; image je starsi, nebo je chyba ve vyctu COPY):
$(list_head "$TMP/only-image.lst")"
    fi
    fail pwe "$desc" "$reason"
}

# check_pwe_labels - popisky image pwe: title a verze enginu (tag pwe:<verze> nesmi ukazovat na jiny kod);
# commit a cas buildu se jen vypisuji (lokalni build z rozpracovaneho stromu commit nema)
check_pwe_labels() {
    local title version revision created reason=""
    title="$(image_label pwe org.opencontainers.image.title)"
    version="$(image_label pwe org.opencontainers.image.version)"
    revision="$(image_label pwe org.opencontainers.image.revision)"
    created="$(image_label pwe org.opencontainers.image.created)"
    if [ "$title" != "pwe" ]; then
        reason="popisek org.opencontainers.image.title je '$title', ocekavano 'pwe'"
    fi
    if [ "$version" != "$VERSION" ]; then
        reason="${reason:+$reason
}popisek org.opencontainers.image.version je '$version', ocekavano '$VERSION' (PWE/VERSION)"
    fi
    if [ -z "$reason" ]; then
        ok pwe "popisky image: title=pwe, version=$VERSION (revision=${revision:-neuvedena}, created=${created:-neuveden})"
    else
        fail pwe "popisky image: title=pwe, version=$VERSION" "$reason"
    fi
}

# check_image <image> - vsechny kontroly jednoho image
check_image() {
    local name="$1"
    image_ready "$name" || return 0
    check_base_common "$name"
    case "$name" in
        pwe-base)
            check_base_function
            check_no_drivers pwe-base
            ;;
        pwe)
            check pwe "perl -c pwe.fcgi" perl -c /PWE/PWE/pwe.fcgi
            # shellcheck disable=SC2016
            check pwe "obsah /PWE/PWE (soubory a adresare enginu, bez t/ a docker/)" sh -c '
                rc=0
                cd /PWE/PWE || { echo "chybi adresar /PWE/PWE"; exit 1; }
                for f in pwe.fcgi debug.cgi VERSION favicon.ico README.md CHANGELOG.md /PWE/LICENSE; do
                    [ -f "$f" ] || { echo "chybi soubor $f"; rc=1; }
                done
                for d in Libs Pages Sites Services Entities templates assets tools; do
                    [ -d "$d" ] || { echo "chybi adresar $d"; rc=1; }
                done
                for x in t docker; do
                    [ ! -e "$x" ] || { echo "/PWE/PWE/$x v image byt nema"; rc=1; }
                done
                exit $rc'
            # shellcheck disable=SC2016
            check pwe "VERSION = $VERSION (PWE/VERSION pracovni kopie)" sh -c '
                v="$(tr -d "[:space:]" < /PWE/PWE/VERSION)"
                [ "$v" = "$1" ] || { echo "v image je verze $v, v pracovni kopii $1"; exit 1; }' sh "$VERSION"
            check_pwe_labels
            check_pwe_files
            ;;
        pwe-static)
            check_no_drivers pwe-static
            ;;
        pwe-mariadb)
            check pwe-mariadb "DBD::mysql a DBD::MariaDB" perl -e "$PERL_HAS" DBD::mysql DBD::MariaDB
            ;;
        pwe-mysql)
            check pwe-mysql "DBD::mysql" perl -e "$PERL_HAS" DBD::mysql
            ;;
        pwe-postgres)
            check pwe-postgres "DBD::Pg" perl -e "$PERL_HAS" DBD::Pg
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
            ;;
    esac
    if [ "$name" != "pwe" ]; then
        check_no_engine "$name"
    fi
    return 0
}

echo "[smoke-images] registr=$REGISTRY tag=$TAG verze=$VERSION platforma=${PLATFORM:-vychozi} pull=$PULL image=${IMAGES[*]}" >&2

for image in "${IMAGES[@]}"; do
    check_image "$image"
done

if [ "$FAILED" -gt 0 ]; then
    echo "[smoke-images] FAIL: selhalo $FAILED z $CHECKS kontrol" >&2
    exit 1
fi
echo "[smoke-images] OK: $CHECKS kontrol" >&2
exit 0
