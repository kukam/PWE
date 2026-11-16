#!/bin/bash
# Nasazeni webu PWE do Kubernetes chartem nxs-universal-chart (cile make k8s-*). Navod: kubernetes/README.md
#
#   PWE/tools/k8s.sh <prikaz> <nazev> [dalsi argumenty]
#
#   <nazev>   jmeno nasazeni: hodnoty chartu jsou v kubernetes/values-<nazev>.yml, release se jmenuje
#             pwe-<nazev> a web bezi na https://pwe-<nazev>.<K8S_DOMAIN> (jinou adresu urci generic.pweHost
#             ve values). V repozitari jsou dve vzorova nasazeni: static (image pwe-example-static se
#             vzorovym webem example.web, bez databaze) a generic (image pwe-example-mariadb se vzorovym
#             webem example-db.web + MariaDB).
#
#   prikazy   image     vlastni web: sestavi image webu pro platformu clusteru a nahraje ho do registru;
#                       vzorove nasazeni: nic nestavi, jen to oznami (kod 0)
#             template  vypise manifesty, ktere by se nasadily (helm template; bez KUBE_CONTEXT
#                       s prazdnym kubeconfigem, takze se k zadnemu clusteru nepripoji)
#             deploy    nasadi nebo aktualizuje release (helm upgrade --install --wait)
#             status    stav releasu: pody, sluzby, ingress, svazky, certifikat
#             test      overi web pres HTTPS (platny certifikat, uvodni stranka, statika)
#             logs      poslednich K8S_TAIL radku logu vsech kontejneru releasu
#             delete    odinstaluje release (svazek databaze a certifikat zustavaji)
#
#   dalsi argumenty: helm u template, deploy a delete (napr. --dry-run=server), docker buildx build
#             u image, kubectl logs u logs (napr. -f nebo -c fcgi). Prepinace, ktere meni cluster, kontext,
#             prihlaseni nebo namespace (--kube-context, --kubeconfig, --context, --server, --namespace,
#             -n, u logs i -s a jeho slepene tvary ...), se odmitaji. --dry-run u deploy (i v K8S_HELM_ARGS)
#             a u delete je zkouska nasucho: deploy nezaklada hesla (pouzije vzor), delete nic neodinstaluje;
#             --dry-run=none a --dry-run=false jsou skutecne nasazeni, jina hodnota nez client, server
#             a true se odmitne.
#
# Dva druhy nasazeni - rozhoduje nazev image generic.pweImage v kubernetes/values-<nazev>.yml:
#   pwe-example-<profil>   VZOROVE NASAZENI. Hotovy image vzoroveho webu (knihovny, engine i web):
#                  pwe-example-static (web example.web, profil static) nebo pwe-example-mariadb,
#                  pwe-example-mysql, pwe-example-postgres (web example-db.web, profil podle nazvu).
#                  Nic se nestavi a prikaz image neni potreba: image se bere z registru image PWE s tagem
#                  verze enginu. generic.pweWeb a generic.pweProfile musi nazvu image odpovidat.
#   jiny nazev     VLASTNI WEB. Image webu stavi prikaz image Dockerfilem webu (webapps/<web>/Dockerfile,
#                  kontext = koren repozitare; web = generic.pweWeb, profil = generic.pweProfile):
#                  zavislostni image pwe-<profil> (web bez databaze, profil static: pwe-base) + engine
#                  z pracovni kopie + web. Nahrava ho do K8S_REGISTRY.
#   Vyhrazene nazvy - image vlastniho webu se tak jmenovat nesmi: zavislostni image pwe-base, pwe-mariadb,
#                  pwe-mysql, pwe-postgres a pwe-debugger (jen knihovny, bez enginu a webu - nasadit je
#                  nejde), vsechny pwe-example-* a zrusene image pwe a pwe-static.
# Nasazuje se podle digestu: deploy si v registru zjisti digest tagu a pody dostanou odkaz
# <image>:<tag>@sha256:..., takze nove nahrany image pod stejnym tagem vyvola vymenu podu.
#
# Nastaveni: promenne prostredi, jinak kubernetes/local.env (neni v gitu, vzor local.env.example).
# Neprazdna promenna prostredi ma prednost pred souborem.
#   KUBE_CONTEXT       kontext kubectl - POVINNY pro deploy, status, logs a delete. Zadna vychozi hodnota:
#                      skript nikdy nepouzije "aktualni kontext" a kazdemu prikazu ho predava vyslovne.
#                      Promenne, kterymi by helm nebo kubectl vybraly cluster, prihlaseni nebo namespace
#                      jinak (HELM_KUBEAPISERVER, HELM_KUBETOKEN, HELM_KUBECONTEXT ..., HELM_NAMESPACE,
#                      KUBERNETES_MASTER), skript pred spustenim rusi - z prostredi i z local.env.
#                      KUBECONFIG se respektuje: urcuje jen soubor s kontexty, kontext v nem vybira
#                      vzdy KUBE_CONTEXT.
#   K8S_NAMESPACE      namespace (vychozi = nazev releasu pwe-<nazev>, kazde nasazeni ma vlastni); jinak nez
#                      touto promennou se nenastavuje
#   K8S_DOMAIN         domena; web bezi na pwe-<nazev>.<K8S_DOMAIN> (povinna, pokud values nema pweHost)
#   K8S_ISSUER         ClusterIssuer cert-manageru pro certifikat (povinny pro deploy)
#   K8S_REGISTRY       registr, ve kterem je nasazovany image (bez nazvu image); deploy v nem zjistuje digest.
#                      Vlastni web: prikaz image do nej nahrava, napr. docker.io/muj-ucet (povinny pro image
#                      a pro zjisteni digestu pri deploy). Vzorove nasazeni: registr s image vzorovych webu,
#                      vychozi PWE_IMAGE_REGISTRY (ghcr.io/kukam). Hodnota z local.env plati pro VSECHNA
#                      nasazeni.
#   K8S_PULL_REGISTRY  registr, ze ktereho image taha cluster (vychozi K8S_REGISTRY; jiny napr. pri
#                      pouziti proxy cache: harbor.example.com/ghcr/kukam). Musi to byt zrcadlo registru
#                      K8S_REGISTRY - digest se zjistuje tam. Kdyz se registry lisi, skript to oznami;
#                      s jinym K8S_REGISTRY proto zmen i K8S_PULL_REGISTRY.
#   K8S_IMAGE_TAG      tag nasazovaneho image, pripadne <tag>@sha256:<digest>. Vychozi: vlastni web latest
#                      (nezavisi na PWE_IMAGE_TAG), vzorove nasazeni tag image PWE (PWE_IMAGE_TAG, jinak
#                      verze z PWE/VERSION)
#   K8S_PLATFORM       platforma image vlastniho webu (vychozi linux/amd64)
#   K8S_BUILDER        builder pro docker buildx (vychozi = builder aktualniho kontextu dockeru s ovladacem
#                      docker: default na Linuxu, desktop-linux v Docker Desktop; vidi i lokalne sestavene
#                      zavislostni image)
#   K8S_CHART, K8S_CHART_VERSION   chart (vychozi oci://registry.nixys.ru/nuc/nxs-universal-chart, 3.2.2)
#   K8S_HELM_ARGS      dalsi argumenty pro helm template/upgrade, deli se na mezerach (hodnoty bez mezer),
#                      napr. --set-string generic.pweNginxImage=harbor.example.com/dockerhub/library/nginx
#   K8S_TIMEOUT        jak dlouho deploy ceka na pripravene pody (vychozi 10m)
#   K8S_TAIL           pocet radku logu na kontejner (vychozi 100)
#   K8S_MAX_LOG_REQUESTS   z kolika kontejneru smi logs cist soucasne (kubectl --max-log-requests, vychozi 20)
#   K8S_ALLOW_TAG=1    deploy smi nasadit jen podle tagu, kdyz digest image v registru nejde zjistit
#   K8S_NEW_SECRETS=1  deploy smi vygenerovat nova hesla, i kdyz release nebo jeho svazek uz existuje
#                      nebo kdyz jejich stav v clusteru nejde zjistit
#   K8S_DELETE_WITHOUT_SECRETS=1   delete smi odinstalovat release s hesly (ma vzor secrets-<nazev>.example.yml),
#                      i kdyz na tomto stroji chybi kubernetes/secrets-<nazev>.yml
#   HELM, KUBECTL      programy (vychozi helm, kubectl)
#   PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG   registr a tag image PWE (viz lib/images.sh; vychozi ghcr.io/kukam
#                      a verze z PWE/VERSION): vzorove nasazeni nasazuje pwe-example-<profil>:<tag>, image
#                      vlastniho webu se stavi nad zavislostnim image pwe-<profil>:<tag> (profil static:
#                      pwe-base:<tag>). Engine v image vlastniho webu je vzdy ten z pracovni kopie.
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
HEX_CHARS="0123456789abcdef"

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

# Promenne, kterymi by helm nebo kubectl vybraly cluster, prihlaseni nebo namespace mimo KUBE_CONTEXT
# a K8S_NAMESPACE (obdoba odmitanych prepinacu --kube-*): vsechny HELM_KUBE* (HELM_KUBEAPISERVER,
# HELM_KUBETOKEN, HELM_KUBECONTEXT ...), HELM_NAMESPACE a KUBERNETES_MASTER (vychozi API server, kdyz ho
# kubeconfig neurci). Rusi se, at prisly z prostredi, nebo z kubernetes/local.env. KUBECONFIG zustava:
# urcuje jen soubor s kontexty, kontext v nem vybira vzdy KUBE_CONTEXT.
IGNORED_ENV=""
for key in $(env | sed -n "s/^\(HELM_KUBE[${UPPER_CHARS}${LOWER_CHARS}${DIGITS}_]*\)=.*/\1/p" | LC_ALL=C sort) HELM_NAMESPACE KUBERNETES_MASTER; do
    [ -z "${!key:-}" ] || IGNORED_ENV="$IGNORED_ENV $key"
    unset "$key"
done
if [ -n "$IGNORED_ENV" ]; then
    echo "[k8s] promenne$IGNORED_ENV se nepouziji: cluster se vybira jen pres KUBE_CONTEXT, namespace jen pres K8S_NAMESPACE" >&2
fi

# Prepinace, ktere by zmenily cluster, kontext, prihlaseni nebo namespace. Kontext se nastavuje jen pres
# KUBE_CONTEXT, namespace jen pres K8S_NAMESPACE (jinak by skript hlasil a hlidal jiny namespace, nez do
# ktereho helm nebo kubectl skutecne sahne).
reject_cluster_flags() {
    local a
    for a in "$@"; do
        case "$a" in
            --kube-context* | --kubeconfig* | --kube-apiserver* | --kube-token* | --kube-as-* | --kube-ca-file* \
            | --kube-insecure-skip-tls-verify* | --kube-tls-server-name* | --context* | --cluster* | --server*)
                die "prepinac '$a' neni povolen: kontext se nastavuje jen pres KUBE_CONTEXT (kubernetes/local.env nebo KUBE_CONTEXT=... na prikazove radce)" ;;
            --namespace*)
                die "prepinac '$a' neni povolen: namespace se nastavuje jen pres K8S_NAMESPACE (kubernetes/local.env nebo K8S_NAMESPACE=... na prikazove radce)" ;;
        esac
    done
    return 0
}

# has_short_flag <argument> <hledane znaky> <znaky prepinacu s hodnotou> - 0, kdyz argument je skupina
# kratkych prepinacu a obsahuje nektery z hledanych. Kratke prepinace jdou slepit s hodnotou i mezi sebou
# (-shttps://x, -s=https://x, -fs https://x): znaky pred hledanym se berou jako prepinace bez hodnoty,
# u prepinace s hodnotou (treti argument) a u znaku "=" skupina konci - zbytek je hodnota.
has_short_flag() {
    local rest="$1"
    case "$rest" in
        --* | -) return 1 ;;
        -*) rest="${rest#-}" ;;
        *) return 1 ;;
    esac
    while [ -n "$rest" ]; do
        case "$rest" in
            ["$2"]*) return 0 ;;
            ["$3"=]*) return 1 ;;
        esac
        rest="${rest#?}"
    done
    return 1
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
# Kratke prepinace podle programu, ktery argumenty dostane. helm (template, deploy, delete a vzdy
# K8S_HELM_ARGS): -n je namespace; hodnotu maji -f, -o, -a, -s (template --show-only) a -l.
HELM_SHORT_ARGS=(${EXTRA_HELM[@]+"${EXTRA_HELM[@]}"})
case "$CMD" in
    template | deploy | delete) HELM_SHORT_ARGS+=("$@") ;;
esac
for a in ${HELM_SHORT_ARGS[@]+"${HELM_SHORT_ARGS[@]}"}; do
    if has_short_flag "$a" n foasl; then
        die "prepinac '$a' neni povolen: namespace se nastavuje jen pres K8S_NAMESPACE (kubernetes/local.env nebo K8S_NAMESPACE=... na prikazove radce)"
    fi
done
if [ "$CMD" = logs ]; then
    # kubectl logs: -s je API server a -n namespace (i slepene: -shttps://x, -s=x, -fs x); hodnotu maji
    # -c, -l a -v. Prihlaseni a overeni serveru se berou jen z kontextu (obdoba --kube-token, --kube-as-*,
    # --kube-ca-file, --kube-insecure-skip-tls-verify a --kube-tls-server-name helmu).
    for a in "$@"; do
        case "$a" in
            --user* | --token* | --password* | --as | --as=* | --as-* | --client-certificate* | --client-key* \
            | --certificate-authority* | --insecure-skip-tls-verify | --insecure-skip-tls-verify=* | --tls-server-name*)
                die "prepinac '$a' neni u logs povolen: prihlaseni a overeni serveru se berou jen z kontextu KUBE_CONTEXT" ;;
        esac
        if has_short_flag "$a" sn clv; then
            die "prepinac '$a' neni u logs povolen: server urcuje jen KUBE_CONTEXT, namespace jen K8S_NAMESPACE"
        fi
    done
fi

RELEASE="pwe-$NAME"
# Kazde nasazeni ma vlastni namespace pojmenovany jako release (pwe-<nazev>); K8S_NAMESPACE ho prepise
# (hodnota z kubernetes/local.env by ale platila pro VSECHNA nasazeni - davej ji jen na prikazovou radku).
NAMESPACE="${K8S_NAMESPACE:-$RELEASE}"
CHART="${K8S_CHART:-oci://registry.nixys.ru/nuc/nxs-universal-chart}"
CHART_VERSION="${K8S_CHART_VERSION:-3.2.2}"
HELM="${HELM:-helm}"
KUBECTL="${KUBECTL:-kubectl}"
PLATFORM="${K8S_PLATFORM:-linux/amd64}"
SELECTOR="app.kubernetes.io/instance=$RELEASE"

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

# Profil webu: static = web bez databaze, ostatni urcuji ovladac databaze (a zavislostni image).
case "$PROFILE" in
    static | mariadb | mysql | postgres) ;;
    *) die "kubernetes/values-$NAME.yml: generic.pweProfile '$PROFILE' neni profil PWE (static, mariadb, mysql, postgres)" ;;
esac
# Nazev image: cesta repozitare bez registru a tagu. Jine znaky (dvojtecka s tagem, velka pismena) by navic
# obesly kontrolu vyhrazenych nazvu niz.
case "$IMAGE_NAME" in
    *[!"$LOWER_CHARS$DIGITS"._/-]* | /* | */ | *//*)
        die "kubernetes/values-$NAME.yml: generic.pweImage '$IMAGE_NAME' neni nazev image: smi obsahovat jen mala pismena, cislice a znaky . _ - / (bez registru a tagu - registr urcuje K8S_REGISTRY, tag K8S_IMAGE_TAG)" ;;
esac

# Druh nasazeni podle nazvu image. pwe-example-<profil> je hotovy image vzoroveho webu (knihovny, engine
# i web; static: example.web, databazove profily: example-db.web) = vzorove nasazeni, nic se nestavi.
# Jakykoli jiny nazev je image vlastniho webu, ktery stavi a nahrava prikaz image.
SAMPLE=0
SAMPLE_WEB=""
SAMPLE_PROFILE=""
SAMPLE_IMAGES="pwe-example-static, pwe-example-mariadb, pwe-example-mysql, pwe-example-postgres"
case "$IMAGE_NAME" in
    pwe-example-static) SAMPLE_WEB="example.web"; SAMPLE_PROFILE="static" ;;
    pwe-example-mariadb | pwe-example-mysql | pwe-example-postgres) SAMPLE_WEB="example-db.web"; SAMPLE_PROFILE="${IMAGE_NAME#pwe-example-}" ;;
esac
if [ -n "$SAMPLE_WEB" ]; then
    # Image vzoroveho webu ma web i profil zapecene: values, ktere tvrdi neco jineho, jsou chyba (typicky
    # kopie values pro vlastni web, ve ktere zustal nazev image, nebo zmeneny jen pweProfile).
    [ "$WEB" = "$SAMPLE_WEB" ] \
        || die "kubernetes/values-$NAME.yml: generic.pweImage '$IMAGE_NAME' je image vzoroveho webu $SAMPLE_WEB, ale generic.pweWeb je '$WEB'. Pro vlastni web nastav generic.pweImage na nazev image webu (stavi ho make k8s-image K8S=$NAME)"
    [ "$PROFILE" = "$SAMPLE_PROFILE" ] \
        || die "kubernetes/values-$NAME.yml: generic.pweImage '$IMAGE_NAME' je image vzoroveho webu s profilem $SAMPLE_PROFILE, ale generic.pweProfile je '$PROFILE'. Vzorove nasazeni s jinym profilem ma jiny image ($SAMPLE_IMAGES) - zmen generic.pweImage i generic.pweProfile; image vlastniho webu pojmenuj jinak"
    SAMPLE=1
else
    # Vyhrazene nazvy (posledni cast cesty: i ns/pwe-base by s K8S_REGISTRY bez jmenneho prostoru mirilo na
    # image PWE). Bez teto kontroly by se braly jako image vlastniho webu a prikaz image by web nahral pod
    # jmenem image PWE - v registru, kde image PWE jsou (nebo zustaly stare tagy zrusenych), by prepsal tag.
    RESERVED=""
    case "${IMAGE_NAME##*/}" in
        pwe-example-*) RESERVED="nazvy pwe-example-* patri image vzorovych webu; existuji jen $SAMPLE_IMAGES a ve values se pisou bez cesty" ;;
        pwe | pwe-static) RESERVED="zruseny image, uz se nestavi ani nepublikuje" ;;
        pwe-base | pwe-debugger | pwe-mariadb | pwe-mysql | pwe-postgres) RESERVED="zavislostni image: jen knihovny, bez enginu a webu - nasadit ho nejde" ;;
    esac
    [ -z "$RESERVED" ] \
        || die "kubernetes/values-$NAME.yml: generic.pweImage '$IMAGE_NAME' je vyhrazeny nazev image PWE ($RESERVED). Vzorove nasazeni ma generic.pweImage $SAMPLE_IMAGES (podle generic.pweProfile); image vlastniho webu pojmenuj jinak"
fi

# Registr, ve kterem nasazovany image je (deploy v nem zjistuje digest, prikaz image do nej nahrava):
# K8S_REGISTRY; vzorove nasazeni ma vychozi registr image PWE (PWE_IMAGE_REGISTRY, jinak ghcr.io/kukam),
# vlastni web vychozi hodnotu nema. Cluster taha z K8S_PULL_REGISTRY, jinak ze stejneho registru.
REGISTRY="${K8S_REGISTRY:-}"
if [ -z "$REGISTRY" ] && [ "$SAMPLE" = 1 ]; then
    REGISTRY="$(pwe_image_registry)"
fi
REGISTRY="${REGISTRY%/}"
PULL_REGISTRY="${K8S_PULL_REGISTRY:-$REGISTRY}"
PULL_REGISTRY="${PULL_REGISTRY%/}"

# is_digest <text> - 0, kdyz je text digest image presneho tvaru sha256:<64 sestnactkovych znaku 0-9 a-f>
is_digest() {
    local hex="${1#sha256:}"
    case "$1" in sha256:*) ;; *) return 1 ;; esac
    [ "${#hex}" = 64 ] || return 1
    case "$hex" in *[!"$HEX_CHARS"]*) return 1 ;; esac
    return 0
}

# last_line <text> - posledni neprazdny radek textu (duvod chyby do hlasky)
last_line() {
    printf '%s\n' "$1" | sed -e '/^[[:space:]]*$/d' | tail -1
}

# capture <prikaz...> - spusti prikaz jednou, jeho stdout ulozi do CAP_OUT a stderr do CAP_ERR; vraci jeho
# navratovy kod. Proudy se ctou oddelene: stdout se dal zpracovava (digest image, jmena svazku) a varovani
# ze stderr se do nej nesmi primichat; stderr slouzi jen jako duvod do chybove hlasky.
capture() {
    local rc=0
    CAP_ERRFILE="$(mktemp "${TMPDIR:-/tmp}/pwe-k8s.XXXXXX")" || die "nelze zalozit docasny soubor (mktemp)"
    # docasny soubor se smaze i pri preruseni skriptu (Ctrl-C behem dotazu do registru nebo clusteru)
    trap 'rm -f "$CAP_ERRFILE"' EXIT
    CAP_OUT="$("$@" 2> "$CAP_ERRFILE")" || rc=$?
    CAP_ERR="$(cat "$CAP_ERRFILE" 2> /dev/null || true)"
    rm -f "$CAP_ERRFILE"
    trap - EXIT
    return "$rc"
}

# need_tag - nastavi TAG, tag nasazovaneho image: K8S_IMAGE_TAG, jinak u vzoroveho nasazeni tag image
# PWE (pwe_image_tag: PWE_IMAGE_TAG, jinak verze z PWE/VERSION) a u vlastniho webu latest (nezavisle
# na PWE_IMAGE_TAG). Muze obsahovat i digest: <tag>@sha256:<64 hex znaku>. Volaji ho jen prikazy, ktere
# s image pracuji (image, template, deploy) - status, logs, test a delete tag nepotrebuji.
need_tag() {
    if [ -n "${K8S_IMAGE_TAG:-}" ]; then
        TAG="$K8S_IMAGE_TAG"
    elif [ "$SAMPLE" = 1 ]; then
        # hlasku o neplatnem PWE_IMAGE_TAG nebo PWE/VERSION vypise pwe_image_tag
        TAG="$(pwe_image_tag)" || exit 2
    else
        TAG="latest"
    fi
    pwe_image_tag_valid "${TAG%%@*}" \
        || die "K8S_IMAGE_TAG='$TAG' neni platny tag image (povolene znaky A-Z a-z 0-9 _ . -, nezacina teckou ani pomlckou, nejvys 128 znaku)"
    case "$TAG" in
        *@*) is_digest "${TAG#*@}" || die "K8S_IMAGE_TAG='$TAG': za @ musi byt digest sha256:<64 sestnactkovych znaku 0-9 a-f>" ;;
    esac
    return 0
}

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

# release_in_cluster - zjisti, jestli release nebo svazek databaze releasu v clusteru uz existuje:
#   0 = existuje (helm status uspel, nebo dotaz na svazky neco nasel),
#   1 = prokazatelne neexistuje: helm status ohlasil "release: not found" A dotaz na svazky probehl
#       uspesne a nic nenasel.
# Kdyz stav nejde zjistit (nedostupny cluster, preklep v KUBE_CONTEXT, vyprsene prihlaseni, chybejici
# opravneni, chybejici program kubectl - jakakoli jina chyba helm nebo kubectl), skonci chybou. "Nevim" se
# nesmi brat jako "release neexistuje": zalozila by se nova hesla k existujici databazi a dalsi (uz
# uspesny) deploy by jimi prepsal Secret releasu.
release_in_cluster() {
    local out why rc=0
    local hint="nova hesla nezakladam (kubernetes/secrets-$NAME.yml chybi; kdyz release uz existuje, zkopiruj soubor ze stroje, odkud se nasazovalo). Nova hesla jen vyslovne: K8S_NEW_SECRETS=1"
    out="$("$HELM" status "$RELEASE" --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" 2>&1)" || rc=$?
    [ "$rc" != 0 ] || return 0
    case "$out" in
        *"release: not found"*) ;;
        *)
            why="$(last_line "$out")"
            die "stav releasu $RELEASE v clusteru nelze zjistit (${why:-$HELM status skoncil kodem $rc bez hlasky}) - $hint. Over KUBE_CONTEXT, pripojeni a prihlaseni ke clusteru: $HELM --kube-context $KUBE_CONTEXT -n $NAMESPACE status $RELEASE"
            ;;
    esac
    command -v "$KUBECTL" > /dev/null 2>&1 \
        || die "svazky releasu $RELEASE v clusteru nelze zjistit (program $KUBECTL neni nainstalovany) - $hint"
    rc=0
    capture kc get persistentvolumeclaims -l "$SELECTOR" -o name || rc=$?
    if [ "$rc" != 0 ]; then
        why="$(last_line "$CAP_ERR")"
        die "svazky releasu $RELEASE v clusteru nelze zjistit (${why:-$KUBECTL skoncil kodem $rc bez hlasky}) - $hint. Over: $KUBECTL --context $KUBE_CONTEXT -n $NAMESPACE get persistentvolumeclaims -l $SELECTOR"
    fi
    [ -n "$CAP_OUT" ]
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
    if [ -n "$PULL_REGISTRY" ]; then
        HELM_ARGS+=(--set-string "generic.pweRegistry=$PULL_REGISTRY")
        # Digest se zjistuje v REGISTRY, cluster ale taha z PULL_REGISTRY. Ze jde o zrcadlo tehoz registru,
        # skript overit neumi (proxy cache byva dostupna jen z clusteru) - proto to pred nasazenim aspon
        # zretelne rekne. Typicka past: K8S_PULL_REGISTRY v local.env a K8S_REGISTRY prepsany jen pro
        # jedno nasazeni - pody by pak skoncily v ImagePullBackOff.
        if [ -n "$REGISTRY" ] && [ "$PULL_REGISTRY" != "$REGISTRY" ]; then
            echo "[k8s] image se overuje v registru $REGISTRY (tam se zjistuje digest), cluster ho ale taha z $PULL_REGISTRY/$IMAGE_NAME (K8S_PULL_REGISTRY) - musi to byt zrcadlo (proxy cache) registru $REGISTRY, jinak pody skonci v ImagePullBackOff" >&2
        fi
    fi
    HELM_ARGS+=(--set-string "generic.pweImageTag=$IMAGE_TAG_REF")
    [ -n "${K8S_DOMAIN:-}" ] && HELM_ARGS+=(--set-string "generic.pweDomain=$K8S_DOMAIN")
    [ -n "${K8S_ISSUER:-}" ] && HELM_ARGS+=(--set-string "generic.pweIssuer=$K8S_ISSUER")
    HELM_ARGS+=(${EXTRA_HELM[@]+"${EXTRA_HELM[@]}"})
    return 0
}

# resolve_image_tag [1] - zjisti digest tagu v registru, ve kterem nasazovany image je (REGISTRY); pody
# pak dostanou odkaz <tag>@sha256:... S argumentem 1 (deploy) je nezjisteny digest chyba (vyjimka
# K8S_ALLOW_TAG=1), jinak jen varovani a pouzije se tag. Pred volanim musi probehnout need_tag.
resolve_image_tag() {
    IMAGE_TAG_REF="$TAG"
    case "$TAG" in *@*) return 0 ;; esac
    local why="" advice="" digest="" line rc=0
    local ref="${REGISTRY:-<K8S_REGISTRY>}/$IMAGE_NAME:$TAG"
    if [ -z "$REGISTRY" ]; then
        why="neni nastaven K8S_REGISTRY"
    elif ! command -v docker > /dev/null 2>&1; then
        why="chybi program docker"
    else
        # Digest je jen radek stdout presneho tvaru sha256:<64 hex> z uspesneho behu dockeru. Varovani
        # dockeru na stderr se do odkazu na image nesmi dostat (cte se oddelene, jen jako duvod chyby).
        capture docker buildx imagetools inspect "$REGISTRY/$IMAGE_NAME:$TAG" --format '{{.Manifest.Digest}}' || rc=$?
        if [ "$rc" = 0 ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"
                if is_digest "$line"; then
                    digest="$line"
                    break
                fi
            done <<< "$CAP_OUT"
        fi
        if [ -n "$digest" ]; then
            IMAGE_TAG_REF="$TAG@$digest"
            echo "[k8s] image $ref ma digest $digest" >&2
            return 0
        fi
        if [ "$rc" = 0 ]; then
            why="docker nevypsal digest tvaru sha256:<64 hex>, ale: $(last_line "$CAP_OUT")"
        else
            why="$(last_line "$CAP_ERR")"
            [ -n "$why" ] || why="docker skoncil kodem $rc bez hlasky"
        fi
    fi
    if [ "${1:-0}" = 1 ] && [ -z "${K8S_ALLOW_TAG:-}" ]; then
        if [ "$SAMPLE" = 1 ]; then
            advice="Vzorove nasazeni $NAME bere hotovy image vzoroveho webu z registru $REGISTRY"
            if [ -n "${K8S_REGISTRY:-}" ]; then
                advice="$advice (K8S_REGISTRY z prostredi nebo z kubernetes/local.env plati i pro vzorova nasazeni; registr image PWE: K8S_REGISTRY=$(pwe_image_registry))"
            else
                advice="$advice (PWE_IMAGE_REGISTRY)"
            fi
            advice="$advice: over, ze tam image s tagem ${TAG} je (publikuje ho pipeline; make images ho stavi jen mistne) a ze k nemu ma docker pristup (docker login), nebo zvol jiny registr ci tag (K8S_REGISTRY=<registr>, K8S_IMAGE_TAG=latest)."
            # K8S_PULL_REGISTRY (typicky z local.env) plati dal i s jinym K8S_REGISTRY. Bez teto vety by rada
            # vedla k digestu z jednoho registru a tahani z proxy cache jineho (pody v ImagePullBackOff).
            if [ -n "${K8S_PULL_REGISTRY:-}" ]; then
                advice="$advice S jinym K8S_REGISTRY zmen i K8S_PULL_REGISTRY (ted $PULL_REGISTRY, plati dal): na zrcadlo noveho registru, nebo na registr sam, kdyz na nej cluster dosahne primo."
            fi
        else
            advice="Image nejdriv sestav a nahraj: make k8s-image K8S=$NAME."
        fi
        die "digest image $ref nelze zjistit ($why). $advice Nasazeni jen podle tagu (novy image pod stejnym tagem pak pody nevymeni): K8S_ALLOW_TAG=1"
    fi
    echo "[k8s] VAROVANI: digest image $ref nelze zjistit ($why) - pouzivam jen tag" >&2
    return 0
}

# set_dry_run <argumenty helmu v poradi, v jakem je dostane> - nastavi DRY_RUN=1, kdyz jde o zkousku
# nasucho, jinak 0. Plati posledni vyskyt prepinace (jako u helmu); --dry-run=none a --dry-run=false
# znamenaji skutecne nasazeni. Neznama hodnota se odmitne: podle DRY_RUN se rozhoduje, jestli se zalozi
# skutecna hesla, nebo pouzije vzor s CHANGE_ME, a ten se do clusteru dostat nesmi.
set_dry_run() {
    local a
    DRY_RUN=0
    for a in "$@"; do
        case "$a" in
            --dry-run=none | --dry-run=false) DRY_RUN=0 ;;
            --dry-run | --dry-run=client | --dry-run=server | --dry-run=true) DRY_RUN=1 ;;
            --dry-run=*) die "prepinac '$a': neznama hodnota --dry-run (povolene: client, server, true = zkouska nasucho; none, false = skutecne nasazeni)" ;;
        esac
    done
    return 0
}

# check_web_dockerfile <Dockerfile webu> - Dockerfile z drivejsi sablony pocita se zakladnim image, ktery
# obsahuje engine: stavi nad zrusenym image (FROM .../pwe jako nosic enginu, FROM .../pwe-static), nebo ze
# zakladu maze vzorovy web. Zavislostni image engine ani web neobsahuji - sestaveni by skoncilo zavadejici
# chybou, a kde v mistnim Dockeru nebo v registru zustaly stare tagy, proslo by tise a image webu by dostal
# engine z doby, kdy stary image vznikl. Na pwe-static vede i FROM .../pwe-${PWE_PROFILE} s profilem static:
# to je bud drivejsi sablona, nebo Dockerfile webu s databazi a chybny generic.pweProfile ve values.
# Pozna se jen to, co je jiste (radky FROM a mazani vzoroveho webu); komentare se preskakuji, jiny
# Dockerfile projde. Uplnou kontrolu Dockerfile proti sablone dela make check (PWE/tools/check-webapp.pl),
# ten jen varuje.
check_web_dockerfile() {
    local file="$1" line ref base why="" by_profile=0 db=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            '#'*) continue ;;
            *[[:space:]]rm[[:space:]]*/PWE/webapps/example.web* | *[[:space:]]rm[[:space:]]*/PWE/webapps/example-db.web*) why="ze zakladniho image maze vzorovy web" ;;
            [Ff][Rr][Oo][Mm][[:space:]]*)
                # image = prvni slovo za FROM, ktere neni prepinac (--platform=...); z nej nazev bez registru,
                # digestu a tagu
                ref=""
                set -f
                # shellcheck disable=SC2086
                set -- $line
                set +f
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in --*) shift ;; *) ref="$1"; break ;; esac
                done
                base="${ref%%@*}"
                base="${base##*/}"
                base="${base%%:*}"
                # shellcheck disable=SC2016
                case "$base" in
                    pwe | pwe-static) why="stavi nad zrusenym image $base" ;;
                    'pwe-${PWE_PROFILE}' | 'pwe-$PWE_PROFILE') [ "$PROFILE" != static ] || by_profile=1 ;;
                esac
                ;;
        esac
        [ -z "$why" ] || break
    done < "$file"
    [ "$PROFILE" = static ] || db=" --db $PROFILE"
    [ -z "$why" ] \
        || die "webapps/$WEB/Dockerfile je z drivejsi sablony ($why). Zavislostni image engine ani vzorovy web neobsahuji: Dockerfile webu stavi nad $BASE_NAME a engine kopiruje z kontextu sestaveni (COPY PWE/...). Vygeneruj novy: PWE/tools/new-webapp.pl $WEB$db --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne); kontrola: make check WEB=$WEB"
    [ "$by_profile" = 0 ] \
        || die "webapps/$WEB/Dockerfile stavi nad zavislostnim image profilu (FROM .../pwe-\${PWE_PROFILE}), ale generic.pweProfile v kubernetes/values-$NAME.yml je static - image pwe-static neexistuje, web bez databaze stavi nad pwe-base. Web s databazi: nastav generic.pweProfile na jeji profil (mariadb, mysql, postgres). Web bez databaze: vygeneruj novy Dockerfile: PWE/tools/new-webapp.pl $WEB --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne); kontrola: make check WEB=$WEB"
    return 0
}

# check_base_platform <image> - zavislostni image, nad kterym se stavi image vlastniho webu (pwe-<profil>,
# u webu bez databaze pwe-base), musi v mistnim Dockeru existovat pro cilovou platformu. Jinak by ho buildx
# podle verze a uloziste image bud pouzil jen s varovanim InvalidBaseImagePlatform (image webu s binarkami
# jine architektury, v clusteru "exec format error"), nebo by sestaveni skoncilo chybou "no match for
# platform in manifest". Image, ktery mistne neni, se nekontroluje: buildx ho stahne z registru.
check_base_platform() {
    local img p have platforms tag
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
            # make images oznacuje jen tagy <verze> a latest (prepsal by mistni image pro platformu stroje),
            # proto rada stavi stage zavislostniho image primo a pod vlastnim tagem
            tag="${img##*:}-$(printf '%s' "${p#*/}" | tr '/' '-')"
            die "mistni image $img neni pro platformu $p (je $have). Image vlastniho webu se stavi nad nim, proto musi byt pro platformu clusteru. Sestav ho pro ni pod vlastnim tagem: docker build --platform $p --target $BASE_STAGE -t ${img%:*}:$tag -f PWE/docker/Dockerfile . a ten predej pri sestaveni webu: PWE_IMAGE_TAG=$tag make k8s-image K8S=$NAME (kubernetes/README.md, Vlastni web)"
        done
    done
    return 0
}

case "$CMD" in
    image)
        need_tag
        if [ "$SAMPLE" = 1 ]; then
            # Vzorove nasazeni: image vzoroveho webu uz knihovny, engine i web obsahuje a je v registru
            # image PWE - neni co stavet ani nahravat.
            echo "[k8s] nasazeni $NAME je vzorove: pouziva hotovy image vzoroveho webu $REGISTRY/$IMAGE_NAME:$TAG (knihovny, engine i web $WEB) - nic se nestavi. Nasazeni: make k8s-deploy K8S=$NAME" >&2
            echo "[k8s] image vzorovych webu stavi make images a do registru je publikuje pipeline; make k8s-image stavi jen image vlastniho webu (generic.pweImage jiny nez pwe-example-<profil>), viz kubernetes/README.md, Vlastni web" >&2
            exit 0
        fi
        [ -n "$REGISTRY" ] || die "neni nastaven K8S_REGISTRY (registr, do ktereho se image webu nahrava, napr. docker.io/<ucet>)"
        case "$TAG" in *@*) die "K8S_IMAGE_TAG s digestem ($TAG) nelze pouzit pro sestaveni - zadej jen tag" ;; esac
        [ -f "$ROOT/webapps/$WEB/Dockerfile" ] || die "webapps/$WEB/Dockerfile neexistuje (generic.pweWeb v kubernetes/values-$NAME.yml)"
        # Image webu = zavislostni image + engine + web. Dockerfile webu stavi nad zavislostnim image profilu
        # (pwe-<profil>; web bez databaze, profil static, nad pwe-base - image pwe-static neexistuje) a engine
        # si bere z kontextu sestaveni, tedy z pracovni kopie. BASE_STAGE = stage (a cil bake) v
        # PWE/docker/Dockerfile, ze ktere zavislostni image vznika.
        case "$PROFILE" in
            static) BASE_NAME="pwe-base"; BASE_STAGE="base" ;;
            *) BASE_NAME="pwe-$PROFILE"; BASE_STAGE="$PROFILE" ;;
        esac
        check_web_dockerfile "$ROOT/webapps/$WEB/Dockerfile"
        need_program docker "Image webu se stavi pres docker buildx."
        BASE_REGISTRY="$(pwe_image_registry)"
        BASE_TAG="$(pwe_image_tag)"
        BASE_IMAGE="$BASE_REGISTRY/$BASE_NAME:$BASE_TAG"
        TARGET="$REGISTRY/$IMAGE_NAME:$TAG"
        check_base_platform "$BASE_IMAGE"
        # Builder s ovladacem docker se jmenuje stejne jako aktualni kontext dockeru (default na Linuxu,
        # desktop-linux v Docker Desktop). Jen ten vidi lokalne sestavene zavislostni image.
        BUILDER="${K8S_BUILDER:-$(docker context show 2> /dev/null || echo default)}"
        echo "[k8s] image webu $TARGET ($PLATFORM): zavislostni image $BASE_IMAGE + engine z pracovni kopie (PWE/) + web webapps/$WEB" >&2
        docker buildx build \
            --builder "$BUILDER" \
            --platform "$PLATFORM" \
            --provenance=false --sbom=false \
            -f "$ROOT/webapps/$WEB/Dockerfile" \
            --build-arg "PWE_IMAGE_REGISTRY=$BASE_REGISTRY" \
            --build-arg "PWE_IMAGE_TAG=$BASE_TAG" \
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
        need_tag
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
        # argumenty v poradi, v jakem je helm dostane: K8S_HELM_ARGS, pak argumenty prikazove radky
        set_dry_run ${EXTRA_HELM[@]+"${EXTRA_HELM[@]}"} "$@"
        need_tag
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
            # (-c fcgi, -cfcgi, -c=fcgi, -fc fcgi i --container[=]: s vybranym kontejnerem kubectl --all-containers odmita)
            case "$a" in --container | --container=*) ALL_CONTAINERS=() ;; esac
            if has_short_flag "$a" c lnsv; then ALL_CONTAINERS=(); fi
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
        set_dry_run "$@"
        # helm uninstall bere kazdy argument bez pomlcky jako DALSI release: "delete static pwe-example-mariadb"
        # by odinstaloval i release, jehoz soubor s hesly pojistka nize nekontroluje. Povolene jsou jen
        # prepinace; hodnota oddelena mezerou se preskoci u prepinacu helm uninstall, ktere hodnotu maji.
        skip_value=0
        for arg in "$@"; do
            if [ "$skip_value" = 1 ]; then
                skip_value=0
                continue
            fi
            case "$arg" in
                --cascade | --description | --timeout | --burst-limit | --qps | --registry-config | --repository-cache | --repository-config)
                    skip_value=1 ;;
                -*) ;;
                *) die "delete: argument '$arg' by helm vzal jako dalsi release k odinstalovani - odinstalovava se jen release $RELEASE; dalsi nasazeni odinstaluj zvlast (make k8s-delete K8S=<nazev>)" ;;
            esac
        done
        # Hesla databaze jsou jen v souboru secrets-<nazev>.yml a v releasu. Kdyz soubor na tomto stroji
        # chybi, odinstalovani by smazalo jejich posledni kopii, zatimco svazek databaze zustava - data by
        # pak byla bez zasahu primo do databaze nedostupna. (Deploy ma pro zrcadlovy pripad release_in_cluster.)
        if [ "$DRY_RUN" = 0 ] && [ -z "${K8S_DELETE_WITHOUT_SECRETS:-}" ] \
            && [ -f "$ROOT/kubernetes/secrets-$NAME.example.yml" ] && [ ! -f "$ROOT/kubernetes/secrets-$NAME.yml" ]; then
            die "kubernetes/secrets-$NAME.yml na tomto stroji chybi - po odinstalovani by hesla databaze zustala jen ve svazku, ktery odinstalovani nemaze, a nove nasazeni by se k nemu nepripojilo. Nejdriv hesla uloz: $HELM --kube-context $KUBE_CONTEXT -n $NAMESPACE get values $RELEASE -o yaml (klic secrets; vystup obsahuje hesla), nebo soubor zkopiruj ze stroje, odkud se nasazovalo. Odinstalovat presto: K8S_DELETE_WITHOUT_SECRETS=1"
        fi
        # jmena Secretu s certifikatem zjistit pred odinstalovanim (pak uz ingress neni)
        TLS="$(kc get ingress -l "$SELECTOR" -o jsonpath='{.items[*].spec.tls[*].secretName}' 2> /dev/null || true)"
        "$HELM" uninstall "$RELEASE" --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
        if [ "$DRY_RUN" = 1 ]; then
            echo "[k8s] zkouska nasucho (--dry-run): release $RELEASE zustava" >&2
            exit 0
        fi
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
