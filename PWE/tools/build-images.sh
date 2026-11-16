#!/bin/bash
# Sestavi image PWE podle docker-bake.hcl: zavislostni image (stage v PWE/docker/Dockerfile) a image vzorovych
# webu (Dockerfile vzoroveho webu webapps/example.web/Dockerfile a webapps/example-db.web/Dockerfile).
#
#   PWE/tools/build-images.sh [volby] [cil...]                      (make images [ARGS='base debugger'])
#
#   PWE/tools/build-images.sh                          # vsech 9 image, nacte je do lokalniho Dockeru
#   PWE/tools/build-images.sh base debugger            # jen vybrane cile
#   PWE/tools/build-images.sh --no-cache base          # bez cache (napr. kvuli aktualizacim balicku)
#   PWE/tools/build-images.sh --print                  # jen vypise cile a tagy, nic nestavi
#   PWE/tools/build-images.sh --platform linux/amd64 base example-static   # zkusebni build pro jinou platformu
#   PWE/tools/build-images.sh --push                   # sestavi a publikuje (linux/amd64 i linux/arm64)
#
# Cile (bez cile = vsechny; lze psat i jmenem image: pwe-base, pwe-example-static...):
#   base mariadb mysql postgres debugger
#                   zavislostni image pwe-base, pwe-mariadb, pwe-mysql, pwe-postgres, pwe-debugger: jen knihovny,
#                   zadny kod enginu a zadny web
#   example-static example-mariadb example-mysql example-postgres
#                   image vzorovych webu pwe-example-*: zavislostni image + engine + vzorovy web (example.web nad
#                   pwe-base, example-db.web nad pwe-mariadb / pwe-mysql / pwe-postgres). Vzorovy cil si svuj
#                   zaklad sestavi sam (zavislost v docker-bake.hcl) - nestavi se nad image z registru ani nad
#                   starsim lokalnim. Do lokalniho Dockeru (s --push do registru) se ale zaklad dostane jen
#                   tehdy, kdyz je take mezi cili: po zmene zakladu proto stav oba (nebo vse).
#
# Tagy: kazdy image dostane prave dva - <verze> (obsah PWE/VERSION, napr. 2.2.1) a latest. Tagy podle vetve
# gitu neexistuji a na vetvi sestaveni nezavisi. Kazde sestaveni (a kazda publikace) oba tagy prepise;
# presny kod urcuje jen digest nebo popisek org.opencontainers.image.revision image vzorovych webu. Novou verzi
# vyda zvyseni PWE/VERSION. PWE_IMAGE_TAG (vyber image pro nastroje) se pri sestaveni nepouziva.
#
# Volby:
#   --push          publikuje do registru (vyzaduje docker login); bez ni se image jen nactou do lokalniho Dockeru.
#                   POZOR - ZADNA POJISTKA VETVE (zamer): rucni --push z LIBOVOLNE vetve i z odpojeneho HEAD
#                   prepise v registru tagy <verze> i latest vsech sestavovanych image tim, co je v pracovni
#                   kopii. Tag latest je vychozi zaklad Dockerfile webu (PWE_IMAGE_TAG=latest) i compose stacku,
#                   zmena se tedy hned projevi u kazdeho, kdo ho pouziva. Ktera vetev smi publikovat, hlida jen
#                   pipeline (.github/workflows/images.yml: vychozi vetev repozitare a vetve z promenne
#                   repozitare PUBLISH_BRANCHES) - bezne publikuje ona; rucni --push je vyslovne rozhodnuti
#                   toho, kdo ma do registru pravo zapisu. Co se chystas publikovat, ukaze --push --print.
#                   Pojistka (kod 2, nic se nestavi): pracovni kopie nesmi mit necommitnute zmeny (publikoval
#                   by se kod, ktery neni v zadnem commitu, a image vzorovych webu by nemely popisek revision).
#                   Obejiti: --allow-dirty.
#                   Bez --platform se publikuji platformy linux/amd64,linux/arm64 (jen platforma stroje by
#                   prepsala vicearchitekturni tag z CI); vice platforem najednou potrebuje builder s ovladacem
#                   docker-container nebo Docker s containerd uloznym prostorem.
#                   Bez gitu se publikuje s varovanim: popisek revision image vzorovych webu bude prazdny.
#   --allow-dirty   povoli --push z pracovni kopie s necommitnutymi zmenami (popisek revision zustane prazdny)
#   --platform P    cilova platforma nebo seznam (linux/amd64,linux/arm64); vychozi = platforma stroje, s --push
#                   linux/amd64,linux/arm64.
#                   Bez --push se vysledek NENACITA (build jen overi, ze image pro platformu jde sestavit):
#                   nacteni by pod stejnym tagem nahradilo image pro platformu stroje. Vynutit lze --load.
#   --load          nacte vysledek do lokalniho Dockeru i s --platform
#   --no-cache      nepouzije cache buildu
#   --print         vypise vyslednou konfiguraci bake (cile, tagy, argumenty) a skonci; pojistka --push jen varuje
#   --set K=V       preda nastaveni primo docker buildx bake (lze opakovat), napr. --set '*.cache-from=type=gha'
#   Volby --platform a --set vyzaduji hodnotu, ktera nezacina pomlckou (lze psat i --platform=P, --set=K=V).
#
# Jmena image (viz PWE/tools/lib/images.sh):
#   PWE_IMAGE_REGISTRY     registr a jmenny prostor (vychozi ghcr.io/kukam)
#   PWE_IMAGE_REGISTRIES   carkou oddeleny seznam registru, kdyz se ma publikovat do vice (ma prednost).
#                          Mezery, prazdne polozky a koncova lomitka se odstrani; neplatny registr = kod 2.
#                          Image vzorovych webu berou zaklad z prvniho registru seznamu.
#   PWE_IMAGE_SOURCE       adresa repozitare do popisku image (vychozi https://github.com/kukam/PWE)
# Verze: obsah PWE/VERSION ve tvaru X.Y.Z (pwe_image_version); jiny obsah = kod 2, nic se nestavi.
#
# Vsechny cile se stavi jednim volanim bake, takze spolecny stage base se sestavi jen jednou a ostatni na nej
# navazuji; image vzorovych webu dostanou svuj zaklad z tehoz volani (contexts v docker-bake.hcl), takze je
# sestavi i builder, ktery lokalni image nevidi (docker-container). --load funguje s builderem "docker"
# i "docker-container"; vice platforem najednou umi nacist jen Docker s containerd uloznym prostorem
# (image store).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"

# Cile docker-bake.hcl = jmena image (pwe_image_names v PWE/tools/lib/images.sh) bez predpony "pwe-".
ALL_TARGETS="$(pwe_image_names all | sed 's/^pwe-//' | tr '\n' ' ')"
ALL_TARGETS="${ALL_TARGETS% }"
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
                *)
                    # cile zrusene pri prestavbe image: rekni, co je nahrazuje
                    case "$1" in
                        pwe) fail "Cil pwe (image pwe = jen engine) byl zrusen: engine se do image webu kopiruje z repozitare (webapps/<web>/Dockerfile). Cile: $ALL_TARGETS" ;;
                        static | pwe-static) fail "Cil static (image pwe-static) byl zrusen: web bez databaze bezi nad pwe-base (cil base), vzorovy web bez databaze je cil example-static. Cile: $ALL_TARGETS" ;;
                    esac
                    fail "Neznamy cil $1 (cile: $ALL_TARGETS)"
                    ;;
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

# Verze enginu = tag vsech image (druhy tag je latest). Soubor PWE/VERSION bez verze tvaru X.Y.Z ukonci
# skript uz tady (hlaska z pwe_image_version, kod 2).
VERSION="$(pwe_image_version)"
if [ -n "${PWE_IMAGE_TAG:-}" ] && [ "$PWE_IMAGE_TAG" != "$VERSION" ] && [ "$PWE_IMAGE_TAG" != latest ]; then
    echo "[build-images] PWE_IMAGE_TAG=$PWE_IMAGE_TAG se pri sestaveni nepouziva: image dostanou tagy $VERSION (PWE/VERSION) a latest" >&2
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
                warn "pracovni kopie ma necommitnute zmeny (--allow-dirty): publikovany kod neodpovida zadnemu commitu a image vzorovych webu nebudou mit popisek revision"
            else
                push_refuse "Pracovni kopie ma necommitnute zmeny (git status) - publikoval by se kod, ktery neni v zadnem commitu, bez popisku revision. Commitni je, nebo pridej --allow-dirty."
            fi
            ;;
        nogit)
            warn "bez gitu nelze zjistit commit - popisek org.opencontainers.image.revision image vzorovych webu bude prazdny"
            ;;
    esac
    if [ -z "$PLATFORM" ]; then
        PLATFORM="$PUSH_PLATFORMS"
        echo "[build-images] --push bez --platform: publikuji vychozi platformy $PLATFORM (jinou vyber volbou --platform)" >&2
    fi
fi

# Promenne pro docker-bake.hcl (bake je cte z prostredi).
export REGISTRIES VERSION CREATED REVISION
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

echo "[build-images] registr=$REGISTRIES tagy=$VERSION,latest platforma=${PLATFORM:-stroje} cile=${TARGETS[*]:-vsechny} -> $MODE" >&2

# Vzorovy cil bez sveho zakladu mezi cili: zaklad se sestavi (zavislost v docker-bake.hcl), ale nikam se
# neulozi - v lokalnim Dockeru (v registru) zustane dosavadni image zakladu, ktery muze byt starsi.
# Upozorneni jen tehdy, kdyz se vysledek uklada (nacteni do lokalniho Dockeru, publikace).
if [ "$LOADED" = 1 ] || { [ "$PUSH" = 1 ] && [ "$PRINT" != 1 ]; }; then
    SELECTED=" ${TARGETS[*]:-} "
    for target in "${TARGETS[@]}"; do
        case "$target" in
            example-static) base=base ;;
            example-*)      base="${target#example-}" ;;
            *)              continue ;;
        esac
        case "$SELECTED" in
            *" $base "*) ;;
            *) echo "[build-images] cil $target: zaklad pwe-$base se sestavi z pracovni kopie, ale neulozi se (neni mezi cili) - mistni pwe-$base:$VERSION zustava beze zmeny; oba: $0 $base $target" >&2 ;;
        esac
    done
fi

# Kontext buildu i cesta k Dockerfile v docker-bake.hcl jsou relativni ke koreni repozitare.
cd "$ROOT"
"${CMD[@]}"

# Po nacteni vypise, co je v lokalnim Dockeru pod tagy verze a latest - jen image PWE (pwe_image_names), ne
# zbytky zrusenych image, ktere v lokalnim Dockeru mohou zustat ze starsich sestaveni.
if [ "$LOADED" = 1 ]; then
    echo "[build-images] lokalni image s tagy $VERSION a latest:" >&2
    FILTERS=()
    for r in "${REGS[@]}"; do
        for name in $(pwe_image_names all); do
            FILTERS+=(--filter "reference=$r/$name:$VERSION" --filter "reference=$r/$name:latest")
        done
    done
    docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' "${FILTERS[@]}" | sort >&2
fi
