#!/bin/bash
# Nasazeni webu PWE do Kubernetes chartem nxs-universal-chart (cile make k8s-*). Navod: kubernetes/README.md
#
#   PWE/tools/k8s.sh <prikaz> <nazev> [dalsi argumenty]
#
#   <nazev>   jmeno nasazeni: hodnoty chartu jsou v kubernetes/values-<nazev>.yml, release se jmenuje
#             pwe-<nazev> a web bezi na https://pwe-<nazev>.<K8S_DOMAIN> (jinou adresu urci generic.pweHost
#             ve values). V repozitari jsou dva priklady: static (webapps/example.web, bez databaze)
#             a generic (webapps/example-db.web + MariaDB).
#
#   prikazy   image     sestavi image webu pro platformu clusteru a nahraje ho do registru
#             template  vypise manifesty, ktere by se nasadily (helm template; bez KUBE_CONTEXT
#                       s prazdnym kubeconfigem, takze se k zadnemu clusteru nepripoji)
#             deploy    nasadi nebo aktualizuje release (helm upgrade --install --wait)
#             status    stav releasu: pody, sluzby, ingress, svazky, certifikat
#             test      overi web pres HTTPS (platny certifikat, uvodni stranka, statika)
#             logs      poslednich K8S_TAIL radku logu vsech kontejneru releasu
#             delete    odinstaluje release (svazek databaze a certifikat zustavaji)
#
#   dalsi argumenty: helm u template, deploy a delete (napr. --dry-run=server), docker buildx build
#             u image, kubectl logs u logs (napr. -f nebo -c fcgi). Prepinace, ktere meni cluster nebo
#             kontext (--kube-context, --kubeconfig, --context, --server ...), se odmitaji.
#
# Nastaveni: promenne prostredi, jinak kubernetes/local.env (neni v gitu, vzor local.env.example).
# Neprazdna promenna prostredi ma prednost pred souborem.
#   KUBE_CONTEXT       kontext kubectl - POVINNY pro deploy, status, logs a delete. Zadna vychozi hodnota:
#                      skript nikdy nepouzije "aktualni kontext" a kazdemu prikazu ho predava vyslovne.
#   K8S_NAMESPACE      namespace (vychozi pwe)
#   K8S_DOMAIN         domena; web bezi na pwe-<nazev>.<K8S_DOMAIN> (povinna, pokud values nema pweHost)
#   K8S_ISSUER         ClusterIssuer cert-manageru pro certifikat (povinny pro deploy)
#   K8S_REGISTRY       registr, do ktereho se image webu nahrava, napr. docker.io/kukam (povinny pro image
#                      a pro zjisteni digestu pri deploy)
#   K8S_PULL_REGISTRY  registr, ze ktereho image taha cluster (vychozi K8S_REGISTRY; jiny napr. pri
#                      pouziti proxy cache: harbor.example.com/dockerhub/kukam)
#   K8S_IMAGE_TAG      tag image webu (vychozi = aktualni vetev gitu prevedena na platny tag; nezavisi
#                      na PWE_IMAGE_TAG, ktery vybira jen image enginu)
#   K8S_PLATFORM       platforma image webu (vychozi linux/amd64)
#   K8S_BUILDER        builder pro docker buildx (vychozi = builder aktualniho kontextu dockeru s ovladacem
#                      docker: default na Linuxu, desktop-linux v Docker Desktop; vidi i lokalne sestavene
#                      image enginu)
#   K8S_CHART, K8S_CHART_VERSION   chart (vychozi oci://registry.nixys.ru/nuc/nxs-universal-chart, 3.2.2)
#   K8S_HELM_ARGS      dalsi argumenty pro helm template/upgrade, deli se na mezerach (hodnoty bez mezer),
#                      napr. --set-string generic.pweNginxImage=harbor.example.com/dockerhub/library/nginx
#   K8S_TIMEOUT        jak dlouho deploy ceka na pripravene pody (vychozi 10m)
#   K8S_TAIL           pocet radku logu na kontejner (vychozi 100)
#   K8S_ALLOW_TAG=1    deploy smi nasadit jen podle tagu, kdyz digest image v registru nejde zjistit
#   K8S_NEW_SECRETS=1  deploy smi vygenerovat nova hesla, i kdyz release nebo jeho svazek uz existuje
#   HELM, KUBECTL      programy (vychozi helm, kubectl)
#   PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG   image enginu, ze kterych se image webu stavi (viz lib/images.sh)
#
# Image webu se stavi z webapps/<web>/Dockerfile; ktery web a jak se image jmenuje, urcuji klice
# generic.pweWeb, generic.pweProfile a generic.pweImage v kubernetes/values-<nazev>.yml.
# Nasazuje se podle digestu: deploy si v registru zjisti digest tagu a pody dostanou odkaz
# <image>:<tag>@sha256:..., takze nove nahrany image pod stejnym tagem vyvola vymenu podu.
set -e

# "CDPATH= cd": s exportovanym CDPATH by cd vypsal cilovy adresar na stdout a ROOT by mel dva radky
# shellcheck disable=SC1007
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"

usage() {
    sed -n '2,/^set -e$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit "${1:-2}"
}

die() {
    echo "[k8s] $*" >&2
    exit 2
}

LOWER_CHARS="abcdefghijklmnopqrstuvwxyz"
UPPER_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS="0123456789"

CMD="${1:-}"
case "$CMD" in
    image | template | deploy | status | test | logs | delete) ;;
    -h | --help | help) usage 0 ;;
    *) usage 2 ;;
esac
NAME="${2:-${K8S:-}}"
[ $# -ge 2 ] && shift 2 || shift $#
[ -n "$NAME" ] || die "chybi nazev nasazeni: make k8s-$CMD K8S=<nazev> (napr. static nebo generic; soubor kubernetes/values-<nazev>.yml)"
# znaky vyjmenovane (ne rozsah a-z): rozsahy zavisi na locale a v bash 3.2 by prosla i velka pismena
case "$NAME" in
    *[!"$LOWER_CHARS$DIGITS"-]* | -* | *-) die "nazev nasazeni '$NAME' smi obsahovat jen mala pismena, cislice a pomlcky (ne na zacatku a konci)" ;;
esac

VALUES="$ROOT/kubernetes/values-$NAME.yml"
[ -f "$VALUES" ] || die "soubor kubernetes/values-$NAME.yml neexistuje (dostupne: $(cd "$ROOT/kubernetes" && ls values-*.yml 2>/dev/null | sed -e 's/^values-//' -e 's/\.yml$//' | tr '\n' ' '))"

# Mistni nastaveni: kubernetes/local.env (radky KLIC=hodnota). Neprazdna promenna prostredi ma prednost.
# Mezery kolem hodnoty, jeden par uvozovek kolem ni a znak CR (soubor z Windows) se odstrani.
LOCAL_ENV="$ROOT/kubernetes/local.env"
if [ -f "$LOCAL_ENV" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            '' | '#'*) continue ;;
            *=*) ;;
            *) die "kubernetes/local.env: nerozumim radku: $line" ;;
        esac
        key="${trimmed%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${trimmed#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        case "$key" in
            '' | [!"$LOWER_CHARS$UPPER_CHARS"_]* | *[!"$LOWER_CHARS$UPPER_CHARS$DIGITS"_]*)
                die "kubernetes/local.env: neplatny nazev promenne: '$key'" ;;
        esac
        # nazev je overeny vyse (jen pismena, cislice, podtrzitko), eval je proto bezpecny
        if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
            export "$key=$value"
        fi
    done < "$LOCAL_ENV"
fi

# Prepinace, ktere by zmenily cluster, kontext nebo prihlaseni. Kontext se nastavuje jen pres KUBE_CONTEXT.
reject_cluster_flags() {
    local a
    for a in "$@"; do
        case "$a" in
            --kube-context* | --kubeconfig* | --kube-apiserver* | --kube-token* | --kube-as-* | --kube-ca-file* \
            | --kube-insecure-skip-tls-verify* | --kube-tls-server-name* | --context* | --cluster* | --server*)
                die "prepinac '$a' neni povolen: kontext se nastavuje jen pres KUBE_CONTEXT (kubernetes/local.env nebo KUBE_CONTEXT=... na prikazove radce)" ;;
        esac
    done
    return 0
}
EXTRA_HELM=()
if [ -n "${K8S_HELM_ARGS:-}" ]; then
    # deleni na mezerach bez rozvijeni hvezdicek (set -f)
    set -f
    # shellcheck disable=SC2206
    EXTRA_HELM=($K8S_HELM_ARGS)
    set +f
fi
reject_cluster_flags "$@" ${EXTRA_HELM[@]+"${EXTRA_HELM[@]}"}
if [ "$CMD" = logs ]; then
    for a in "$@"; do
        case "$a" in
            -s | --user* | --token* | --password*) die "prepinac '$a' neni u logs povolen" ;;
        esac
    done
fi

RELEASE="pwe-$NAME"
NAMESPACE="${K8S_NAMESPACE:-pwe}"
CHART="${K8S_CHART:-oci://registry.nixys.ru/nuc/nxs-universal-chart}"
CHART_VERSION="${K8S_CHART_VERSION:-3.2.2}"
HELM="${HELM:-helm}"
KUBECTL="${KUBECTL:-kubectl}"
PLATFORM="${K8S_PLATFORM:-linux/amd64}"
PUSH_REGISTRY="${K8S_REGISTRY:-}"
PUSH_REGISTRY="${PUSH_REGISTRY%/}"
PULL_REGISTRY="${K8S_PULL_REGISTRY:-$PUSH_REGISTRY}"
PULL_REGISTRY="${PULL_REGISTRY%/}"
SELECTOR="app.kubernetes.io/instance=$RELEASE"

# Tag image webu: K8S_IMAGE_TAG, jinak vetev gitu (stejne pravidlo jako tag image enginu, ale nezavisle
# na PWE_IMAGE_TAG). Muze obsahovat i digest: <tag>@sha256:<64 hex znaku>.
TAG="${K8S_IMAGE_TAG:-$(pwe_image_tag_sanitize "$(pwe_image_branch)")}"
pwe_image_tag_valid "${TAG%%@*}" \
    || die "K8S_IMAGE_TAG='$TAG' neni platny tag image (nazev vetve preved: bash PWE/tools/lib/images.sh pwe_image_tag_sanitize '...')"
case "$TAG" in
    *@*)
        case "${TAG#*@}" in
            sha256:????????????????????????????????????????????????????????????????) ;;
            *) die "K8S_IMAGE_TAG='$TAG': za @ musi byt digest sha256:<64 znaku>" ;;
        esac ;;
esac

# value_of <klic> - hodnota klice generic.<klic> z values souboru (radek "  <klic>: hodnota  # komentar")
value_of() {
    sed -n "s/^  $1:[[:space:]]*[\"']\{0,1\}\([^\"'[:space:]#]*\).*/\1/p" "$VALUES" | head -1
}
WEB="$(value_of pweWeb)"
PROFILE="$(value_of pweProfile)"
IMAGE_NAME="$(value_of pweImage)"
HOST="$(value_of pweHost)"
[ -n "$WEB" ] && [ -n "$PROFILE" ] && [ -n "$IMAGE_NAME" ] \
    || die "kubernetes/values-$NAME.yml: pod klicem generic chybi pweWeb, pweProfile nebo pweImage"

need_program() {
    command -v "$1" > /dev/null 2>&1 || die "program $1 neni nainstalovany. $2"
}
need_helm() {
    need_program "$HELM" "Instalace: https://helm.sh/docs/intro/install/ (macOS: brew install helm). Potreba je Helm 3.8 nebo novejsi (chart je v registru OCI)."
}
need_context() {
    [ -n "${KUBE_CONTEXT:-}" ] || die "neni nastaven KUBE_CONTEXT (make k8s-$CMD K8S=$NAME KUBE_CONTEXT=<kontext>, nebo radek v kubernetes/local.env). Aktualni kontext kubectl se zamerne nepouziva. Dostupne kontexty: $KUBECTL config get-contexts -o name"
    case "$KUBE_CONTEXT" in
        -*) die "KUBE_CONTEXT='$KUBE_CONTEXT' nesmi zacinat pomlckou" ;;
    esac
    echo "[k8s] kontext=$KUBE_CONTEXT namespace=$NAMESPACE release=$RELEASE" >&2
}
# need_host - adresa webu: generic.pweHost z values, jinak <release>.<K8S_DOMAIN>
need_host() {
    if [ -z "$HOST" ]; then
        [ -n "${K8S_DOMAIN:-}" ] || die "neni nastavena K8S_DOMAIN (web bezi na $RELEASE.<domena>); nastav ji v kubernetes/local.env nebo na prikazove radce, pripadne generic.pweHost ve values"
        HOST="$RELEASE.$K8S_DOMAIN"
    fi
}
kc() {
    "$KUBECTL" --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
}

# release_in_cluster - 0, kdyz release nebo svazek databaze releasu v clusteru uz existuje
release_in_cluster() {
    "$HELM" status "$RELEASE" --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" > /dev/null 2>&1 && return 0
    [ -n "$(kc get persistentvolumeclaims -l "$SELECTOR" -o name 2> /dev/null)" ]
}

# Argumenty helm spolecne pro template a deploy: values, volitelne secrets a prepisy z nastaveni.
# $1 = 1: chybejici soubor s hesly se zalozi ze vzoru (deploy); 0: pouzije se vzor (template, --dry-run)
helm_values_args() {
    HELM_ARGS=(-f "$VALUES")
    local secrets="$ROOT/kubernetes/secrets-$NAME.yml" example="$ROOT/kubernetes/secrets-$NAME.example.yml" line
    if [ -f "$example" ] && [ ! -f "$secrets" ]; then
        if [ "$1" = 1 ]; then
            if [ -z "${K8S_NEW_SECRETS:-}" ] && release_in_cluster; then
                die "kubernetes/secrets-$NAME.yml chybi, ale release $RELEASE nebo jeho svazek v clusteru uz existuje - nova hesla by nesouhlasila s databazi. Obnov soubor z clusteru: $HELM --kube-context $KUBE_CONTEXT -n $NAMESPACE get values $RELEASE -o yaml (klic secrets), nebo ho zkopiruj ze stroje, odkud se nasazovalo. Nova hesla jen vyslovne: K8S_NEW_SECRETS=1"
            fi
            (
                # soubor vznika uz s pravy 0600 (umask plati i pro presmerovani uvnitr teto podskupiny)
                umask 077
                {
                    printf '# SKUTECNA HESLA pro release %s - vygeneroval PWE/tools/k8s.sh %s ze vzoru %s.\n' \
                        "$RELEASE" "$(date '+%Y-%m-%d %H:%M')" "secrets-$NAME.example.yml"
                    printf '# Neni v gitu - uschovej si ho; bez nej se dalsi nasazeni k databazi nepripoji (kubernetes/README.md, Hesla).\n'
                    while IFS= read -r line || [ -n "$line" ]; do
                        case "$line" in
                            '#'*) continue ;;
                        esac
                        while :; do
                            case "$line" in
                                *CHANGE_ME*) line="${line%%CHANGE_ME*}$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')${line#*CHANGE_ME}" ;;
                                *) break ;;
                            esac
                        done
                        printf '%s\n' "$line"
                    done < "$example"
                } > "$secrets"
            )
            echo "[k8s] zalozen kubernetes/secrets-$NAME.yml s nahodnymi hesly (neni v gitu) - uschovej si ho" >&2
        else
            echo "[k8s] kubernetes/secrets-$NAME.yml neexistuje, pouzivam vzor secrets-$NAME.example.yml" >&2
            secrets="$example"
        fi
    fi
    if [ -f "$secrets" ]; then
        if [ "$secrets" != "$example" ] && grep -v '^[[:space:]]*#' "$secrets" | grep -q CHANGE_ME; then
            die "kubernetes/secrets-$NAME.yml obsahuje nevyplnene CHANGE_ME - dopln hesla, nebo soubor smaz a nech ho vygenerovat"
        fi
        HELM_ARGS+=(-f "$secrets")
    fi
    [ -n "$PULL_REGISTRY" ] && HELM_ARGS+=(--set-string "generic.pweRegistry=$PULL_REGISTRY")
    HELM_ARGS+=(--set-string "generic.pweImageTag=$IMAGE_TAG_REF")
    [ -n "${K8S_DOMAIN:-}" ] && HELM_ARGS+=(--set-string "generic.pweDomain=$K8S_DOMAIN")
    [ -n "${K8S_ISSUER:-}" ] && HELM_ARGS+=(--set-string "generic.pweIssuer=$K8S_ISSUER")
    HELM_ARGS+=(${EXTRA_HELM[@]+"${EXTRA_HELM[@]}"})
    return 0
}

# resolve_image_tag [1] - zjisti digest tagu v registru, do ktereho se image nahrava; pody pak dostanou
# odkaz <tag>@sha256:... S argumentem 1 (deploy) je nezjisteny digest chyba (vyjimka K8S_ALLOW_TAG=1),
# jinak jen varovani a pouzije se tag.
resolve_image_tag() {
    IMAGE_TAG_REF="$TAG"
    case "$TAG" in *@*) return 0 ;; esac
    local out="" why=""
    if [ -z "$PUSH_REGISTRY" ]; then
        why="neni nastaven K8S_REGISTRY"
    elif ! command -v docker > /dev/null 2>&1; then
        why="chybi program docker"
    else
        out="$(docker buildx imagetools inspect "$PUSH_REGISTRY/$IMAGE_NAME:$TAG" --format '{{.Manifest.Digest}}' 2>&1)" || true
        case "$out" in
            sha256:*)
                IMAGE_TAG_REF="$TAG@$out"
                echo "[k8s] image $PUSH_REGISTRY/$IMAGE_NAME:$TAG ma digest $out" >&2
                return 0
                ;;
        esac
        why="$(printf '%s\n' "$out" | tail -1)"
    fi
    if [ "${1:-0}" = 1 ] && [ -z "${K8S_ALLOW_TAG:-}" ]; then
        die "digest image ${PUSH_REGISTRY:-<K8S_REGISTRY>}/$IMAGE_NAME:$TAG nelze zjistit ($why). Image nejdriv sestav a nahraj: make k8s-image K8S=$NAME. Nasazeni jen podle tagu (novy image pod stejnym tagem pak pody nevymeni): K8S_ALLOW_TAG=1"
    fi
    echo "[k8s] VAROVANI: digest image ${PUSH_REGISTRY:-<K8S_REGISTRY>}/$IMAGE_NAME:$TAG nelze zjistit ($why) - pouzivam jen tag" >&2
    return 0
}

# check_engine_platform - image enginu, ktere jsou v mistnim Dockeru, musi existovat pro cilovou platformu.
# Jinak by je buildx pouzil jen s varovanim InvalidBaseImagePlatform a vznikl by image webu s binarkami
# jine architektury (v clusteru "exec format error").
check_engine_platform() {
    local img p have platforms
    local supports_platform=0
    docker image inspect --help 2> /dev/null | grep -q -- '--platform' && supports_platform=1
    platforms="$(printf '%s' "$PLATFORM" | tr ',' ' ')"
    for img in "$@"; do
        docker image inspect "$img" > /dev/null 2>&1 || continue   # neni mistne: buildx ho stahne z registru
        have="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$img" 2> /dev/null || true)"
        for p in $platforms; do
            if [ "$supports_platform" = 1 ]; then
                docker image inspect --platform "$p" "$img" > /dev/null 2>&1 && continue
            else
                [ "$have" = "$p" ] && continue
            fi
            die "mistni image $img neni pro platformu $p (je $have). Sestav image enginu i pro ni, napr. PWE_IMAGE_TAG=<tag>-amd64 make images ARGS='--platform $p --load base pwe $PROFILE' a pak PWE_IMAGE_TAG=<tag>-amd64 make k8s-image K8S=$NAME (kubernetes/README.md, krok 2)"
        done
    done
    return 0
}

case "$CMD" in
    image)
        [ -n "$PUSH_REGISTRY" ] || die "neni nastaven K8S_REGISTRY (registr pro image webu, napr. docker.io/<ucet>)"
        case "$TAG" in *@*) die "K8S_IMAGE_TAG s digestem ($TAG) nelze pouzit pro sestaveni - zadej jen tag" ;; esac
        [ -f "$ROOT/webapps/$WEB/Dockerfile" ] || die "webapps/$WEB/Dockerfile neexistuje (generic.pweWeb v kubernetes/values-$NAME.yml)"
        need_program docker "Image webu se stavi pres docker buildx."
        ENGINE_REGISTRY="$(pwe_image_registry)"
        ENGINE_TAG="$(pwe_image_tag)"
        TARGET="$PUSH_REGISTRY/$IMAGE_NAME:$TAG"
        check_engine_platform "$ENGINE_REGISTRY/pwe:$ENGINE_TAG" "$ENGINE_REGISTRY/pwe-$PROFILE:$ENGINE_TAG"
        # Builder s ovladacem docker se jmenuje stejne jako aktualni kontext dockeru (default na Linuxu,
        # desktop-linux v Docker Desktop). Jen ten vidi lokalne sestavene image enginu.
        BUILDER="${K8S_BUILDER:-$(docker context show 2> /dev/null || echo default)}"
        echo "[k8s] image webu $TARGET ($PLATFORM) z webapps/$WEB, engine $ENGINE_REGISTRY/pwe:$ENGINE_TAG + pwe-$PROFILE:$ENGINE_TAG" >&2
        docker buildx build \
            --builder "$BUILDER" \
            --platform "$PLATFORM" \
            --provenance=false --sbom=false \
            -f "$ROOT/webapps/$WEB/Dockerfile" \
            --build-arg "PWE_IMAGE_REGISTRY=$ENGINE_REGISTRY" \
            --build-arg "PWE_IMAGE_TAG=$ENGINE_TAG" \
            --build-arg "PWE_PROFILE=$PROFILE" \
            -t "$TARGET" \
            --push \
            "$@" \
            "$ROOT"
        resolve_image_tag
        echo "[k8s] nahrano: $TARGET; nasazeni: make k8s-deploy K8S=$NAME" >&2
        ;;

    template)
        need_helm
        resolve_image_tag
        helm_values_args 0
        if [ -n "${KUBE_CONTEXT:-}" ]; then
            "$HELM" template "$RELEASE" "$CHART" --version "$CHART_VERSION" --kube-context "$KUBE_CONTEXT" \
                --namespace "$NAMESPACE" "${HELM_ARGS[@]}" "$@"
        else
            # Bez KUBE_CONTEXT prazdny kubeconfig: --validate nebo --dry-run=server pak skonci chybou,
            # misto aby se pripojily ke clusteru aktualniho kontextu.
            KUBECONFIG=/dev/null "$HELM" template "$RELEASE" "$CHART" --version "$CHART_VERSION" \
                --namespace "$NAMESPACE" "${HELM_ARGS[@]}" "$@"
        fi
        ;;

    deploy)
        need_helm
        need_context
        need_host
        [ -n "${K8S_ISSUER:-}" ] || die "neni nastaven K8S_ISSUER (ClusterIssuer cert-manageru; seznam: $KUBECTL --context $KUBE_CONTEXT get clusterissuer)"
        DRY_RUN=0
        case " $* " in *" --dry-run"*) DRY_RUN=1 ;; esac
        resolve_image_tag 1
        # zkouska nasucho hesla nezaklada (pouzije vzor), skutecne nasazeni ano
        if [ "$DRY_RUN" = 1 ]; then helm_values_args 0; else helm_values_args 1; fi
        "$HELM" upgrade --install "$RELEASE" "$CHART" --version "$CHART_VERSION" \
            --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" --create-namespace \
            --wait --timeout "${K8S_TIMEOUT:-10m}" \
            "${HELM_ARGS[@]}" "$@"
        if [ "$DRY_RUN" = 1 ]; then
            echo "[k8s] zkouska nasucho (--dry-run): v clusteru se nic nezmenilo" >&2
        else
            echo "[k8s] nasazeno: https://$HOST/ (certifikat vystavuje cert-manager, muze to trvat nekolik minut); stav: make k8s-status K8S=$NAME, overeni: make k8s-test K8S=$NAME" >&2
        fi
        ;;

    status)
        need_helm
        need_context
        "$HELM" status "$RELEASE" --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" | sed -n '1,6p'
        echo
        kc get pods,services,ingress -l "$SELECTOR" -o wide
        # svazky releasu (StatefulSet je zaklada se stitky releasu)
        PVC="$(kc get persistentvolumeclaims -l "$SELECTOR" 2> /dev/null || true)"
        [ -z "$PVC" ] || { echo; printf '%s\n' "$PVC"; }
        # Certifikat zaklada cert-manager pod jmenem Secretu z ingressu releasu (bez cert-manageru se preskoci).
        TLS="$(kc get ingress -l "$SELECTOR" -o jsonpath='{.items[*].spec.tls[*].secretName}' 2> /dev/null || true)"
        if [ -n "$TLS" ]; then
            # shellcheck disable=SC2086
            CERTS="$(kc get certificates $TLS 2> /dev/null || true)"
            [ -z "$CERTS" ] || { echo; printf '%s\n' "$CERTS"; }
        fi
        ;;

    logs)
        need_context
        ALL_CONTAINERS=(--all-containers)
        for a in "$@"; do
            case "$a" in -c | --container | --container=*) ALL_CONTAINERS=() ;; esac
        done
        kc logs -l "$SELECTOR" ${ALL_CONTAINERS[@]+"${ALL_CONTAINERS[@]}"} --prefix \
            --max-log-requests "${K8S_MAX_LOG_REQUESTS:-20}" --tail="${K8S_TAIL:-100}" "$@"
        ;;

    test)
        need_host
        need_program curl "Overeni webu pouziva curl."
        URL="https://$HOST"
        FAIL=0
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        check() {
            # check <popis> <ocekavany stavovy kod> <cesta> [hledany text]
            local code
            code="$(curl -sS --max-time 30 -o "$TMP/body" -w '%{http_code}' "$URL$3" 2> "$TMP/err" || true)"
            if [ "$code" != "$2" ]; then
                echo "FAIL $1: $URL$3 -> HTTP ${code:-zadna odpoved} (cekano $2) $(head -1 "$TMP/err")"
                FAIL=1
            elif [ -n "${4:-}" ] && ! grep -q -- "$4" "$TMP/body"; then
                echo "FAIL $1: $URL$3 -> v odpovedi chybi text '$4'"
                FAIL=1
            else
                echo "OK   $1: $URL$3 -> HTTP $code"
            fi
        }
        echo "[k8s] overuji $URL (curl overuje i certifikat)" >&2
        check "uvodni stranka" 200 "/" "<html"
        # statika enginu: posledni verze Bootstrapu v PWE/assets (posila ji nginx podu)
        BS="$(cd "$ROOT/PWE/assets/css" 2> /dev/null && ls -d bootstrap-* 2> /dev/null | tail -1 || true)"
        [ -z "$BS" ] || check "statika enginu (nginx)" 200 "/assets/css/$BS/bootstrap.min.css"
        [ ! -f "$ROOT/webapps/$WEB/static/css/site.css" ] || check "statika webu (nginx)" 200 "/static/css/site.css"
        check "sonda nginx" 200 "/healthz" "ok"
        if command -v openssl > /dev/null 2>&1; then
            echo "certifikat: $(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2> /dev/null | openssl x509 -noout -issuer -enddate 2> /dev/null | tr '\n' ' ')"
        fi
        [ "$FAIL" = 0 ] || exit 1
        ;;

    delete)
        need_helm
        need_context
        # jmena Secretu s certifikatem zjistit pred odinstalovanim (pak uz ingress neni)
        TLS="$(kc get ingress -l "$SELECTOR" -o jsonpath='{.items[*].spec.tls[*].secretName}' 2> /dev/null || true)"
        "$HELM" uninstall "$RELEASE" --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
        echo "[k8s] release $RELEASE odinstalovan" >&2
        LEFT="$(kc get persistentvolumeclaims -l "$SELECTOR" 2> /dev/null || true)"
        if [ -n "$TLS" ]; then
            # shellcheck disable=SC2086
            LEFT="$LEFT${LEFT:+
}$(kc get secrets $TLS 2> /dev/null || true)"
        fi
        if [ -n "$(printf '%s' "$LEFT" | tr -d '[:space:]')" ]; then
            echo "[k8s] v clusteru zustava (nove nasazeni na to navaze; smazat lze rucne: $KUBECTL --context $KUBE_CONTEXT -n $NAMESPACE delete ...):" >&2
            printf '%s\n' "$LEFT"
        fi
        ;;
esac
