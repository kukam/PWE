#!/bin/bash
# Jmena image PWE pro shell nastroje v PWE/tools/ (jediny zdroj pravdy pro registr a tag).
#
# Pouziti ve skriptu (bash):
#   . "$ROOT/PWE/tools/lib/images.sh"
#   IMAGE="$(pwe_tool_image)"                 # image pro nastroje (testy, perl -c, CGI request)
#   pwe_image_missing_hint "$IMAGE" run-tests # rada na stderr, kdyz image neni v lokalnim Dockeru
#   docker pull "$(pwe_image pwe-mariadb)"    # ghcr.io/kukam/pwe-mariadb:<verze>
#   pwe_image "$(pwe_profile_image static)"   # ghcr.io/kukam/pwe-base:<verze> (web bez databaze)
#
# Primo z prikazove radky, Makefile nebo jineho jazyka:
#   bash PWE/tools/lib/images.sh pwe_image pwe-debugger
#   bash PWE/tools/lib/images.sh pwe_image_tag
#   bash PWE/tools/lib/images.sh pwe_image_version
#   bash PWE/tools/lib/images.sh pwe_image_names
#
# Image PWE (pwe_image_names):
#   zavislostni image   pwe-base, pwe-mariadb, pwe-mysql, pwe-postgres, pwe-debugger - jen knihovny, zadny
#                       kod enginu a zadny web (engine dostavaji mountem repozitare, nebo ho prida image webu)
#   vzorove weby        pwe-example-static, pwe-example-mariadb, pwe-example-mysql, pwe-example-postgres
#                       = zavislostni image + engine + vzorovy web
# Profil static (web bez databaze) bezi nad pwe-base, databazove profily nad pwe-<profil> (pwe_profile_image).
#
# Tagy: kazdy image PWE ma prave dva - <verze> (obsah PWE/VERSION) a latest. Tagy podle vetve gitu
# neexistuji: vychozi tag nastroju je verze enginu v pracovni kopii a na gitu ani na vetvi nezavisi.
#
# Promenne prostredi:
#   PWE_IMAGE_REGISTRY   registr a jmenny prostor image (vychozi ghcr.io/kukam)
#   PWE_IMAGE_TAG        tag image (vychozi = verze enginu z PWE/VERSION, viz pwe_image_tag), napr. latest
#                        nebo starsi verze. Musi to byt platny tag image (pwe_image_tag_valid), jinak
#                        funkce skonci chybou (kod 2).
#   PWE_TEST_IMAGE       uplne prepsani image nastroju (cele jmeno vcetne tagu), ma prednost pred obema
#
# Stejna pravidla ma pro Perl nastroje PWE::ToolEnv (PWE/tools/lib/PWE/ToolEnv.pm) - obe implementace
# musi davat stejny vysledek (hlidaji to PWE/t/14-tools.t a PWE/t/21-image-tools.t).

# Cesta k tomuto souboru: v bash BASH_SOURCE, pri nacteni ze zsh (vychozi shell macOS) ${(%):-%x}
# - bez toho by se koren repozitare urcil spatne a pwe_image_version by cetl cizi soubor PWE/VERSION.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _PWE_IMAGES_SELF="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    eval '_PWE_IMAGES_SELF="${(%):-%x}"'
else
    _PWE_IMAGES_SELF="$0"
fi

# Koren repozitare = tri urovne nad timto souborem (<repo>/PWE/tools/lib/images.sh). "unset CDPATH" (jen
# v podshellu): cd nehleda relativni cestu v CDPATH/cdpath. ">/dev/null": interaktivni zsh (a bash s CDPATH)
# i pripadny hook chpwd vypisuji pri cd na stdout - koren by mel vic radku a soubor PWE/VERSION by se nenasel.
_PWE_IMAGES_ROOT="$(unset CDPATH; cd -- "$(dirname -- "${_PWE_IMAGES_SELF}")/../../.." > /dev/null && pwd)"

# pwe_image_registry - vypise registr a jmenny prostor image (bez koncoveho lomitka).
pwe_image_registry() {
    local registry="${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}"
    printf '%s\n' "${registry%/}"
}

# pwe_image_tag_valid <tag> - vraci 0, kdyz je <tag> platny tag image, tj. odpovida
# ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$, jinak 1. Nic nevypisuje. Znaky jsou vyjmenovane (ne rozsahy A-Z),
# aby vysledek nezavisel na locale, a vzor funguje v bash 3.2, bash 5 i zsh.
pwe_image_tag_valid() {
    local tag="${1:-}"
    case "${tag}" in
        '' | [.-]*) return 1 ;;
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*) return 1 ;;
    esac
    [ "${#tag}" -le 128 ]
}

# pwe_image_git_repo - vraci 0, kdyz je k dispozici git a koren repozitare PWE je korenem pracovni kopie
# gitu. --show-prefix je prazdny jen v koreni pracovni kopie: repozitar PWE rozbaleny uvnitr ciziho
# gitoveho repozitare (napr. archiv v podadresari) se za pracovni kopii nepovazuje - cizi commit ani stav
# se nepouzije. Git slouzi jen build-images.sh (popisek revision, kontrola necommitnutych zmen pred
# --push); tag image na nem nezavisi.
pwe_image_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    [ -z "$(git -C "${_PWE_IMAGES_ROOT}" rev-parse --show-prefix 2>/dev/null || echo x)" ]
}

# pwe_image_version - vypise verzi enginu = obsah souboru PWE/VERSION bez bilych znaku (napr. 2.2.1).
# Je to tag, pod kterym image stavi build-images.sh, a vychozi tag nastroju (pwe_image_tag). Verze musi
# mit tvar X.Y.Z (tri cisla oddelena teckami). Kdyz soubor chybi, nejde precist nebo ma jiny obsah,
# vypise hlasku na stderr, na stdout nic a vrati 2. Git ani vetev se nepouzivaji.
pwe_image_version() {
    local file="${_PWE_IMAGES_ROOT}/PWE/VERSION"
    local version="" dots=""
    if [ -f "${file}" ] && [ -r "${file}" ]; then
        version="$(tr -d '[:space:]' < "${file}" 2>/dev/null)" || version=""
    fi
    # jen cislice a tecky, zadna prazdna cast (uvodni, koncova nebo dvojita tecka) a prave dve tecky
    dots="${version//[0123456789]/}"
    case "${version}" in
        '' | *[!0123456789.]* | .* | *. | *..*) dots="" ;;
    esac
    if [ "${dots}" != ".." ]; then
        printf '%s\n' "Soubor ${file} neobsahuje verzi enginu tvaru X.Y.Z (obsah: '${version}') - verzi image nelze urcit. Oprav PWE/VERSION, nebo zadej tag vyslovne: PWE_IMAGE_TAG=<tag> (napr. latest)" >&2
        return 2
    fi
    printf '%s\n' "${version}"
}

# pwe_image_tag - vypise tag image: PWE_IMAGE_TAG (beze zmeny), jinak verzi enginu z PWE/VERSION
# (pwe_image_version). PWE_IMAGE_TAG, ktery neni platny tag image (napr. nazev vetve s lomitkem), se
# nepouzije: funkce vypise hlasku na stderr, na stdout nic a vrati 2; stejne skonci, kdyz PWE_IMAGE_TAG
# zadan neni a PWE/VERSION verzi neobsahuje. Volajici pod "set -e" tim skonci (X="$(pwe_image_tag)");
# "export X=$(...)" a "local X=$(...)" navratovy kod zahazuji - nepouzivat.
pwe_image_tag() {
    if [ -n "${PWE_IMAGE_TAG:-}" ]; then
        if ! pwe_image_tag_valid "${PWE_IMAGE_TAG}"; then
            printf '%s\n' "PWE_IMAGE_TAG='${PWE_IMAGE_TAG}' neni platny tag image (povolene znaky A-Z a-z 0-9 _ . -, nezacina teckou ani pomlckou, nejvys 128 znaku). Image PWE maji tagy <verze> (obsah PWE/VERSION) a latest." >&2
            return 2
        fi
        printf '%s\n' "${PWE_IMAGE_TAG}"
        return 0
    fi
    pwe_image_version
}

# pwe_image <nazev> - vypise cele jmeno image <registr>/<nazev>:<tag>, napr. pwe_image pwe-debugger.
# Kdyz tag nelze urcit (neplatny PWE_IMAGE_TAG, PWE/VERSION bez verze), nevypise nic a vrati 2 (hlasku
# vypise pwe_image_tag).
pwe_image() {
    local name="${1:?Pouziti: pwe_image <nazev image, napr. pwe-debugger>}"
    local tag
    tag="$(pwe_image_tag)" || return $?
    printf '%s/%s:%s\n' "$(pwe_image_registry)" "${name}" "${tag}"
}

# pwe_image_names [deps|examples|all] - vypise jmena image PWE (bez registru a tagu), jedno na radek, v poradi,
# v jakem se stavi a kontroluji: deps = zavislostni image, examples = image vzorovych webu, all (vychozi) =
# vsech 9. Cil sestaveni (build-images.sh, docker-bake.hcl) = jmeno bez predpony "pwe-". Neznama skupina =
# hlaska na stderr, kod 2. (Perl: PWE::ToolEnv::image_names.)
pwe_image_names() {
    case "${1:-all}" in
        deps)     printf '%s\n' pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger ;;
        examples) printf '%s\n' pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres ;;
        all)      pwe_image_names deps && pwe_image_names examples ;;
        *)
            printf '%s\n' "Neznama skupina image '${1}' (deps | examples | all)" >&2
            return 2
            ;;
    esac
}

# pwe_profile_image <profil> - vypise jmeno zavislostniho image profilu (bez registru a tagu): static (web bez
# databaze) -> pwe-base, mariadb | mysql | postgres -> pwe-<profil>. V tomto image bezi sluzba fcgi vyvojoveho
# stacku a vychazi z nej image webu. Neznamy profil = hlaska na stderr, nic na stdout, kod 2.
# (Perl: PWE::ToolEnv::profile_image.)
pwe_profile_image() {
    case "${1:-}" in
        static)                     printf '%s\n' pwe-base ;;
        mariadb | mysql | postgres) printf '%s\n' "pwe-${1}" ;;
        *)
            printf '%s\n' "Neznamy profil '${1:-}' (static | mariadb | mysql | postgres)" >&2
            return 2
            ;;
    esac
}

# pwe_image_removed_note <jmeno image> - pro image zruseny pri prestavbe image (pwe, pwe-static) vypise, co ho
# nahrazuje, a vrati 0; pro kazde jine jmeno nevypise nic a vrati 1. Jen pro rady v hlaskach.
pwe_image_removed_note() {
    case "${1:-}" in
        pwe)        printf '%s\n' "image pwe byl zrusen: engine se do image webu kopiruje z repozitare (webapps/<web>/Dockerfile), nastroje a vyvojovy stack ho berou z mountu repozitare" ;;
        pwe-static) printf '%s\n' "image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, vzorovy web bez databaze je image pwe-example-static" ;;
        *)          return 1 ;;
    esac
}

# pwe_tool_image - vypise image pro vyvojove nastroje spoustene v kontejneru (make test, compile, check,
# cgi, module, smtp-test; make new bezi na hostiteli a image nepotrebuje): PWE_TEST_IMAGE, jinak
# pwe-debugger:<tag> (ma vsechny databazove ovladace; kod enginu a weby dostava mountem repozitare).
# S PWE_TEST_IMAGE se tag nezjistuje ani nekontroluje; jinak pri neurcitelnem tagu vraci 2 jako pwe_image.
pwe_tool_image() {
    if [ -n "${PWE_TEST_IMAGE:-}" ]; then
        printf '%s\n' "${PWE_TEST_IMAGE}"
        return 0
    fi
    pwe_image pwe-debugger
}

# pwe_image_missing_hint <image> [nastroj] - kdyz <image> neni v lokalnim Dockeru, vypise na stderr radu
# (radky zacinaji "[<nastroj>]", vychozi tools): docker ho zkusi stahnout z registru; jak ho sestavit (image PWE:
# make images ARGS=<cil>, jiny image: make images); a ktere tagy tehoz repozitare v lokalnim Dockeru jsou.
# U zruseneho image (pwe, pwe-static ze starsiho usporadani) misto rady k sestaveni rekne, ze byl zrusen a co
# ho nahrazuje. Kdyz image mistne je (nebo chybi prikaz docker), nevypise nic. Vzdy vraci 0 - je to jen rada,
# beh volajiciho neprerusuje. Stejny text vypisuje PWE::ToolEnv::_image_missing_note().
pwe_image_missing_hint() {
    local image="${1:?Pouziti: pwe_image_missing_hint <image> [nastroj]}"
    local label="${2:-tools}"
    local repo name tags var removed
    command -v docker >/dev/null 2>&1 || return 0
    docker image inspect "${image}" >/dev/null 2>&1 && return 0
    # repozitar = jmeno bez digestu a bez tagu (dvojtecka v registru s portem zustava)
    repo="${image%%@*}"
    case "${repo##*/}" in
        *:*) repo="${repo%:*}" ;;
    esac
    name="${repo##*/}"
    tags="$(docker image ls --format '{{.Tag}}' "${repo}" 2>/dev/null | LC_ALL=C grep -v '^<none>$' | LC_ALL=C sort -u | tr '\n' ' ')" || true
    tags="${tags% }"
    printf '%s\n' "[${label}] image ${image} neni v lokalnim Dockeru, docker ho zkusi stahnout z registru." >&2
    if removed="$(pwe_image_removed_note "${name}")"; then
        printf '%s\n' "[${label}]   ${removed}" >&2
    elif pwe_image_names all | LC_ALL=C grep -q -x -F -e "${name}"; then
        printf '%s\n' "[${label}]   sestaveni: make images ARGS=${name#pwe-} (PWE/tools/build-images.sh ${name#pwe-})" >&2
    else
        printf '%s\n' "[${label}]   sestaveni: make images (PWE/tools/build-images.sh)" >&2
    fi
    if [ -n "${tags}" ]; then
        if [ "${image}" = "${PWE_TEST_IMAGE:-}" ]; then
            var="PWE_TEST_IMAGE=${repo}:<tag>"
        else
            var="PWE_IMAGE_TAG=<tag>"
        fi
        printf '%s\n' "[${label}]   mistne dostupne tagy ${repo}: ${tags} (pouziti: ${var})" >&2
    else
        printf '%s\n' "[${label}]   v lokalnim Dockeru neni zadny image ${repo}" >&2
    fi
    return 0
}

# Prime spusteni (ne source): prvni argument je nazev funkce, dalsi jeji argumenty. Navratovy kod = kod funkce.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        pwe_image_registry | pwe_image_tag | pwe_image_version | pwe_image_tag_valid | pwe_image_git_repo \
            | pwe_image | pwe_image_names | pwe_profile_image | pwe_tool_image | pwe_image_missing_hint)
            "$@"
            ;;
        *)
            echo "Pouziti: bash $0 pwe_image_registry | pwe_image_tag | pwe_image_version | pwe_image_tag_valid <tag> | pwe_image_git_repo | pwe_image <nazev> | pwe_image_names [deps|examples|all] | pwe_profile_image <profil> | pwe_tool_image | pwe_image_missing_hint <image> [nastroj]" >&2
            exit 2
            ;;
    esac
fi
