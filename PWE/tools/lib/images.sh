#!/bin/bash
# Jmena image PWE pro shell nastroje v PWE/tools/ (jediny zdroj pravdy pro registr a tag).
#
# Pouziti ve skriptu (bash):
#   . "$ROOT/PWE/tools/lib/images.sh"
#   IMAGE="$(pwe_tool_image)"                 # image pro nastroje (testy, perl -c, CGI request)
#   pwe_image_missing_hint "$IMAGE" run-tests # rada na stderr, kdyz image neni v lokalnim Dockeru
#   docker pull "$(pwe_image pwe-mariadb)"    # ghcr.io/kukam/pwe-mariadb:<vetev>
#
# Primo z prikazove radky, Makefile nebo jineho jazyka:
#   bash PWE/tools/lib/images.sh pwe_image pwe-debugger
#   bash PWE/tools/lib/images.sh pwe_image_tag
#   bash PWE/tools/lib/images.sh pwe_image_branch
#   bash PWE/tools/lib/images.sh pwe_image_tag_sanitize 'feature/kosik'
#
# Promenne prostredi:
#   PWE_IMAGE_REGISTRY   registr a jmenny prostor image (vychozi ghcr.io/kukam)
#   PWE_IMAGE_TAG        tag image (vychozi = aktualni vetev gitu repozitare, viz pwe_image_tag). Musi to byt
#                        platny tag image (pwe_image_tag_valid), jinak funkce skonci chybou (kod 2).
#   PWE_TEST_IMAGE       uplne prepsani image nastroju (cele jmeno vcetne tagu), ma prednost pred obema
#
# Stejna pravidla ma pro Perl nastroje PWE::ToolEnv (PWE/tools/lib/PWE/ToolEnv.pm) - obe implementace
# musi davat stejny vysledek (hlidaji to PWE/t/14-tools.t a PWE/t/21-image-tools.t).

# Cesta k tomuto souboru: v bash BASH_SOURCE, pri nacteni ze zsh (vychozi shell macOS) ${(%):-%x}
# - bez toho by se koren repozitare urcil spatne a pwe_image_tag by tise vracel "master".
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _PWE_IMAGES_SELF="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    eval '_PWE_IMAGES_SELF="${(%):-%x}"'
else
    _PWE_IMAGES_SELF="$0"
fi

# Koren repozitare = tri urovne nad timto souborem (<repo>/PWE/tools/lib/images.sh). "unset CDPATH" (jen
# v podshellu): cd nehleda relativni cestu v CDPATH/cdpath. ">/dev/null": interaktivni zsh (a bash s CDPATH)
# i pripadny hook chpwd vypisuji pri cd na stdout - koren by mel vic radku a pwe_image_tag by tise vracel master.
_PWE_IMAGES_ROOT="$(unset CDPATH; cd -- "$(dirname -- "${_PWE_IMAGES_SELF}")/../../.." > /dev/null && pwd)"

# pwe_image_registry - vypise registr a jmenny prostor image (bez koncoveho lomitka).
pwe_image_registry() {
    local registry="${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}"
    printf '%s\n' "${registry%/}"
}

# pwe_image_tag_sanitize <nazev> - prevede nazev vetve na platny tag image: znaky mimo
# [A-Za-z0-9_.-] nahradi pomlckou, odstrani uvodni tecky a pomlcky, zkrati na 128 znaku
# (napr. feature/kosik -> feature-kosik). Prazdny vysledek = master. Stejne pravidlo pouziva CI.
pwe_image_tag_sanitize() {
    local tag
    tag="$(printf '%s' "${1:-}" | LC_ALL=C sed -e 's/[^A-Za-z0-9_.-]/-/g' -e 's/^[.-]*//' | cut -c1-128)"
    printf '%s\n' "${tag:-master}"
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
# gitoveho repozitare (napr. archiv v podadresari) se za pracovni kopii nepovazuje - cizi vetev, commit
# ani stav se nepouzije.
pwe_image_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    [ -z "$(git -C "${_PWE_IMAGES_ROOT}" rev-parse --show-prefix 2>/dev/null || echo x)" ]
}

# pwe_image_branch - vypise aktualni vetev gitu repozitare; prazdny vystup = vetev nelze urcit
# (bez gitu, odpojeny HEAD, repozitar rozbaleny uvnitr ciziho gitu). Vzdy vraci 0.
pwe_image_branch() {
    if pwe_image_git_repo; then
        git -C "${_PWE_IMAGES_ROOT}" symbolic-ref --quiet --short HEAD 2>/dev/null || true
    fi
}

# pwe_image_tag - vypise tag image: PWE_IMAGE_TAG (beze zmeny), jinak aktualni vetev gitu repozitare
# (pwe_image_branch) prevedena pres pwe_image_tag_sanitize; kdyz vetev nelze urcit, vraci master.
# PWE_IMAGE_TAG, ktery neni platny tag image (napr. neprevedeny nazev vetve s lomitkem), se nepouzije:
# funkce vypise hlasku na stderr, na stdout nic a vrati 2. Volajici pod "set -e" tim skonci
# (X="$(pwe_image_tag)"); "export X=$(...)" a "local X=$(...)" navratovy kod zahazuji - nepouzivat.
pwe_image_tag() {
    if [ -n "${PWE_IMAGE_TAG:-}" ]; then
        if ! pwe_image_tag_valid "${PWE_IMAGE_TAG}"; then
            printf '%s\n' "PWE_IMAGE_TAG='${PWE_IMAGE_TAG}' neni platny tag image (povolene znaky A-Z a-z 0-9 _ . -, nezacina teckou ani pomlckou, nejvys 128 znaku). Nazev vetve preved: bash PWE/tools/lib/images.sh pwe_image_tag_sanitize '${PWE_IMAGE_TAG}'" >&2
            return 2
        fi
        printf '%s\n' "${PWE_IMAGE_TAG}"
        return 0
    fi
    pwe_image_tag_sanitize "$(pwe_image_branch)"
}

# pwe_image <nazev> - vypise cele jmeno image <registr>/<nazev>:<tag>, napr. pwe_image pwe-debugger.
# Pri neplatnem PWE_IMAGE_TAG nevypise nic a vrati 2 (hlasku vypise pwe_image_tag).
pwe_image() {
    local name="${1:?Pouziti: pwe_image <nazev image, napr. pwe-debugger>}"
    local tag
    tag="$(pwe_image_tag)" || return $?
    printf '%s/%s:%s\n' "$(pwe_image_registry)" "${name}" "${tag}"
}

# pwe_tool_image - vypise image pro vyvojove nastroje spoustene v kontejneru (make test, compile, check,
# cgi, module, smtp-test; make new bezi na hostiteli a image nepotrebuje): PWE_TEST_IMAGE, jinak
# pwe-debugger (ma vsechny databazove ovladace). Pri neplatnem PWE_IMAGE_TAG vraci 2 jako pwe_image.
pwe_tool_image() {
    if [ -n "${PWE_TEST_IMAGE:-}" ]; then
        printf '%s\n' "${PWE_TEST_IMAGE}"
        return 0
    fi
    pwe_image pwe-debugger
}

# pwe_image_missing_hint <image> [nastroj] - kdyz <image> neni v lokalnim Dockeru, vypise na stderr radu
# (radky zacinaji "[<nastroj>]", vychozi tools): docker ho zkusi stahnout z registru, sestavit ho jde
# pres make images, a ktere tagy tehoz repozitare v lokalnim Dockeru jsou. Kdyz image mistne je (nebo
# chybi prikaz docker), nevypise nic. Vzdy vraci 0 - je to jen rada, beh volajiciho neprerusuje.
# Stejny text vypisuje PWE::ToolEnv::_image_missing_note().
pwe_image_missing_hint() {
    local image="${1:?Pouziti: pwe_image_missing_hint <image> [nastroj]}"
    local label="${2:-tools}"
    local repo tags var
    command -v docker >/dev/null 2>&1 || return 0
    docker image inspect "${image}" >/dev/null 2>&1 && return 0
    # repozitar = jmeno bez digestu a bez tagu (dvojtecka v registru s portem zustava)
    repo="${image%%@*}"
    case "${repo##*/}" in
        *:*) repo="${repo%:*}" ;;
    esac
    tags="$(docker image ls --format '{{.Tag}}' "${repo}" 2>/dev/null | LC_ALL=C grep -v '^<none>$' | LC_ALL=C sort -u | tr '\n' ' ')" || true
    tags="${tags% }"
    printf '%s\n' "[${label}] image ${image} neni v lokalnim Dockeru, docker ho zkusi stahnout z registru." >&2
    printf '%s\n' "[${label}]   sestaveni: make images (PWE/tools/build-images.sh)" >&2
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
        pwe_image_registry | pwe_image_tag | pwe_image_tag_sanitize | pwe_image_tag_valid | pwe_image_git_repo \
            | pwe_image_branch | pwe_image | pwe_tool_image | pwe_image_missing_hint)
            "$@"
            ;;
        *)
            echo "Pouziti: bash $0 pwe_image_registry | pwe_image_tag | pwe_image_branch | pwe_image_tag_sanitize <vetev> | pwe_image_tag_valid <tag> | pwe_image_git_repo | pwe_image <nazev> | pwe_tool_image | pwe_image_missing_hint <image> [nastroj]" >&2
            exit 2
            ;;
    esac
fi
