#!/bin/bash
# Sestavi image PWE podle docker-bake.hcl (stage v PWE/docker/Dockerfile).
#
#   PWE/tools/build-images.sh [volby] [cil...]                      (make images [ARGS='pwe debugger'])
#
#   PWE/tools/build-images.sh                          # vsech 7 image, nacte je do lokalniho Dockeru
#   PWE/tools/build-images.sh pwe debugger             # jen vybrane cile
#   PWE/tools/build-images.sh --no-cache base          # bez cache (napr. kvuli aktualizacim balicku)
#   PWE/tools/build-images.sh --print                  # jen vypise cile a tagy, nic nestavi
#   PWE/tools/build-images.sh --platform linux/amd64 base pwe       # zkusebni build pro jinou platformu
#   PWE/tools/build-images.sh --push                   # sestavi a publikuje (linux/amd64 i linux/arm64)
#
# Cile: base pwe static mariadb mysql postgres debugger (bez cile = vsechny; lze psat i pwe-base, pwe-mariadb...).
#
# Volby:
#   --push          publikuje do registru (vyzaduje docker login); bez ni se image jen nactou do lokalniho Dockeru.
#                   Pojistky (kod 2, nic se nestavi):
#                     - tag musi byt urcity: bud PWE_IMAGE_TAG, nebo vetev gitu. V odpojenem HEAD, v kopii bez gitu
#                       a v kopii uvnitr ciziho repozitare by se publikoval tag master - zadej PWE_IMAGE_TAG=<tag>.
#                       Totez plati pro vetev, jejiz nazev se na tag master teprve prevede (napr. +master).
#                     - pracovni kopie nesmi mit necommitnute zmeny (publikoval by se kod, ktery neni v zadnem
#                       commitu, a image pwe by nemel popisek revision). Obejiti: --allow-dirty.
#                   Bez --platform se publikuji platformy linux/amd64,linux/arm64 (jen platforma stroje by
#                   prepsala vicearchitekturni tag z CI); vice platforem najednou potrebuje builder s ovladacem
#                   docker-container nebo Docker s containerd uloznym prostorem.
#                   Bez gitu (s PWE_IMAGE_TAG) se publikuje s varovanim: popisek revision image pwe bude prazdny.
#   --allow-dirty   povoli --push z pracovni kopie s necommitnutymi zmenami (popisek revision zustane prazdny)
#   --platform P    cilova platforma nebo seznam (linux/amd64,linux/arm64); vychozi = platforma stroje, s --push
#                   linux/amd64,linux/arm64.
#                   Bez --push se vysledek NENACITA (build jen overi, ze image pro platformu jde sestavit):
#                   nacteni by pod stejnym tagem nahradilo image pro platformu stroje. Vynutit lze --load.
#   --load          nacte vysledek do lokalniho Dockeru i s --platform
#   --no-cache      nepouzije cache buildu
#   --print         vypise vyslednou konfiguraci bake (cile, tagy, argumenty) a skonci; pojistky --push jen varuji
#   --set K=V       preda nastaveni primo docker buildx bake (lze opakovat), napr. --set '*.cache-from=type=gha'
#   Volby --platform a --set vyzaduji hodnotu, ktera nezacina pomlckou (lze psat i --platform=P, --set=K=V).
#
# Jmena image (viz PWE/tools/lib/images.sh):
#   PWE_IMAGE_REGISTRY     registr a jmenny prostor (vychozi ghcr.io/kukam)
#   PWE_IMAGE_REGISTRIES   carkou oddeleny seznam registru, kdyz se ma publikovat do vice (ma prednost).
#                          Mezery, prazdne polozky a koncova lomitka se odstrani; neplatny registr = kod 2.
#   PWE_IMAGE_TAG          tag (vychozi = aktualni vetev gitu, bez urcitelne vetve master); image pwe dostane navic
#                          tag = obsah PWE/VERSION. Musi to byt platny tag image a NESMI mit tvar verze X.Y.Z
#                          (ani jako nazev vetve): zamenil by se s tagem verze image pwe - kod 2 i bez --push.
#   PWE_IMAGE_SOURCE       adresa repozitare do popisku image (vychozi https://github.com/kukam/PWE)
#
# Vsechny cile se stavi jednim volanim bake nad jednim Dockerfile, takze spolecny stage base se sestavi
# jen jednou a ostatni na nej navazuji. --load funguje s builderem "docker" i "docker-container";
# vice platforem najednou umi nacist jen Docker s containerd uloznym prostorem (image store).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"

ALL_TARGETS="base pwe static mariadb mysql postgres debugger"
PUSH_PLATFORMS="linux/amd64,linux/arm64"

usage() {
    sed -n '2,/^set -e$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# fail <hlaska> - chyba v zadani: hlaska na stderr, kod 2.
fail() {
    echo "$*" >&2
    exit 2
}

# warn <hlaska> - varovani na stderr, beh pokracuje.
warn() {
    echo "[build-images] POZOR: $*" >&2
}

# option_value <volba> <hodnota> <priklad> - volba vyzaduje hodnotu, ktera nezacina pomlckou
# (jinak by --platform spolkl nasledujici volbu, napr. "--platform --push").
option_value() {
    case "$2" in
        '' | -*) fail "$1 vyzaduje hodnotu, napr. $3 (napoveda: $0 --help)" ;;
    esac
}

PUSH=0
ALLOW_DIRTY=0
LOAD=0
NOCACHE=0
PRINT=0
PLATFORM=""
SETS=()
TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --push)        PUSH=1; shift ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --load)        LOAD=1; shift ;;
        --no-cache)    NOCACHE=1; shift ;;
        --print)       PRINT=1; shift ;;
        --platform)
            option_value --platform "${2:-}" linux/amd64
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            option_value --platform "${1#--platform=}" linux/amd64
            PLATFORM="${1#--platform=}"
            shift
            ;;
        --set)
            option_value --set "${2:-}" "'*.cache-from=type=gha'"
            SETS+=("$2")
            shift 2
            ;;
        --set=*)
            option_value --set "${1#--set=}" "'*.cache-from=type=gha'"
            SETS+=("${1#--set=}")
            shift
            ;;
        -h | --help)   usage; exit 0 ;;
        -*)            fail "Neznama volba $1 (napoveda: $0 --help)" ;;
        *)
            target="${1#pwe-}"
            case " $ALL_TARGETS " in
                *" $target "*) TARGETS+=("$target") ;;
                *) fail "Neznamy cil $1 (cile: $ALL_TARGETS)" ;;
            esac
            shift
            ;;
    esac
done
if [ "$PUSH" = 1 ] && [ "$LOAD" = 1 ]; then
    fail "Volby --push a --load nejdou pouzit zaroven"
fi

# push_refuse <hlaska> - pojistka --push: publikaci odmitne (kod 2). S --print se nic nepublikuje,
# takze jen varuje, ze by skutecny --push skoncil chybou.
push_refuse() {
    if [ "$PRINT" = 1 ]; then
        warn "$* (--push by skoncil chybou)"
    else
        fail "$*"
    fi
}

# Registry: seznam se normalizuje (mezery, prazdne polozky a koncova lomitka pryc) a kazda polozka overi -
# bake by jinak vyrobil image bez tagu nebo jmeno s dvojitym lomitkem.
REGISTRY_RE='^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)*$'
RAW_REGISTRIES="$(printf '%s' "${PWE_IMAGE_REGISTRIES:-$(pwe_image_registry)}" | tr -d '[:space:]')"
REGS=()
IFS=',' read -r -a RAW_REGS <<< "$RAW_REGISTRIES" || true
for r in "${RAW_REGS[@]}"; do
    while [ "${r%/}" != "$r" ]; do r="${r%/}"; done
    [ -n "$r" ] || continue
    printf '%s' "$r" | LC_ALL=C grep -Eq "$REGISTRY_RE" \
        || fail "Neplatny registr '$r' (PWE_IMAGE_REGISTRY / PWE_IMAGE_REGISTRIES): ocekava se napr. ghcr.io/kukam nebo localhost:5000/tym, jmenny prostor malymi pismeny"
    REGS+=("$r")
done
[ ${#REGS[@]} -gt 0 ] || fail "Neni zadan zadny registr (PWE_IMAGE_REGISTRY / PWE_IMAGE_REGISTRIES je po odstraneni mezer a prazdnych polozek prazdny)"
REGISTRIES="$(IFS=','; printf '%s' "${REGS[*]}")"

# Tag: PWE_IMAGE_TAG, jinak vetev gitu. Neplatny PWE_IMAGE_TAG ukonci skript uz tady (hlaska z pwe_image_tag, kod 2).
TAG="$(pwe_image_tag)"
VERSION="$(tr -d '[:space:]' < "$ROOT/PWE/VERSION")"
pwe_image_tag_valid "$VERSION" || fail "PWE/VERSION neobsahuje platnou verzi (pouzije se jako tag image pwe): '$VERSION'"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ "$TAG" =~ $VERSION_RE ]]; then
    fail "Tag $TAG ma tvar verze X.Y.Z - zamenil by se s tagem verze image pwe (pwe:$VERSION). Zadej jiny tag (PWE_IMAGE_TAG=release-$TAG) nebo prejmenuj vetev."
fi
if [ -z "${PWE_IMAGE_TAG:-}" ]; then
    BRANCH="$(pwe_image_branch)"
    if [ -z "$BRANCH" ]; then
        if [ "$PUSH" = 1 ]; then
            push_refuse "Nelze urcit vetev gitu (odpojeny HEAD, kopie bez gitu nebo uvnitr ciziho repozitare) - publikoval by se tag master. Zadej tag vyslovne: PWE_IMAGE_TAG=<tag>"
        else
            warn "vetev gitu nelze urcit (odpojeny HEAD, kopie bez gitu nebo uvnitr ciziho repozitare), pouziva se tag master. Jiny tag: PWE_IMAGE_TAG=<tag>"
        fi
    elif [ "$PUSH" = 1 ] && [ "$BRANCH" != master ] && [ "$TAG" = master ]; then
        push_refuse "Vetev '$BRANCH' dava tag master - prepsala by image hlavni vetve. Zadej tag vyslovne: PWE_IMAGE_TAG=<tag>"
    fi
fi

# Popisky image: cas buildu a commit. Commit jen z cisteho stromu - s neulozenymi zmenami by mu image neodpovidal.
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REVISION=""
TREE="clean"
if pwe_image_git_repo; then
    if [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null || echo x)" ]; then
        REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
    else
        TREE="dirty"
    fi
else
    TREE="nogit"
fi
if [ "$PUSH" = 1 ]; then
    case "$TREE" in
        dirty)
            if [ "$ALLOW_DIRTY" = 1 ]; then
                warn "pracovni kopie ma necommitnute zmeny (--allow-dirty): publikovany kod neodpovida zadnemu commitu a image pwe nebude mit popisek revision"
            else
                push_refuse "Pracovni kopie ma necommitnute zmeny (git status) - publikoval by se kod, ktery neni v zadnem commitu, bez popisku revision. Commitni je, nebo pridej --allow-dirty."
            fi
            ;;
        nogit)
            warn "bez gitu nelze zjistit commit - popisek org.opencontainers.image.revision image pwe bude prazdny"
            ;;
    esac
    if [ -z "$PLATFORM" ]; then
        PLATFORM="$PUSH_PLATFORMS"
        echo "[build-images] --push bez --platform: publikuji vychozi platformy $PLATFORM (jinou vyber volbou --platform)" >&2
    fi
fi

# Promenne pro docker-bake.hcl (bake je cte z prostredi).
export REGISTRIES TAG VERSION CREATED REVISION
if [ -n "${PWE_IMAGE_SOURCE:-}" ]; then export SOURCE="$PWE_IMAGE_SOURCE"; else unset SOURCE; fi

CMD=(docker buildx bake -f docker-bake.hcl)
[ -n "$PLATFORM" ] && CMD+=(--set "*.platform=$PLATFORM")
[ "$NOCACHE" = 1 ] && CMD+=(--no-cache)
for s in "${SETS[@]}"; do CMD+=(--set "$s"); done

LOADED=0
if [ "$PRINT" = 1 ]; then
    CMD+=(--print)
    MODE="vypis konfigurace"
elif [ "$PUSH" = 1 ]; then
    CMD+=(--push)
    MODE="publikace do registru"
elif [ -z "$PLATFORM" ] || [ "$LOAD" = 1 ]; then
    CMD+=(--load)
    LOADED=1
    MODE="nacteni do lokalniho Dockeru"
else
    # Jina platforma bez --push a bez --load: jen overeni, ze build projde (vysledek zustane v cache builderu).
    CMD+=(--set "*.output=type=cacheonly")
    MODE="zkusebni build bez nacteni (vysledek jen v cache builderu)"
fi
CMD+=("${TARGETS[@]}")

echo "[build-images] registr=$REGISTRIES tag=$TAG verze=$VERSION platforma=${PLATFORM:-stroje} cile=${TARGETS[*]:-vsechny} -> $MODE" >&2

# Kontext buildu i cesta k Dockerfile v docker-bake.hcl jsou relativni ke koreni repozitare.
cd "$ROOT"
"${CMD[@]}"

# Po nacteni vypise, co je v lokalnim Dockeru pod tagem vetve (a verze u image pwe).
if [ "$LOADED" = 1 ]; then
    echo "[build-images] lokalni image s tagem $TAG (pwe i $VERSION):" >&2
    for r in "${REGS[@]}"; do
        docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
            --filter "reference=$r/pwe*:$TAG" --filter "reference=$r/pwe:$VERSION" | sort >&2
    done
fi
