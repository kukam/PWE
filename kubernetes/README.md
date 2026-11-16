# Nasazení webu PWE do Kubernetes

Web nad PWE se do Kubernetes nasazuje jako **jeden image, který obsahuje knihovny, engine i web**,
obecným chartem [nxs-universal-chart](https://github.com/nixys/nxs-universal-chart) —
`oci://registry.nixys.ru/nuc/nxs-universal-chart`, verze **3.2.2**. Chart nemá žádné šablony
specifické pro PWE: všechno, co se nasadí, popisuje soubor s hodnotami `values-<název>.yml`.
Nasazení i kontrolu dělají cíle `make k8s-*` (skript `PWE/tools/k8s.sh`).

Jsou dva druhy nasazení a liší se jen tím, odkud se image bere:

- **Vzorové nasazení** používá hotový image vzorového webu z registru (`pwe-example-static`,
  `pwe-example-mariadb` …). Staví a publikuje ho pipeline, takže se pro nasazení **nic nestaví**.
- **Vlastní web** má vlastní image. Staví se Dockerfilem webu (`webapps/<web>/Dockerfile`) z kořene
  repozitáře — závislostní image `pwe-<profil>` (web bez databáze `pwe-base`) + engine z pracovní
  kopie + web — a nahrává se do tvého registru, viz [Vlastní web](#vlastní-web).

V repozitáři jsou dvě hotová vzorová nasazení:

| Název | Image | Co se nasadí | Adresa |
| --- | --- | --- | --- |
| `example-static` | `ghcr.io/kukam/pwe-example-static` (`pwe-base` + engine + `example.web`, bez databáze) | web | `https://pwe-example-static.<doména>` |
| `example-mariadb` | `ghcr.io/kukam/pwe-example-mariadb` (`pwe-mariadb` + engine + `example-db.web`) | web + MariaDB | `https://pwe-example-mariadb.<doména>` |
| `example-mysql` | `ghcr.io/kukam/pwe-example-mysql` (`pwe-mysql` + engine + `example-db.web`) | web + MySQL | `https://pwe-example-mysql.<doména>` |
| `example-postgres` | `ghcr.io/kukam/pwe-example-postgres` (`pwe-postgres` + engine + `example-db.web`) | web + PostgreSQL | `https://pwe-example-postgres.<doména>` |

Název nasazení odpovídá názvu image bez předpony `pwe-`: release, adresa webu i namespace se pak jmenují
stejně (`pwe-example-<varianta>`). Každé nasazení má vlastní namespace.

Chart, manifesty a postup byly ověřeny nasazením obou vzorových webů do clusteru s Kubernetes 1.32,
ingress-nginx a cert-managerem (certifikát Let's Encrypt přes DNS-01), s Helm 3.22 — tehdy s image
vzorových webů z jiného registru a s enginem naslouchajícím na všech rozhraních podu. Současné
uspořádání (image `pwe-example-*` sestavené šablonou webu, engine jen na `127.0.0.1`) je ověřené
vyrenderováním manifestů (`helm template`, `helm lint`) a spuštěním podů podle nich v Dockeru nad
místně sestavenými image; **v clusteru zatím ne**. S Helm 4 a s jinými ingress controllery nasazení
ověřené není.

> **Zásada:** skript nikdy nepoužije „aktuální kontext“ `kubectl`. Cluster se vybírá jen proměnnou
> `KUBE_CONTEXT` a každý příkaz `helm` i `kubectl` ji dostane výslovně. I v tomto návodu má každý
> příkaz `kubectl` volbu `--context` — na stroji s více clustery tak nic neskončí jinde.

## Soubory v tomto adresáři

| Soubor | K čemu je |
| --- | --- |
| `values-example-static.yml` | hodnoty chartu pro web bez databáze |
| `values-example-mariadb.yml` | hodnoty chartu pro web s databází MariaDB |
| `secrets-example-mariadb.example.yml` | vzor souboru s hesly databáze |
| `local.env.example` | vzor místního nastavení (kontext, doména, registr) |
| `local.env` | tvoje místní nastavení — **není v gitu** (`.gitignore`) |
| `secrets-<název>.yml` | skutečná hesla — **nejsou v gitu**, založí se při prvním nasazení |

## Co se v clusteru vytvoří

```text
Ingress pwe-<název>-web            HTTPS, certifikát vystaví cert-manager (Secret pwe-<název>-web-tls)
  └─ Service pwe-<název>-web       port 80
       └─ Deployment pwe-<název>-web   (výchozí 2 pody)
            ├─ initContainer static    z image zkopíruje statiku do sdíleného svazku
            ├─ kontejner nginx         port 80: statiku posílá sám, ostatní předá enginu
            └─ kontejner fcgi          engine PWE, FastCGI na 127.0.0.1:7779 (jen uvnitř podu)
NetworkPolicy pwe-<název>-web      do podů webu zvenku jen port 80

jen generic:
StatefulSet pwe-example-mariadb-mariadb    MariaDB, 1 pod, svazek 1 Gi (PVC data-pwe-example-mariadb-mariadb-0)
Service pwe-example-mariadb-mariadb        port 3306, dostupná jen uvnitř clusteru
NetworkPolicy pwe-example-mariadb-mariadb  databáze přijímá spojení jen od podů webu
Secret pwe-example-mariadb-db              hesla databáze
```

- **Jeden pod = nginx + engine.** Proces enginu obsluhuje jeden požadavek najednou; souběžnost
  dávají pody (`deployments.web.replicas`). Statické soubory (`static/` a `assets/` webu,
  `assets/` enginu) posílá nginx přímo z kopie, kterou při startu podu připraví initContainer —
  stejné rozdělení jako ve vývojovém stacku (`docker-compose/docker-compose_nginx.conf`).
- **HTTPS končí na ingressu**, do podu jde HTTP. Nginx v podu předává enginu původní schéma
  (`HTTPS=on` podle hlavičky `X-Forwarded-Proto`) a skutečnou adresu klienta (`X-Forwarded-For`).
- **Engine poslouchá jen na `127.0.0.1:7779`** (`FCGI_SOCKET_PATH`), tedy jen pro nginx téhož podu.
  Z jiných podů port dostupný není — nikdo tak nemůže obejít ingress a nginx a podvrhnout enginu
  adresu klienta nebo HTTPS, a to ani v clusteru, kde se síťová pravidla neuplatní. Adresu
  `host:port` umí engine od verze 2.2.1.
- **Web bez databáze** si stav návštěvníka ukládá do souborů v podu, proto ingress drží návštěvníka
  u stejného podu (cookie `pwe-pod`). **Web s databází** má stav v databázi; schéma si při prvním
  startu založí engine sám (migrace `conf/mariadb.dbversion`).
- **Nahrané soubory** (`uploadfile/`) jsou v obou příkladech jen v podu a zaniknou s ním. Pro
  skutečný web použij sdílený svazek — viz [Škálování a data](#škálování-a-data).
- **Sondy** enginu se spouštějí uvnitř kontejneru (`exec`) a zkoušejí spojení na `127.0.0.1:7779`.
  Engine otevře FastCGI socket až po připojení k databázi a migracích schématu. Do té doby ho hlídá
  jen `startupProbe` (až 10 minut), takže ho liveness sonda nezabije uprostřed migrace. Před
  ukončením podu čekají oba kontejnery 5 s (`preStop`): ingress mezitím pod vyřadí a rozpracované
  požadavky doběhnou.
- **Síťová pravidla** (`networkPolicies`): do podů webu smí zvenku jen port 80 (nginx), databáze
  přijímá spojení jen od podů webu téhož releasu. Pravidla uplatní jen síťový plugin, který
  `NetworkPolicy` podporuje (Calico, Cilium …), a globální pravidla pluginu mají přednost.
  **V ověřovacím clusteru se neuplatnila:** globální pravidlo Calico `default.allow-node-to-node`
  (order 50, `selector: all()`) tam povoluje veškerý provoz mezi pody dřív, než se pravidla
  namespace vyhodnotí. Ochrana portu enginu na nich proto nestojí (viz výše); databázi pak před
  ostatními pody chrání jen heslo. Ověření ve vlastním clusteru: z podu mimo release zkus spojení
  na `pwe-example-mariadb-mariadb.<namespace>:3306` — nesmí se navázat.
- Pody nemají token service accountu, kontejnery běží bez linuxových oprávnění (engine jako root
  bez capabilities, nginx jen s těmi, které potřebuje) a s profilem seccomp `RuntimeDefault`.

## Image a tagy

- **Závislostní image** `pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` a `pwe-debugger` nesou
  jen běhové knihovny (a ovladač databáze). **Engine ani web v nich není**, takže se nasadit nedají:
  jsou základem image webu a ve vývojovém stacku dostávají engine mountem repozitáře.
- **Image vzorových webů** `pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql`
  a `pwe-example-postgres` jsou závislostní image + engine v `/PWE/PWE` + vzorový web ve
  `/PWE/webapps/`. Vznikají stejnou šablonou jako image vlastního webu — přímo z
  `webapps/example.web/Dockerfile` a `webapps/example-db.web/Dockerfile` — a jsou samy spustitelné.
  Do registru je publikuje pipeline; `make images` je staví jen do místního Dockeru.
- Image `pwe` (samotný engine) a `pwe-static` byly **zrušeny**: engine se do image webu kopíruje
  z repozitáře a web bez databáze běží nad `pwe-base`. Přehled všech image:
  [`docs/17-nasazeni.md`](../docs/17-nasazeni.md).
- **Každý image má právě dva tagy:** `<verze>` (obsah `PWE/VERSION`, např. `2.2.1`) a `latest`.
  Tagy podle větve gitu neexistují. Image publikuje pipeline GitHub Actions z výchozí větve
  repozitáře (a z větví vyjmenovaných v proměnné repozitáře `PUBLISH_BRANCHES`) pro `linux/amd64`
  i `linux/arm64`.
- **Oba tagy se přepisují** (i tag verze, dokud se `PWE/VERSION` nezvýší). Proto se **nasazuje podle
  digestu**: `make k8s-deploy` si v registru zjistí digest tagu a pody dostanou odkaz
  `<image>:<tag>@sha256:…`. V clusteru tak běží přesně to, co bylo v registru v okamžiku nasazení,
  a nový image pod stejným tagem vyvolá při dalším `make k8s-deploy` výměnu podů.

Který image se nasadí, určují tyto proměnné (prostředí nebo `kubernetes/local.env`):

| Proměnná | Vzorové nasazení (`example-*`) | Vlastní web |
| --- | --- | --- |
| `K8S_REGISTRY` — registr, ve kterém image je; `make k8s-deploy` v něm zjišťuje digest | registr s image vzorových webů; výchozí `PWE_IMAGE_REGISTRY`, tedy `ghcr.io/kukam` | **povinný:** registr, do kterého `make k8s-image` nahrává image webu |
| `K8S_PULL_REGISTRY` — registr, ze kterého image tahá cluster | výchozí `K8S_REGISTRY`; jiný jen s proxy cache, a to **zrcadlem téhož registru** (digest se zjišťuje v `K8S_REGISTRY`) | totéž |
| `K8S_IMAGE_TAG` — tag nasazovaného image | výchozí `PWE_IMAGE_TAG`, jinak verze z `PWE/VERSION` | výchozí `latest`; na `PWE_IMAGE_TAG` nezávisí |
| `PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` — registr a tag image PWE | výchozí registr a tag nasazovaného image `pwe-example-<profil>` | závislostní image `pwe-<profil>` (web bez databáze `pwe-base`), nad kterým se image webu staví; engine se bere z pracovní kopie |
| `K8S_PLATFORM`, `K8S_BUILDER` | nepoužijí se (nic se nestaví) | platforma a builder image webu |

Druh nasazení pozná skript podle `generic.pweImage` ve values. **Vzorové nasazení** je právě jeden
z těchto čtyř názvů a `pweWeb` i `pweProfile` mu musí odpovídat:

| `pweImage` | `pweWeb` | `pweProfile` |
| --- | --- | --- |
| `pwe-example-static` | `example.web` | `static` |
| `pwe-example-mariadb` | `example-db.web` | `mariadb` |
| `pwe-example-mysql` | `example-db.web` | `mysql` |
| `pwe-example-postgres` | `example-db.web` | `postgres` |

Values, ve kterých web nebo profil názvu neodpovídá, skript odmítne (`generic.pweImage '…' je image
vzoroveho webu …, ale generic.pweWeb je '…'`, resp. `… je image vzoroveho webu s profilem …, ale
generic.pweProfile je '…'`). Jakýkoli jiný název je image **vlastního webu** — kromě **vyhrazených
názvů**, které skript odmítne také (`generic.pweImage '…' je vyhrazeny nazev image PWE (…)`):

- závislostní image `pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` a `pwe-debugger`,
- všechny názvy `pwe-example-*`,
- zrušené image `pwe` a `pwe-static`.

Bez toho by `make k8s-image` nahrál image webu pod jménem image PWE a v registru, kde image PWE jsou
(nebo kde zůstaly staré tagy zrušených image), by přepsal jeho tag. Platí to i pro název s cestou
(`muj-ucet/pwe-base`). `pweImage` je název bez registru a tagu — malá písmena, číslice a znaky
`. _ - /` (jinak `neni nazev image`); `pweProfile` je `static`, `mariadb`, `mysql` nebo `postgres`
(jinak `neni profil PWE`).

> **Pozor na společný `local.env`:** `K8S_REGISTRY`, `K8S_PULL_REGISTRY` i `K8S_IMAGE_TAG` zapsané
> v `kubernetes/local.env` platí pro **všechna** nasazení, i vzorová. Kdo má vlastní web i vzorová
> nasazení v různých registrech, předává registr na příkazové řádce — a **s ním i
> `K8S_PULL_REGISTRY`**, pokud ho `local.env` nastavuje. Proxy cache patří k jednomu registru
> a `K8S_PULL_REGISTRY` ze souboru platí dál, takže se samotným jiným `K8S_REGISTRY` by se digest
> zjistil v jednom registru a cluster by image tahal z proxy cache jiného (pody v `ImagePullBackOff`):
>
> ```bash
> make k8s-deploy K8S=example-static K8S_REGISTRY=ghcr.io/kukam K8S_PULL_REGISTRY=harbor.example.com/ghcr/kukam
> make k8s-deploy K8S=mujweb K8S_REGISTRY=docker.io/muj-ucet K8S_PULL_REGISTRY=harbor.example.com/dockerhub/muj-ucet
> ```
>
> (Když cluster na registr dosáhne přímo, nastav `K8S_PULL_REGISTRY` na tentýž registr jako
> `K8S_REGISTRY`.) Skript to ověřit neumí — proxy cache bývá dostupná jen z clusteru. Když se
> registry liší, před nasazením to aspoň oznámí: `[k8s] image se overuje v registru … (tam se
> zjistuje digest), cluster ho ale taha z … (K8S_PULL_REGISTRY) - musi to byt zrcadlo (proxy cache)
> registru …`.

## Co je potřeba

Na tvém stroji:

- `docker` s `buildx` — `make k8s-deploy` jím v registru zjišťuje digest image
  (`docker buildx imagetools inspect`), u vlastního webu jím `make k8s-image` staví a nahrává image.
  K registru, který není veřejný, musí být `docker` přihlášen (`docker login`),
- `helm` 3.8 nebo novější ([instalace](https://helm.sh/docs/intro/install/); chart je v registru
  OCI); ověřeno s Helm 3.22, s Helm 4 ne,
- `kubectl` s kontextem cílového clusteru, `make`, `curl`.

V clusteru (ověření v závorce):

- ingress controller třídy `nginx`, tj. ingress-nginx (`kubectl --context <kontext> get ingressclass`);
  s jiným controllerem změň `ingresses.web.ingressClassName` a anotace `nginx.ingress.kubernetes.io/*`
  nahraď jeho obdobami — bez afinity podle cookie nastav u webu bez databáze `deployments.web.replicas: 1`,
- cert-manager s `ClusterIssuer`em, který umí vystavit certifikát pro tvou doménu
  (`kubectl --context <kontext> get clusterissuer`),
- DNS záznam `pwe-<název>.<doména>` mířící na ingress (adresa je po nasazení ve sloupci `ADDRESS`
  výpisu `make k8s-status`),
- pro nasazení s databází výchozí `StorageClass` (`kubectl --context <kontext> get storageclass`, jedna označená
  `(default)`; jinak doplň `storageClassName` do `statefulSets.mariadb.volumeClaimTemplates`),
- uzly s architekturou `amd64` nebo `arm64` (`kubectl --context <kontext> get nodes -L kubernetes.io/arch`)
  a přístup k registru s image: veřejný repozitář, nebo soukromý repozitář a přihlašovací Secret —
  viz [Soukromý registr](#soukromý-registr). Když cluster na registr nedosáhne přímo, použij proxy
  cache (`K8S_PULL_REGISTRY`) nebo vlastní registr (`K8S_REGISTRY`).

## Postup

### 1. Místní nastavení

Jednou:

```bash
cp kubernetes/local.env.example kubernetes/local.env
$EDITOR kubernetes/local.env
```

| Proměnná | Význam |
| --- | --- |
| `KUBE_CONTEXT` | kontext `kubectl`, do kterého se nasazuje. **Povinný a bez výchozí hodnoty** — bez něj `deploy`, `status`, `logs` ani `delete` nic neudělají |
| `K8S_NAMESPACE` | namespace (výchozí = název releasu `pwe-<název>`, každé nasazení má vlastní; založí se při prvním nasazení). Hodnota z `local.env` by platila pro všechna nasazení — předávej ji jen na příkazové řádce. Jinak než touto proměnnou se nenastavuje — `-n` a `--namespace` v `ARGS` skript odmítne |
| `K8S_DOMAIN` | doména; nasazení `<název>` poběží na `https://pwe-<název>.<K8S_DOMAIN>` (jinou adresu určuje `generic.pweHost` ve values) |
| `K8S_ISSUER` | `ClusterIssuer` cert-manageru |
| `K8S_REGISTRY` | registr, ve kterém nasazovaný image je — viz [Image a tagy](#image-a-tagy). Pro vzorová nasazení ho nech prázdný (výchozí `ghcr.io/kukam`), pro vlastní web je povinný, např. `docker.io/muj-ucet` |
| `K8S_PULL_REGISTRY` | registr, ze kterého image tahá cluster — jen když se liší (proxy cache). Musí to být zrcadlo registru `K8S_REGISTRY`; s jiným `K8S_REGISTRY` změň i tuto proměnnou (viz [Image a tagy](#image-a-tagy)) |
| `K8S_IMAGE_TAG` | tag nasazovaného image — viz [Image a tagy](#image-a-tagy). Výchozí: vzorová nasazení verze enginu z `PWE/VERSION`, vlastní web `latest` |
| `K8S_PLATFORM` | platforma image vlastního webu (výchozí `linux/amd64`) |
| `K8S_HELM_ARGS` | další argumenty pro `helm`, např. `--set-string generic.pweNginxImage=…`; dělí se na mezerách, hodnoty s mezerou nejdou |
| `K8S_TIMEOUT` | jak dlouho `make k8s-deploy` čeká na připravené pody (výchozí `10m`) |
| `K8S_TAIL` | počet řádků logu na kontejner pro `make k8s-logs` (výchozí `100`) |
| `K8S_MAX_LOG_REQUESTS` | z kolika kontejnerů smí `make k8s-logs` číst současně (výchozí `20`; zvyš při větším počtu podů) |
| `K8S_BUILDER` | builder pro `docker buildx` při `make k8s-image` (výchozí builder aktuálního kontextu dockeru) |
| `K8S_CHART`, `K8S_CHART_VERSION` | chart a jeho verze (výchozí `oci://registry.nixys.ru/nuc/nxs-universal-chart`, `3.2.2`) — např. kopie chartu ve vlastním registru |
| `K8S_ALLOW_TAG=1` | výjimka: nasadit jen podle tagu, když digest image nejde zjistit |
| `K8S_NEW_SECRETS=1` | výjimka: vygenerovat nová hesla i pro release, který už existuje nebo jehož stav v clusteru nejde zjistit (viz [Hesla](#hesla)) |
| `K8S_DELETE_WITHOUT_SECRETS=1` | výjimka: `make k8s-delete` odinstaluje release s hesly, i když na tomto stroji chybí `secrets-<název>.yml` (viz [Odinstalování](#odinstalování)) |

V `local.env` se píše `KLÍČ=hodnota`, uvozovky kolem hodnoty a mezery se odstraní. Neprázdná
proměnná prostředí má přednost, takže každou hodnotu lze přepsat i na příkazové řádce:
`make k8s-deploy K8S=example-static KUBE_CONTEXT=jiny`.

Cluster se vybírá **jen** proměnnou `KUBE_CONTEXT` a namespace jen `K8S_NAMESPACE`. Proměnné,
kterými by je `helm` nebo `kubectl` vybraly jinak — všechny `HELM_KUBE*` (`HELM_KUBEAPISERVER`,
`HELM_KUBETOKEN`, `HELM_KUBECONTEXT` …), `HELM_NAMESPACE` a `KUBERNETES_MASTER` — skript před
spuštěním zruší, ať přišly z prostředí, nebo z `local.env`, a oznámí to (`[k8s] promenne … se
nepouziji`). `KUBECONFIG` se respektuje: určuje jen soubor s kontexty, kontext v něm vybírá vždy
`KUBE_CONTEXT`.

Vzorovým nasazením stačí `KUBE_CONTEXT`, `K8S_DOMAIN` a `K8S_ISSUER`.

### 2. Nasazení

```bash
make k8s-deploy K8S=example-static       # helm upgrade --install, čeká na připravené pody
make k8s-status K8S=example-static       # pody, služba, ingress, svazky, certifikát
make k8s-test   K8S=example-static       # ověří web přes HTTPS včetně platnosti certifikátu
```

Žádný image se nestaví: nasadí se `ghcr.io/kukam/pwe-example-static:<verze>` s verzí z `PWE/VERSION`
(`make k8s-image K8S=example-static` jen oznámí, že není co stavět, a skončí kódem 0). Image s tímto tagem
musí být v registru — publikuje ho pipeline z výchozí větve (`make images` ho staví jen do místního
Dockeru). Nejnovější publikovaný image bez ohledu na verzi v pracovní kopii nasadí
`K8S_IMAGE_TAG=latest make k8s-deploy K8S=example-static`.

Certifikát vystavuje cert-manager až po nasazení; s ověřením přes DNS to trvá obvykle 1–3 minuty.
Do té doby ingress odpovídá výchozím certifikátem a `make k8s-test` hlásí chybu certifikátu.

Pro web s databází je postup stejný s `K8S=example-mariadb` (image `pwe-example-mariadb`). Při prvním nasazení
skript založí `kubernetes/secrets-example-mariadb.yml` s náhodnými hesly — **soubor si uschovej** (viz
[Hesla](#hesla)).

### Přehled cílů

| Příkaz | Co udělá |
| --- | --- |
| `make k8s-image K8S=<název>` | vlastní web: sestaví image webu a nahraje ho do registru; vzorové nasazení: nic nestaví, jen to oznámí |
| `make k8s-template K8S=<název>` | vypíše manifesty, které by se nasadily; ke clusteru se nepřipojuje, v registru jen zjišťuje digest (výpis obsahuje hesla — nikam ho nevkládej) |
| `make k8s-deploy K8S=<název>` | nasadí nebo aktualizuje release `pwe-<název>` |
| `make k8s-deploy K8S=<název> ARGS=--dry-run=server` | zkouška nasucho: cluster manifesty jen zkontroluje, hesla se nezakládají (použije se vzor). Pozná se i v `K8S_HELM_ARGS`; `--dry-run=none` a `--dry-run=false` jsou skutečné nasazení, jinou hodnotu než `client`, `server` a `true` skript odmítne |
| `make k8s-status K8S=<název>` | stav releasu |
| `make k8s-test K8S=<název>` | ověří web přes HTTPS: úvodní stránku, statiku enginu (Bootstrap), statiku webu (`static/css/site.css`, má-li ji web) a `/healthz` |
| `make k8s-logs K8S=<název>` | posledních `K8S_TAIL` řádků logu všech kontejnerů; `ARGS=-f` průběžně, `ARGS='-c fcgi'` jen engine |
| `make k8s-delete K8S=<název>` | odinstaluje release (svazek databáze a certifikát zůstávají); u nasazení s hesly jen tehdy, když je na stroji `secrets-<název>.yml` — viz [Odinstalování](#odinstalování). `ARGS=--dry-run` jen vyzkouší |

Argumenty, které by změnily cluster, kontext, přihlášení nebo namespace, skript odmítne — i v
`K8S_HELM_ARGS`:

- u všech příkazů `--kube-context`, `--kubeconfig`, `--kube-apiserver`, `--kube-token`, `--kube-as-*`,
  `--kube-ca-file`, `--kube-insecure-skip-tls-verify`, `--kube-tls-server-name`, `--context`,
  `--cluster`, `--server` a `--namespace`,
- u `template`, `deploy` a `delete` (a v `K8S_HELM_ARGS`) krátké `-n`, i slepené s hodnotou nebo za
  jiným krátkým přepínačem (`-njiny`, `-n=jiny`, `-in jiny`),
- u `logs` krátké `-s` (API server) a `-n`, opět i slepené (`-shttps://…`, `-s=…`, `-fs …`), a přepínače
  přihlášení a ověření serveru (`--user`, `--username`, `--password`, `--token`, `--as`, `--as-group`,
  `--client-certificate`, `--client-key`, `--certificate-authority`, `--insecure-skip-tls-verify`,
  `--tls-server-name`).

Krátké přepínače s hodnotou projdou, i když jejich hodnota tato písmena obsahuje (`-f values-navic.yml`,
`-c nginx`).

## Aktualizace a návrat

- **Nasazuje se podle digestu** (viz [Image a tagy](#image-a-tagy)). Zjištění digestu potřebuje na
  stroji, ze kterého se nasazuje, `docker` s přístupem k registru. Když digest zjistit nejde (image
  v registru není, registr je nedostupný nebo `docker` není přihlášen), nasazení skončí chybou;
  s `K8S_ALLOW_TAG=1` nasadí jen podle tagu — nový image pod stejným tagem pak pody nevymění.
- **Vzorové nasazení** aktualizuje další `make k8s-deploy K8S=<název>`: když pipeline mezitím
  publikovala nový image pod stejným tagem, pody se vymění; po zvýšení `PWE/VERSION` se nasadí tag
  nové verze.
- **Vlastní web:** `make k8s-image K8S=<název> && make k8s-deploy K8S=<název>` — po změně webu i po
  aktualizaci enginu (engine se do image bere z pracovní kopie). Pro produkci použij neměnný tag,
  např. `K8S_IMAGE_TAG=1.4.0` (u obou příkazů), ne `latest`.
- Návrat k předchozí verzi: `helm --kube-context <kontext> -n pwe-<název> rollback pwe-<název>`.

## Nasazení bez make

`make k8s-deploy` jen skládá příkaz `helm`. Totéž ručně — digest tagu vypíše
`docker buildx imagetools inspect ghcr.io/kukam/pwe-example-static:2.2.1 --format '{{.Manifest.Digest}}'`:

```bash
helm upgrade --install pwe-example-static oci://registry.nixys.ru/nuc/nxs-universal-chart --version 3.2.2 \
    --kube-context <kontext> --namespace pwe --create-namespace --wait --timeout 10m \
    -f kubernetes/values-example-static.yml \
    --set-string generic.pweImageTag=2.2.1@sha256:<digest> \
    --set-string generic.pweDomain=example.com \
    --set-string generic.pweIssuer=letsencrypt
```

Pro nasazení s databází přidej `-f kubernetes/secrets-example-mariadb.yml`. Registr je ve values (`generic.pweRegistry`,
výchozí `ghcr.io/kukam`), jiný předá `--set-string generic.pweRegistry=…`.

Bez `generic.pweImageTag` se nasadí výchozí hodnota z values, tedy tag `latest` bez digestu. To se
hodí jen na zkoušku: chart nastavuje `imagePullPolicy: IfNotPresent`, takže uzel, který už image
`latest` má, si novější nestáhne, a nový image pod stejným tagem pody nevymění.

## Vlastní web

Image vlastního webu vzniká z `webapps/<web>/Dockerfile`, který zakládá `make new`. Staví se vždy
z kořene repozitáře a skládá se ze tří částí: **závislostní image** `<registr>/pwe-<profil>:<tag>`
(web bez databáze `pwe-base`; jen knihovny a ovladač databáze), **engine zkopírovaný z pracovní
kopie** (adresář `PWE/` do `/PWE/PWE`) a **web** (`/PWE/webapps/<web>`). Podrobnosti:
[`docs/17-nasazeni.md`](../docs/17-nasazeni.md).

1. Zkopíruj `values-example-static.yml` (web bez databáze) nebo `values-example-mariadb.yml` a
   `secrets-example-mariadb.example.yml` (web s databází MariaDB) pod vlastním názvem:
   `values-mujweb.yml`, `secrets-mujweb.example.yml`.
2. V bloku `generic` nastav `pweWeb` (adresář webu ve `webapps/`) a `pweImage` (název image webu,
   např. `mujweb` — **ne** `pwe-example-…` ani jiný [vyhrazený název](#image-a-tagy)). `pweProfile`
   nech podle vzoru (`static` v kopii `values-example-static.yml`, `mariadb` v kopii `values-example-mariadb.yml`):
   musí odpovídat Dockerfilu webu. Případně nastav `pweHost` — celou adresu webu, např.
   `www.mujweb.cz` (prázdné = `pwe-mujweb.<K8S_DOMAIN>`).
3. Nastav `K8S_REGISTRY` na registr, do kterého smíš nahrávat (viz [Soukromý registr](#soukromý-registr)),
   a přihlas k němu `docker`.
4. `make k8s-image K8S=mujweb && make k8s-deploy K8S=mujweb && make k8s-test K8S=mujweb`.

`make k8s-image` sestaví image `<K8S_REGISTRY>/<pweImage>:<K8S_IMAGE_TAG>` (výchozí tag `latest`)
pro platformu `K8S_PLATFORM` (výchozí `linux/amd64`) a nahraje ho:

- **Engine** v image je vždy ten z pracovní kopie (kontext sestavení je kořen repozitáře); jeho
  verzi říká soubor `/PWE/PWE/VERSION` v image.
- **Závislostní image** je `<PWE_IMAGE_REGISTRY>/pwe-<profil>:<PWE_IMAGE_TAG>`, u webu bez databáze
  (`pweProfile: static`) `<PWE_IMAGE_REGISTRY>/pwe-base:<PWE_IMAGE_TAG>`. Výchozí je `ghcr.io/kukam`
  a verze z `PWE/VERSION`, tedy knihovny, které k enginu v pracovní kopii patří. `PWE_IMAGE_TAG`
  vybírá jen závislosti, verzi enginu neurčuje.

Závislostní image musí existovat pro platformu clusteru:

- **Je v registru** (pipeline ho publikuje pro `linux/amd64` i `linux/arm64`) a v místním Dockeru
  pod tímto tagem není: nic dalšího není potřeba, `buildx` si stáhne správnou platformu.
- **Stroj má stejnou platformu jako uzly clusteru:** stačí místní image z `make images`.
- **Jiná platforma** (typicky Mac s Apple Silicon a cluster s uzly amd64) a závislostní image jen
  místní: sestav ho pro platformu clusteru pod vlastním tagem a ten předej při sestavení webu:

  ```bash
  docker build --platform linux/amd64 --target mariadb \
      -t ghcr.io/kukam/pwe-mariadb:2.2.1-amd64 -f PWE/docker/Dockerfile .
  PWE_IMAGE_TAG=2.2.1-amd64 make k8s-image K8S=mujweb
  ```

  (`--target` je stage závislostního image: `base` pro web bez databáze — image `pwe-base` —, jinak
  `mariadb`, `mysql` nebo `postgres`.) `make images` se na to nehodí: označuje vždy tagy `<verze>`
  a `latest`, takže by image pro platformu stroje, které používá vývojový stack a nástroje,
  nahradil. Postup je ověřený na stroji arm64 (sestavení závislostního image pro
  `linux/amd64` i image webu nad ním); nahrání do registru a nasazení v clusteru v tomto uspořádání
  ověřené není.

Když je závislostní image v místním Dockeru jen pro jinou platformu, `make k8s-image` skončí chybou
s tímto návodem (`mistni image … neni pro platformu …`). Jinak by sestavení podle verze Dockeru
skončilo nesrozumitelnou chybou (`no match for platform in manifest`), nebo by vznikl image webu
s binárkami jiné architektury a pody by v clusteru padaly na `exec format error`.

**Dockerfile z dřívější šablony** `make k8s-image` odmítne (`webapps/<web>/Dockerfile je z drivejsi
sablony (…)`). Pozná ho podle základu, který už neexistuje (image `pwe` jako zdroj enginu,
`pwe-static`), nebo podle mazání vzorového webu ze základního image. Závislostní image engine
neobsahují: sestavení by skončilo zavádějící chybou, a kde v místním Dockeru zůstal starý tag,
prošlo by a web by dostal starý engine. Nový Dockerfile získáš tak, že web vygeneruješ jinam a
převezmeš z výsledku jen `Dockerfile` (vlastní úpravy přenes ručně):

```bash
PWE/tools/new-webapp.pl mujweb.web --db mariadb --dir /tmp/mujweb-novy     # web bez databáze: bez --db
cp /tmp/mujweb-novy/Dockerfile webapps/mujweb.web/Dockerfile
make check WEB=mujweb.web                                                  # úplná kontrola Dockerfile proti šabloně
```

Vlastní weby mají vlastní git mimo tento repozitář. Values svého webu verzuj v jeho repozitáři
(např. `webapps/mujweb.web/kubernetes/values.yml`) a do `kubernetes/` dej symbolický odkaz
`values-mujweb.yml`; soubor s hesly (`secrets-mujweb.yml`) do gitu nepatří nikde.

Tajné hodnoty webu (hesla SMTP, klíče platební brány) nepatří do values souboru ani do image: dej je
do `secrets-<název>.yml` (blok `secrets`) a do kontejneru je předej přes `envsFromSecret`, soubory
(např. soukromý klíč brány) přes svazek typu `secret`.

### Soukromý registr

Image webu obsahuje engine a **celý adresář webu**: zdrojový kód (`Pages/`, `Services/`, `Entities/`,
`Sites/`) i `conf/web.conf` a `conf/<profil>.conf`. Vynechané jsou jen `conf/local.env`, soukromé
klíče a dočasná data (kořenový `.dockerignore`). Kdo image stáhne, má zdrojový kód webu — vlastní
web proto nahrávej do **soukromého** repozitáře (Docker Hub zakládá nový repozitář jako veřejný,
pokud ho předem nezaložíš jako soukromý).

Cluster pak potřebuje přihlašovací Secret v namespace a odkaz na něj ve values (totéž platí pro
vzorová nasazení, když image vzorových webů nejsou v registru veřejné):

```bash
kubectl --context <kontext> create namespace pwe     # pokud ještě neexistuje
kubectl --context <kontext> -n pwe-<název> create secret docker-registry regcred \
    --docker-server=<registr> --docker-username=<uživatel> --docker-password=<token>
```

```yaml
generic:
  extraImagePullSecrets:
    - name: regcred
```

Tato varianta v clusteru ověřená není.

### Jiná databáze než MariaDB

`values-example-mariadb.yml` nasazuje MariaDB (blok `statefulSets.mariadb`, proměnné `MARIADB_*`, port
3306). `pweProfile` určuje ovladač databáze: u vlastního webu závislostní image `pwe-<profil>`, nad
kterým se image webu staví, a soubor `conf/<profil>.conf`; u vzorového nasazení musí odpovídat
názvu image. Hotové hodnoty pro ostatní databáze jsou v `values-example-mysql.yml` (MySQL 8.4, proměnné
`MYSQL_*`) a `values-example-postgres.yml` (PostgreSQL 18, proměnné `POSTGRES_*`, port 5432, svazek
`/var/lib/postgresql`) — vlastní web s touto databází začni kopií příslušného souboru a jeho vzoru hesel.
Ručně pro PostgreSQL (`postgres`) nebo MySQL (`mysql`) je potřeba přepsat blok
`statefulSets` (image, proměnné, port, cestu svazku, sondy), `PWE_CONF_dbi_db1_host` a klíče
v `secrets-<název>.example.yml`. Se změnou `pweProfile` změň u vzorového nasazení i `pweImage` na
`pwe-example-<nový profil>` (např. `pwe-example-postgres`); u vlastního webu zůstává název image
webu. Image vzorového webu, který profilu neodpovídá, skript odmítne (`generic.pweImage '…' je image
vzoroveho webu s profilem …, ale generic.pweProfile je '…'`). Tyto varianty ověřené nejsou.

**Databáze mimo cluster:** smaž blok `statefulSets`, `PWE_CONF_dbi_db1_host` nastav na její adresu
(jiný port: přidej `PWE_CONF_dbi_db1_port`), `generic.pweDbName` a `pweDbUser` podle té databáze
a před prvním nasazením si sám založ `secrets-<název>.yml` s jejím heslem v `MARIADB_PASSWORD`
(jinak skript vygeneruje náhodné).

## Konfigurace enginu

Engine v podu čte `conf/web.conf` webu z image. Hodnoty pro cluster se přepisují proměnnými
`PWE_CONF_<sekce>_<klíč>` v `deployments.web.containers` (kontejner `fcgi`, pole `env`) — přepsat
lze jen klíč, který v konfiguraci webu existuje. Příklady už ve values souborech:

| Proměnná | Proč |
| --- | --- |
| `FCGI_SOCKET_PATH=127.0.0.1:7779` | engine poslouchá na FastCGI socketu (bez ní by obsloužil jeden požadavek a skončil), a to jen na loopbacku podu — z jiných podů port dostupný není. Vyžaduje engine 2.2.1 nebo novější; starší umí jen `:7779` (všechna rozhraní) |
| `PWE_CONF_pwe_development=0` | vypne vývojový režim; mimo jiné generátor kódu `pweCreator` pak odmítne zapisovat soubory (ve vzorových webech je každý návštěvník ve skupině `admin`) |
| `PWE_CONF_http_base_url` | adresa webu pro odkazy generované mimo požadavek |
| `PWE_CONF_log_logout=STDERR` | log enginu jde do logu kontejneru (`make k8s-logs`) |
| `PWE_CONF_dbi_db1_*` | připojení k databázi (jen nasazení s databází); heslo se bere ze Secretu |
| `PWE_CONF_dbi_db1_loglevel=0`, `PWE_CONF_dbi_db1_logfile=/dev/null` | vypne trasování DBI: s `loglevel` 1 by se každé SQL včetně vázaných hodnot (e-maily, hashe hesel) zapisovalo do souboru v kontejneru, bez rotace |
| `TZ` | časové pásmo pro start enginu; pro požadavky ho předává nginx podu (`fastcgi_param TZ`). Obojí z `generic.pweTimezone` (image běží v UTC) |

`PWE_CONF_pwe_home` a `PWE_PROFILE` se nenastavují: má je zapečené image webu (image vzorového webu
ukazuje na svůj vzorový web, image vlastního webu na svůj web). `PWE_CONF_pwe_core=/PWE/PWE` má už
základ `pwe-base`. Pracovní adresáře webu (`ramdisk/`, `sessions/`, `uploadfile/`, `log/`) a symlink
`conf/database.conf` zakládá Dockerfile webu při sestavení.

## Hesla

`secrets-example-mariadb.yml` obsahuje heslo správce databáze a heslo uživatele, pod kterým se připojuje
engine. MariaDB si obě hesla zapíše do svého svazku **při prvním startu**; pozdější změna v souboru
je v databázi sama nezmění.

- Soubor **není v gitu** — na jiný stroj (kolega, CI) ho musíš přenést sám.
- Dokud release běží, obnovíš ho z clusteru:
  `helm --kube-context <kontext> -n pwe-example-mariadb get values pwe-example-mariadb -o yaml` (klíč `secrets`).
- Když soubor chybí a release nebo jeho svazek databáze v clusteru už existuje, `make k8s-deploy`
  nová hesla **nevygeneruje** a skončí chybou s touto radou. Nová hesla vynutíš `K8S_NEW_SECRETS=1`
  — databáze ve svazku ale zůstane se starými.
- Nová hesla se založí jen tehdy, když release **prokazatelně neexistuje**: `helm status` ohlásí
  `release: not found` a dotaz `kubectl` na svazky releasu proběhne úspěšně a nic nenajde. Když
  stav zjistit nejde (nedostupný cluster, překlep v `KUBE_CONTEXT`, vypršené přihlášení, chybějící
  oprávnění nebo program `kubectl`), `make k8s-deploy` hesla nezaloží, nic nenasadí a skončí kódem 2
  s hláškou `stav releasu … v clusteru nelze zjistit (…)` nebo `svazky releasu … v clusteru nelze
  zjistit (…)` — soubor s hesly po takovém běhu nevznikne. Oprav připojení a spusť nasazení znovu;
  výjimka je opět `K8S_NEW_SECRETS=1` (stav clusteru se pak nezjišťuje vůbec).
- Zkouška nasucho (`--dry-run`, `--dry-run=client|server|true` v `ARGS` nebo v `K8S_HELM_ARGS`) hesla
  nezakládá a použije vzor; `--dry-run=none` a `--dry-run=false` jsou skutečné nasazení se
  skutečnými hesly.
- Po nechtěném nasazení s jinými hesly vrátí původní Secret
  `helm --kube-context <kontext> -n pwe-example-mariadb rollback pwe-example-mariadb`.
- `make k8s-delete` odmítne release odinstalovat, když na stroji soubor s hesly chybí — viz
  [Odinstalování](#odinstalování).
- Když soubor ztratíš i s releasem a svazek zůstane, změň heslo přímo v databázi, nebo svazek smaž
  a databázi nech založit znovu.
- Výstup `make k8s-template` a `helm get values` obsahuje hesla — nikam ho nevkládej.

## Škálování a data

- **Počet podů:** `deployments.web.replicas`. Každý pod obsluhuje jeden dynamický požadavek
  najednou.
- **Web bez databáze:** stav návštěvníka je v souborech podu (`pwe.save_opt_to = file`) a zaniká
  s podem. Ingress proto drží návštěvníka u jednoho podu (anotace `affinity: cookie`).
- **Nahrané soubory:** aby je viděly všechny pody a přežily jejich výměnu, nahraď ve
  `values-<název>.yml` svazek `uploadfile` typu `emptyDir` sdíleným svazkem (položky `nginx-conf`
  a `static` v seznamu `volumes` ponech — samostatný soubor přes `-f` by seznam nahradil celý):

  ```yaml
  deployments:
    web:
      volumes:
        - name: nginx-conf
          type: configMap
        - name: static
          type: emptyDir
        - name: uploadfile
          type: pvc              # PVC <release>-uploadfile
  pvcs:
    uploadfile:
      annotations:
        helm.sh/resource-policy: keep   # make k8s-delete svazek s nahranými soubory nesmaže
      accessModes: ["ReadWriteMany"]
      size: 5Gi
      storageClassName: <třída úložiště s podporou ReadWriteMany>
  ```

  Bez anotace `keep` smaže `make k8s-delete` svazek i s nahranými soubory. U webu s databází pak
  nejsou potřeba anotace `affinity` a `session-cookie-name` u ingressu. Tato varianta v clusteru
  ověřená není.
- **Databáze:** jeden pod MariaDB se svazkem 1 Gi z výchozí třídy úložiště
  (`statefulSets.mariadb.volumeClaimTemplates`). Je to minimum pro vzorový web, ne vysoká
  dostupnost; zálohy řeš zvlášť.

## Odinstalování

```bash
make k8s-delete K8S=example-mariadb
```

Odstraní release (pody, služby, ingress, ConfigMap, Secret s hesly). **Zůstává** svazek databáze
(`data-pwe-example-mariadb-mariadb-0`), svazky s anotací `keep` a Secret s certifikátem
(`pwe-example-mariadb-web-tls`) — nové nasazení na ně naváže; skript je po odinstalování vypíše. Úplné
smazání včetně dat:

```bash
kubectl --context <kontext> -n pwe-example-mariadb delete pvc data-pwe-example-mariadb-mariadb-0
kubectl --context <kontext> -n pwe-example-mariadb delete secret pwe-example-mariadb-web-tls
```

**Pojistka hesel:** hesla databáze jsou jen v `secrets-<název>.yml` a v releasu. Když soubor na
tomto stroji chybí, odinstalování by smazalo jejich poslední kopii, zatímco svazek databáze
zůstává — nové nasazení by se k němu nepřipojilo. `make k8s-delete` proto u nasazení s hesly (má
vzor `secrets-<název>.example.yml`) bez místního `secrets-<název>.yml` skončí kódem 2 a nic
neodinstaluje. Hesla nejdřív ulož (výstup obsahuje hesla — nikam ho nevkládej):

```bash
helm --kube-context <kontext> -n pwe-example-mariadb get values pwe-example-mariadb -o yaml     # klíč secrets
```

nebo soubor zkopíruj ze stroje, odkud se nasazovalo. Když data ani hesla nepotřebuješ, odinstaluj
release výslovně: `make k8s-delete K8S=example-mariadb K8S_DELETE_WITHOUT_SECRETS=1`. Zkouška nasucho
(`ARGS=--dry-run`) pojistku nepotřebuje — nic neodinstaluje.

`make k8s-delete` odinstaluje vždy jen release daného nasazení. V `ARGS` smí být jen přepínače helmu
(`ARGS='--timeout 5m'`); název dalšího releasu skript odmítne (`argument '…' by helm vzal jako dalsi
release`), protože by obešel pojistku hesel — další nasazení odinstaluj samostatným příkazem.

## Řešení potíží

| Projev | Příčina a řešení |
| --- | --- |
| `neni nastaven KUBE_CONTEXT` | skript záměrně nepoužívá aktuální kontext; doplň `KUBE_CONTEXT` do `kubernetes/local.env` |
| `make k8s-image`: `nasazeni … je vzorove … nic se nestavi` | není to chyba: vzorové nasazení bere hotový image vzorového webu z registru, pokračuj `make k8s-deploy` |
| `prepinac '…' neni povolen` | přepínač v `ARGS` nebo `K8S_HELM_ARGS` by změnil cluster, kontext, přihlášení nebo namespace — nastav `KUBE_CONTEXT`, resp. `K8S_NAMESPACE` (viz [Přehled cílů](#přehled-cílů)) |
| `[k8s] promenne HELM_KUBE… se nepouziji` | v prostředí nebo v `local.env` je proměnná, kterou by `helm` či `kubectl` vybraly cluster nebo namespace jinak; skript ji zrušil — není to chyba, ale proměnnou raději odstraň |
| `make k8s-deploy` vzorového nasazení: `digest image …/pwe-example-<profil>:<tag> nelze zjistit` | image vzorového webu s tímto tagem v registru není (verze z `PWE/VERSION` ještě nebyla publikována — zkus `K8S_IMAGE_TAG=latest`; `make images` staví jen do místního Dockeru), `docker` k registru nemá přístup (`docker login`), nebo `K8S_REGISTRY` v `local.env` míří na registr vlastního webu — pak `K8S_REGISTRY=ghcr.io/kukam make k8s-deploy …` a k němu `K8S_PULL_REGISTRY=<zrcadlo ghcr.io/kukam, nebo ghcr.io/kukam>`, pokud `local.env` nastavuje i `K8S_PULL_REGISTRY` (viz [Image a tagy](#image-a-tagy)); výjimka `K8S_ALLOW_TAG=1` |
| `make k8s-deploy` vlastního webu: `digest image … nelze zjistit` | image webu v registru není (`make k8s-image`), nebo chybí `docker` či `K8S_REGISTRY`; výjimka `K8S_ALLOW_TAG=1` |
| `digest image … nelze zjistit (docker nevypsal digest tvaru sha256:<64 hex>, ale: …)` | `docker buildx imagetools inspect` skončil úspěšně, ale nevypsal digest — jako digest se bere jen řádek přesného tvaru; digest lze předat i výslovně: `K8S_IMAGE_TAG=<tag>@sha256:<digest>` |
| `[k8s] image se overuje v registru …, cluster ho ale taha z … (K8S_PULL_REGISTRY)` | oznámení, ne chyba: `K8S_PULL_REGISTRY` se liší od `K8S_REGISTRY`. Je to v pořádku jen tehdy, když jde o zrcadlo (proxy cache) téhož registru — jinak změň i `K8S_PULL_REGISTRY` |
| `generic.pweImage 'pwe-example-…' je image vzoroveho webu …, ale generic.pweWeb je '…'` | ve values vlastního webu zůstal název image vzorového webu — nastav `generic.pweImage` na název image webu |
| `generic.pweImage 'pwe-example-…' je image vzoroveho webu s profilem …, ale generic.pweProfile je '…'` | změnil se jen `pweProfile` (typicky při změně databáze) — u vzorového nasazení změň i `pweImage` na `pwe-example-<profil>`, image vlastního webu pojmenuj jinak |
| `generic.pweImage '…' je vyhrazeny nazev image PWE (…)` | `pweImage` je závislostní image (`pwe-base`, `pwe-<profil>`, `pwe-debugger` — jen knihovny, nasadit ho nejde), název `pwe-example-*` mimo čtyři existující, nebo zrušený `pwe` či `pwe-static`. Values z dřívějšího uspořádání oprav: `pwe-static` → `pwe-example-static`, `pwe-mariadb` → `pwe-example-mariadb`; image vlastního webu pojmenuj jinak (viz [Image a tagy](#image-a-tagy)) |
| `generic.pweImage '…' neni nazev image` | `pweImage` je název image bez registru a tagu (malá písmena, číslice, `. _ - /`): registr patří do `K8S_REGISTRY`, tag do `K8S_IMAGE_TAG` |
| `generic.pweProfile '…' neni profil PWE` | `pweProfile` je `static` (web bez databáze), `mariadb`, `mysql` nebo `postgres` |
| `make k8s-image`: `webapps/<web>/Dockerfile je z drivejsi sablony (…)` | Dockerfile webu počítá se základním image, který obsahoval engine (zrušený `pwe` nebo `pwe-static`, mazání vzorového webu) — vygeneruj nový, viz [Vlastní web](#vlastní-web) |
| `make k8s-image`: `webapps/<web>/Dockerfile stavi nad zavislostnim image profilu (FROM .../pwe-${PWE_PROFILE}), ale generic.pweProfile … je static` | Dockerfile webu s databází se nasazuje s `pweProfile: static` — image `pwe-static` neexistuje. Nastav `pweProfile` na profil databáze (`mariadb`, `mysql`, `postgres`); u webu bez databáze je Dockerfile z dřívější šablony a vygeneruj nový, viz [Vlastní web](#vlastní-web) |
| `docker build` image webu skončí na `Zakladni image … neobsahuje engine` | Dockerfile webu je z dřívější šablony, která engine čekala v základním image (`make k8s-image` takový Dockerfile odmítne ještě před sestavením) — vygeneruj nový, viz [Vlastní web](#vlastní-web) |
| `make k8s-image`: `mistni image … neni pro platformu linux/amd64` | závislostní image máš místně jen pro jinou platformu — viz [Vlastní web](#vlastní-web) |
| `make k8s-image`: `pull access denied` / `not found` u image `pwe-<profil>` nebo `pwe-base` | závislostní image s tímto tagem není místně ani v registru — `make images`, případně `PWE_IMAGE_TAG` |
| `make k8s-deploy`: `secrets-<název>.yml chybi, ale release … uz existuje` | viz [Hesla](#hesla) |
| `make k8s-deploy`: `stav releasu pwe-<název> v clusteru nelze zjistit (…)` nebo `svazky releasu pwe-<název> v clusteru nelze zjistit (…)` | soubor s hesly chybí a skript nedokázal ověřit, že release ani jeho svazek neexistují (v závorce je chyba `helm`, resp. `kubectl`): nedostupný cluster, překlep v `KUBE_CONTEXT`, vypršené přihlášení, chybějící oprávnění nebo program `kubectl`. Hesla se nezaložila a nic se nenasadilo — oprav příčinu a spusť nasazení znovu; výjimka `K8S_NEW_SECRETS=1` (viz [Hesla](#hesla)) |
| `make k8s-delete`: `secrets-<název>.yml na tomto stroji chybi` | hesla databáze by po odinstalování zůstala jen ve svazku — nejdřív je ulož, nebo `K8S_DELETE_WITHOUT_SECRETS=1` (viz [Odinstalování](#odinstalování)) |
| pod ve stavu `ImagePullBackOff` | cluster image nestáhne: image není v registru, registr je soukromý (viz [Soukromý registr](#soukromý-registr)), nebo `K8S_PULL_REGISTRY` míří jinam než na zrcadlo registru `K8S_REGISTRY` (skript na rozdíl registrů při nasazení upozorňuje, viz [Image a tagy](#image-a-tagy)); `kubectl --context <kontext> -n pwe-<název> describe pod <pod>` |
| pod ve stavu `Init:CrashLoopBackOff` nebo `CrashLoopBackOff`, v logu `exec format error` | image je pro jinou platformu než uzly — u vlastního webu nastav `K8S_PLATFORM` a znovu `make k8s-image` |
| kontejner `fcgi` se restartuje, v logu `Couldn't chmod(127.0.0.1:7779)` | image obsahuje engine starší než 2.2.1, který adresu `host:port` neumí — nasaď novější image, nebo ve values změň `FCGI_SOCKET_PATH` na `":7779"` |
| v logu `fcgi` vzorového nasazení je `[entrypoint] VAROVANI: bezi vzorovy web … zapeceny v image … neni urcen pro verejny provoz` | není to chyba, ale upozornění: image vzorového webu je ukázka (každý návštěvník je v ní ve skupině `admin`). Do veřejného provozu nasaď vlastní web z vlastního image, viz [Vlastní web](#vlastní-web) |
| `make k8s-test`: chyba certifikátu | certifikát se ještě vystavuje (`make k8s-status`, sloupec `READY` u certifikátu); důvod případné chyby: `kubectl --context <kontext> -n pwe-<název> describe certificate pwe-<název>-web-tls` |
| při prvním nasazení je v logu `fcgi` několikrát `[E] … Connect to mariadb … error:2003 Can't connect` | databáze teprve startuje; engine zkouší připojení po 1 s, nejvýš 60×. Jakmile se připojí, pokračuje; když se do té doby nepřipojí, proces skončí (`Unable connect to db1`) a Kubernetes kontejner spustí znovu |
| v logu `fcgi` druhého podu je `Dbversion: migraci databaze dbid:db1 provadi jiny proces, cekam na zamek spojeni (… s)` | není to chyba: schéma právě zakládá (migruje) první pod a druhý čeká na zámek migrace; jakmile první skončí, pokračuje sám. První hláška je úrovně info (při `log.loglevel` 2 z values vidět není), po 30 s čekání se opakuje jako `[E]`. Když čekání nekončí a žádný pod nemigruje, podívej se do logu prvního podu (`make k8s-logs K8S=<název> ARGS='-c fcgi'`) |
| pod `fcgi` se restartuje, v logu `Connect to mariadb … connect_status:0 error:1045 Access denied` | heslo v `secrets-<název>.yml` nesouhlasí se svazkem databáze — viz [Hesla](#hesla) |
| událost `Startup probe failed: … Connection refused` krátce po startu | engine se ještě připojuje k databázi nebo provádí migrace — je to v pořádku, dokud pod do 10 minut naběhne |
| `make k8s-deploy` skončí na `context deadline exceeded` | pody se do limitu nepřipravily; `make k8s-status` a `make k8s-logs` ukážou proč (limit: `K8S_TIMEOUT`, výchozí `10m`) |
| web odpovídá `502` | kontejner `fcgi` neběží nebo neposlouchá na `127.0.0.1:7779` — `make k8s-logs K8S=<název> ARGS='-c fcgi'` |
