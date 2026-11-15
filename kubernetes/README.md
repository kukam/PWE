# Nasazení webu PWE do Kubernetes

Web nad PWE se do Kubernetes nasazuje jako **image webu** (engine i web v jednom image, staví se
z `webapps/<web>/Dockerfile`) obecným chartem
[nxs-universal-chart](https://github.com/nixys/nxs-universal-chart) —
`oci://registry.nixys.ru/nuc/nxs-universal-chart`, verze **3.2.2**. Chart nemá žádné šablony
specifické pro PWE: všechno, co se nasadí, popisuje soubor s hodnotami `values-<název>.yml`.
Sestavení image, nasazení i kontrolu dělají cíle `make k8s-*` (skript `PWE/tools/k8s.sh`).

V repozitáři jsou dvě hotová nasazení vzorových webů:

| Název | Web | Co se nasadí | Adresa |
| --- | --- | --- | --- |
| `static` | `webapps/example.web` (bez databáze) | web | `https://pwe-static.<doména>` |
| `generic` | `webapps/example-db.web` | web + MariaDB | `https://pwe-generic.<doména>` |

Ověřeno nasazením obou webů do clusteru s Kubernetes 1.32, ingress-nginx a cert-managerem
(certifikát Let's Encrypt přes DNS-01), s Helm 3.22. S Helm 4 a s jinými ingress controllery
nasazení ověřené není.

> **Zásada:** skript nikdy nepoužije „aktuální kontext“ `kubectl`. Cluster se vybírá jen proměnnou
> `KUBE_CONTEXT` a každý příkaz `helm` i `kubectl` ji dostane výslovně. I v tomto návodu má každý
> příkaz `kubectl` volbu `--context` — na stroji s více clustery tak nic neskončí jinde.

## Soubory v tomto adresáři

| Soubor | K čemu je |
| --- | --- |
| `values-static.yml` | hodnoty chartu pro web bez databáze |
| `values-generic.yml` | hodnoty chartu pro web s databází MariaDB |
| `secrets-generic.example.yml` | vzor souboru s hesly databáze |
| `local.env.example` | vzor místního nastavení (kontext, doména, registr) |
| `local.env` | tvoje místní nastavení — **není v gitu** (`.gitignore`) |
| `secrets-<název>.yml` | skutečná hesla — **nejsou v gitu**, založí se při prvním nasazení |

## Co se v clusteru vytvoří

```
Ingress pwe-<název>-web            HTTPS, certifikát vystaví cert-manager (Secret pwe-<název>-web-tls)
  └─ Service pwe-<název>-web       port 80
       └─ Deployment pwe-<název>-web   (výchozí 2 pody)
            ├─ initContainer static    z image webu zkopíruje statiku do sdíleného svazku
            ├─ kontejner nginx         port 80: statiku posílá sám, ostatní předá enginu
            └─ kontejner fcgi          engine PWE, FastCGI na portu 7779 (nginx se připojuje přes 127.0.0.1)
NetworkPolicy pwe-<název>-web      do podů webu zvenku jen port 80

jen generic:
StatefulSet pwe-generic-mariadb    MariaDB, 1 pod, svazek 1 Gi (PVC data-pwe-generic-mariadb-0)
Service pwe-generic-mariadb        port 3306, dostupná jen uvnitř clusteru
NetworkPolicy pwe-generic-mariadb  databáze přijímá spojení jen od podů webu
Secret pwe-generic-db              hesla databáze
```

- **Jeden pod = nginx + engine.** Proces enginu obsluhuje jeden požadavek najednou; souběžnost
  dávají pody (`deployments.web.replicas`). Statické soubory (`static/` a `assets/` webu,
  `assets/` enginu) posílá nginx přímo z kopie, kterou při startu podu připraví initContainer —
  stejné rozdělení jako ve vývojovém stacku (`docker-compose/docker-compose_nginx.conf`).
- **HTTPS končí na ingressu**, do podu jde HTTP. Nginx v podu předává enginu původní schéma
  (`HTTPS=on` podle hlavičky `X-Forwarded-Proto`) a skutečnou adresu klienta (`X-Forwarded-For`).
- **Web bez databáze** si stav návštěvníka ukládá do souborů v podu, proto ingress drží návštěvníka
  u stejného podu (cookie `pwe-pod`). **Web s databází** má stav v databázi; schéma si při prvním
  startu založí engine sám (migrace `conf/mariadb.dbversion`).
- **Nahrané soubory** (`uploadfile/`) jsou v obou příkladech jen v podu a zaniknou s ním. Pro
  skutečný web použij sdílený svazek — viz [Škálování a data](#škálování-a-data).
- **Sondy:** engine otevře FastCGI socket až po připojení k databázi a migracích schématu. Do té
  doby ho hlídá jen `startupProbe` (až 10 minut), takže ho liveness sonda nezabije uprostřed migrace.
  Před ukončením podu čekají oba kontejnery 5 s (`preStop`): ingress mezitím pod vyřadí
  a rozpracované požadavky doběhnou.
- **Síťová pravidla** (`networkPolicies`): do podů webu smí zvenku jen port 80 (nginx). Port enginu
  7779 je dostupný jen uvnitř podu — jinak by jiný pod mohl obejít ingress i nginx a podvrhnout
  enginu adresu klienta nebo HTTPS. Databáze přijímá spojení jen od podů webu téhož releasu.
  Pravidla uplatní jen síťový plugin, který `NetworkPolicy` podporuje (Calico, Cilium …), a globální
  pravidla pluginu mají přednost. **V ověřovacím clusteru se neuplatnila:** globální pravidlo Calico
  `default.allow-node-to-node` (order 50, `selector: all()`) tam povoluje veškerý provoz mezi pody
  dřív, než se pravidla namespace vyhodnotí. Ověření ve vlastním clusteru: z jiného podu zkus
  spojení na `<IP podu webu>:7779` — má být odmítnuto.
- Pody nemají token service accountu, kontejnery běží bez linuxových oprávnění (engine jako root
  bez capabilities, nginx jen s těmi, které potřebuje) a s profilem seccomp `RuntimeDefault`.

## Co je potřeba

Na tvém stroji:

- `docker` s `buildx` (sestavení a nahrání image) a přihlášení k registru (`docker login`),
- `helm` 3.8 nebo novější ([instalace](https://helm.sh/docs/intro/install/); chart je v registru
  OCI); ověřeno s Helm 3.22, s Helm 4 ne,
- `kubectl` s kontextem cílového clusteru, `make`, `curl`,
- **image enginu** `pwe` a `pwe-<profil>` pro platformu uzlů clusteru — v registru, nebo sestavené
  místně (viz [krok 2](#2-image-webu)). Platformu uzlů zjistíš příkazem
  `kubectl --context <kontext> get nodes -L kubernetes.io/arch`, platformy image enginu v registru
  `docker buildx imagetools inspect ghcr.io/kukam/pwe:<tag>`.

V clusteru (ověření v závorce):

- ingress controller třídy `nginx`, tj. ingress-nginx (`kubectl --context <kontext> get ingressclass`);
  s jiným controllerem změň `ingresses.web.ingressClassName` a anotace `nginx.ingress.kubernetes.io/*`
  nahraď jeho obdobami — bez afinity podle cookie nastav u webu bez databáze `deployments.web.replicas: 1`,
- cert-manager s `ClusterIssuer`em, který umí vystavit certifikát pro tvou doménu
  (`kubectl --context <kontext> get clusterissuer`),
- DNS záznam `pwe-<název>.<doména>` mířící na ingress (adresa je po nasazení ve sloupci `ADDRESS`
  výpisu `make k8s-status`),
- pro `generic` výchozí `StorageClass` (`kubectl --context <kontext> get storageclass`, jedna označená
  `(default)`; jinak doplň `storageClassName` do `statefulSets.mariadb.volumeClaimTemplates`),
- přístup k registru s image webu: veřejný repozitář (stačí pro vzorové weby), nebo soukromý
  repozitář a přihlašovací Secret — viz [Soukromý registr](#soukromý-registr).

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
| `K8S_NAMESPACE` | namespace (výchozí `pwe`; založí se při prvním nasazení) |
| `K8S_DOMAIN` | doména; nasazení `<název>` poběží na `https://pwe-<název>.<K8S_DOMAIN>` (jinou adresu určuje `generic.pweHost` ve values) |
| `K8S_ISSUER` | `ClusterIssuer` cert-manageru |
| `K8S_REGISTRY` | registr, do kterého se image webu nahrává, např. `docker.io/muj-ucet` |
| `K8S_PULL_REGISTRY` | registr, ze kterého image tahá cluster — jen když se liší (proxy cache) |
| `K8S_IMAGE_TAG` | tag image webu (výchozí = aktuální větev gitu převedená na platný tag). `PWE_IMAGE_TAG` ho neovlivňuje — vybírá jen image enginu |
| `K8S_PLATFORM` | platforma image webu (výchozí `linux/amd64`) |
| `K8S_HELM_ARGS` | další argumenty pro `helm`, např. `--set-string generic.pweNginxImage=…`; dělí se na mezerách, hodnoty s mezerou nejdou |
| `K8S_TIMEOUT` | jak dlouho `make k8s-deploy` čeká na připravené pody (výchozí `10m`) |
| `K8S_TAIL` | počet řádků logu na kontejner pro `make k8s-logs` (výchozí `100`) |
| `K8S_ALLOW_TAG=1` | výjimka: nasadit jen podle tagu, když digest image nejde zjistit |
| `K8S_NEW_SECRETS=1` | výjimka: vygenerovat nová hesla i pro release, který už existuje (viz [Hesla](#hesla)) |

V `local.env` se píše `KLÍČ=hodnota`, uvozovky kolem hodnoty a mezery se odstraní. Neprázdná
proměnná prostředí má přednost, takže každou hodnotu lze přepsat i na příkazové řádce:
`make k8s-deploy K8S=static KUBE_CONTEXT=jiny`.

### 2. Image webu

```bash
make k8s-image K8S=static        # <K8S_REGISTRY>/pwe-example-static:<větev>
```

Sestaví image webu pro `K8S_PLATFORM` a nahraje ho do `K8S_REGISTRY`. Image webu se staví nad
image enginu `pwe` a `pwe-<profil>` (viz [`docs/17-nasazeni.md`](../docs/17-nasazeni.md)) s tagem
podle `PWE_IMAGE_TAG` (výchozí = větev gitu) — ty musí existovat pro platformu clusteru:

- **Image enginu jsou v registru pro obě platformy** (publikuje je pipeline GitHub Actions): nic
  dalšího není potřeba, `buildx` si je stáhne.
- **Stroj má stejnou platformu jako uzly clusteru:** stačí místní image z `make images`.
- **Jiná platforma** (typicky Mac s Apple Silicon a cluster s uzly amd64) a image enginu jen
  místní: sestav je pro platformu clusteru pod samostatným tagem a ten předej při sestavení webu
  (takto je to ověřené):

  ```bash
  PWE_IMAGE_TAG=<větev>-amd64 make images ARGS='--platform linux/amd64 --load base pwe static mariadb'
  PWE_IMAGE_TAG=<větev>-amd64 make k8s-image K8S=static
  ```

  Tag image webu zůstává `<větev>` (řídí ho `K8S_IMAGE_TAG`, ne `PWE_IMAGE_TAG`). Místní image
  pro obě platformy pod jedním tagem
  (`make images ARGS='--platform linux/amd64,linux/arm64 --load …'`) vyžaduje Docker s úložištěm
  image containerd; tahle varianta ověřená není.

Když je image enginu v místním Dockeru jen pro jinou platformu, `make k8s-image` skončí chybou
(jinak by vznikl image webu s binárkami jiné architektury a pody by v clusteru padaly na
`exec format error`).

### 3. Nasazení

```bash
make k8s-deploy K8S=static       # helm upgrade --install, čeká na připravené pody
make k8s-status K8S=static       # pody, služba, ingress, svazky, certifikát
make k8s-test   K8S=static       # ověří web přes HTTPS včetně platnosti certifikátu
```

Certifikát vystavuje cert-manager až po nasazení; s ověřením přes DNS to trvá obvykle 1–3 minuty.
Do té doby ingress odpovídá výchozím certifikátem a `make k8s-test` hlásí chybu certifikátu.

Pro web s databází je postup stejný s `K8S=generic`. Při prvním nasazení skript založí
`kubernetes/secrets-generic.yml` s náhodnými hesly — **soubor si uschovej** (viz [Hesla](#hesla)).

### Přehled cílů

| Příkaz | Co udělá |
| --- | --- |
| `make k8s-image K8S=<název>` | sestaví image webu a nahraje ho do registru |
| `make k8s-template K8S=<název>` | vypíše manifesty, které by se nasadily; ke clusteru se nepřipojuje (výpis obsahuje hesla — nikam ho nevkládej) |
| `make k8s-deploy K8S=<název>` | nasadí nebo aktualizuje release `pwe-<název>` |
| `make k8s-deploy K8S=<název> ARGS=--dry-run=server` | zkouška nasucho: cluster manifesty jen zkontroluje, hesla se nezakládají |
| `make k8s-status K8S=<název>` | stav releasu |
| `make k8s-test K8S=<název>` | ověří web přes HTTPS: úvodní stránku, statiku enginu (Bootstrap), statiku webu (`static/css/site.css`, má-li ji web) a `/healthz` |
| `make k8s-logs K8S=<název>` | posledních `K8S_TAIL` řádků logu všech kontejnerů; `ARGS=-f` průběžně, `ARGS='-c fcgi'` jen engine |
| `make k8s-delete K8S=<název>` | odinstaluje release (svazek databáze a certifikát zůstávají) |

Argumenty, které by změnily cluster nebo kontext (`--kube-context`, `--kubeconfig`, `--context`,
`--server` …), skript odmítne — i v `K8S_HELM_ARGS`.

## Image a aktualizace webu

- Název image určuje `generic.pweImage` ve `values-<název>.yml`, registr `K8S_REGISTRY`, tag
  `K8S_IMAGE_TAG`.
- **Nasazuje se podle digestu.** `make k8s-deploy` si v registru zjistí digest tagu a pody dostanou
  odkaz `<image>:<tag>@sha256:…`. Nový image nahraný pod stejným tagem tedy při dalším
  `make k8s-deploy` vyvolá výměnu podů a v clusteru běží přesně to, co je v registru.
  Zjištění digestu potřebuje na stroji, ze kterého se nasazuje, `docker` a `K8S_REGISTRY`. Když
  digest zjistit nejde (image v registru není, registr je nedostupný), nasazení skončí chybou;
  s `K8S_ALLOW_TAG=1` nasadí jen podle tagu — nový image pod stejným tagem pak pody nevymění.
- Aktualizace webu = `make k8s-image K8S=<název> && make k8s-deploy K8S=<název>`.
- Pro produkci použij neměnný tag, např. `K8S_IMAGE_TAG=1.4.0`, ne název větve.
- Návrat k předchozí verzi: `helm --kube-context <kontext> -n pwe rollback pwe-<název>`.

## Nasazení bez make

`make k8s-deploy` jen skládá příkaz `helm`. Totéž ručně (s digestem z
`docker buildx imagetools inspect docker.io/muj-ucet/pwe-example-static:master`; bez něj se
nasazuje jen podle tagu):

```bash
helm upgrade --install pwe-static oci://registry.nixys.ru/nuc/nxs-universal-chart --version 3.2.2 \
    --kube-context <kontext> --namespace pwe --create-namespace --wait --timeout 10m \
    -f kubernetes/values-static.yml \
    --set-string generic.pweRegistry=docker.io/muj-ucet \
    --set-string generic.pweImageTag=master@sha256:<digest> \
    --set-string generic.pweDomain=example.com \
    --set-string generic.pweIssuer=letsencrypt
```

Pro `generic` přidej `-f kubernetes/secrets-generic.yml`.

## Vlastní web

1. Zkopíruj `values-static.yml` (web bez databáze) nebo `values-generic.yml` a
   `secrets-generic.example.yml` (web s databází MariaDB) pod vlastním názvem:
   `values-mujweb.yml`, `secrets-mujweb.example.yml`.
2. V bloku `generic` nastav `pweWeb` (adresář webu ve `webapps/`), `pweImage` (název image webu),
   `pweProfile` (`static` v kopii `values-static.yml`, `mariadb` v kopii `values-generic.yml`)
   a případně `pweHost` — celou adresu webu, např. `www.mujweb.cz` (prázdné = `pwe-mujweb.<K8S_DOMAIN>`).
3. `make k8s-image K8S=mujweb && make k8s-deploy K8S=mujweb && make k8s-test K8S=mujweb`.

Vlastní weby mají vlastní git mimo tento repozitář. Values svého webu verzuj v jeho repozitáři
(např. `webapps/mujweb.web/kubernetes/values.yml`) a do `kubernetes/` dej symbolický odkaz
`values-mujweb.yml`; soubor s hesly (`secrets-mujweb.yml`) do gitu nepatří nikde.

Tajné hodnoty webu (hesla SMTP, klíče platební brány) nepatří do values souboru ani do image: dej je
do `secrets-<název>.yml` (blok `secrets`) a do kontejneru je předej přes `envsFromSecret`, soubory
(např. soukromý klíč brány) přes svazek typu `secret`.

### Soukromý registr

Image webu obsahuje **celý adresář webu**: zdrojový kód (`Pages/`, `Services/`, `Entities/`,
`Sites/`) i `conf/web.conf` a `conf/<profil>.conf`. Vynechané jsou jen `conf/local.env`, soukromé
klíče a dočasná data (kořenový `.dockerignore`). Kdo image stáhne, má zdrojový kód webu — vlastní
web proto nahrávej do **soukromého** repozitáře (Docker Hub zakládá nový repozitář jako veřejný,
pokud ho předem nezaložíš jako soukromý).

Cluster pak potřebuje přihlašovací Secret v namespace a odkaz na něj ve values:

```bash
kubectl --context <kontext> create namespace pwe     # pokud ještě neexistuje
kubectl --context <kontext> -n pwe create secret docker-registry regcred \
    --docker-server=<registr> --docker-username=<uživatel> --docker-password=<token>
```

```yaml
generic:
  extraImagePullSecrets:
    - name: regcred
```

Tato varianta v clusteru ověřená není.

### Jiná databáze než MariaDB

`values-generic.yml` nasazuje MariaDB (blok `statefulSets.mariadb`, proměnné `MARIADB_*`, port
3306). `pweProfile` vybírá jen ovladač databáze v image webu (`pwe-<profil>`) a soubor
`conf/<profil>.conf`. Pro PostgreSQL (`postgres`) nebo MySQL (`mysql`) je potřeba přepsat blok
`statefulSets` (image, proměnné, port, cestu svazku, sondy), `PWE_CONF_dbi_db1_host` a klíče
v `secrets-<název>.example.yml`. Tyto varianty ověřené nejsou.

**Databáze mimo cluster:** smaž blok `statefulSets`, `PWE_CONF_dbi_db1_host` nastav na její adresu
(jiný port: přidej `PWE_CONF_dbi_db1_port`), `generic.pweDbName` a `pweDbUser` podle té databáze
a před prvním nasazením si sám založ `secrets-<název>.yml` s jejím heslem v `MARIADB_PASSWORD`
(jinak skript vygeneruje náhodné).

## Konfigurace enginu

Engine v podu čte `conf/web.conf` z image webu. Hodnoty pro cluster se přepisují proměnnými
`PWE_CONF_<sekce>_<klíč>` v `deployments.web.containers` (kontejner `fcgi`, pole `env`) — přepsat
lze jen klíč, který v konfiguraci webu existuje. Příklady už ve values souborech:

| Proměnná | Proč |
| --- | --- |
| `FCGI_SOCKET_PATH=:7779` | engine poslouchá na FastCGI socketu (bez ní by obsloužil jeden požadavek a skončil) |
| `PWE_CONF_pwe_development=0` | vypne vývojový režim; mimo jiné generátor kódu `pweCreator` pak odmítne zapisovat soubory (ve vzorových webech je každý návštěvník ve skupině `admin`) |
| `PWE_CONF_http_base_url` | adresa webu pro odkazy generované mimo požadavek |
| `PWE_CONF_log_logout=STDERR` | log enginu jde do logu kontejneru (`make k8s-logs`) |
| `PWE_CONF_dbi_db1_*` | připojení k databázi (jen `generic`); heslo se bere ze Secretu |
| `PWE_CONF_dbi_db1_loglevel=0`, `PWE_CONF_dbi_db1_logfile=/dev/null` | vypne trasování DBI: s `loglevel` 1 by se každé SQL včetně vázaných hodnot (e-maily, hashe hesel) zapisovalo do souboru v kontejneru, bez rotace |
| `TZ` | časové pásmo pro start enginu; pro požadavky ho předává nginx podu (`fastcgi_param TZ`). Obojí z `generic.pweTimezone` (image běží v UTC) |

## Hesla

`secrets-generic.yml` obsahuje heslo správce databáze a heslo uživatele, pod kterým se připojuje
engine. MariaDB si obě hesla zapíše do svého svazku **při prvním startu**; pozdější změna v souboru
je v databázi sama nezmění.

- Soubor **není v gitu** — na jiný stroj (kolega, CI) ho musíš přenést sám.
- Dokud release běží, obnovíš ho z clusteru:
  `helm --kube-context <kontext> -n pwe get values pwe-generic -o yaml` (klíč `secrets`).
- Když soubor chybí a release nebo jeho svazek databáze v clusteru už existuje, `make k8s-deploy`
  nová hesla **nevygeneruje** a skončí chybou s touto radou. Nová hesla vynutíš `K8S_NEW_SECRETS=1`
  — databáze ve svazku ale zůstane se starými.
- Po nechtěném nasazení s jinými hesly vrátí původní Secret
  `helm --kube-context <kontext> -n pwe rollback pwe-generic`.
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
make k8s-delete K8S=generic
```

Odstraní release (pody, služby, ingress, ConfigMap, Secret s hesly). **Zůstává** svazek databáze
(`data-pwe-generic-mariadb-0`), svazky s anotací `keep` a Secret s certifikátem
(`pwe-generic-web-tls`) — nové nasazení na ně naváže; skript je po odinstalování vypíše. Úplné
smazání včetně dat:

```bash
kubectl --context <kontext> -n pwe delete pvc data-pwe-generic-mariadb-0
kubectl --context <kontext> -n pwe delete secret pwe-generic-web-tls
```

## Řešení potíží

| Projev | Příčina a řešení |
| --- | --- |
| `neni nastaven KUBE_CONTEXT` | skript záměrně nepoužívá aktuální kontext; doplň `KUBE_CONTEXT` do `kubernetes/local.env` |
| `make k8s-image`: `mistni image … neni pro platformu linux/amd64` | image enginu máš místně jen pro jinou platformu — viz [krok 2](#2-image-webu) |
| `make k8s-image`: `pull access denied` / `not found` u image `pwe` nebo `pwe-<profil>` | image enginu s tímto tagem nejsou místně ani v registru — `make images`, případně `PWE_IMAGE_TAG` |
| `make k8s-deploy`: `digest image … nelze zjistit` | image webu v registru není (`make k8s-image`), nebo chybí `docker` či `K8S_REGISTRY`; výjimka `K8S_ALLOW_TAG=1` |
| `make k8s-deploy`: `secrets-<název>.yml chybi, ale release … uz existuje` | viz [Hesla](#hesla) |
| pod ve stavu `ImagePullBackOff` | cluster image nestáhne: image není v registru, registr je soukromý (viz [Soukromý registr](#soukromý-registr)), nebo `K8S_PULL_REGISTRY` míří jinam; `kubectl --context <kontext> -n pwe describe pod <pod>` |
| pod ve stavu `Init:CrashLoopBackOff` nebo `CrashLoopBackOff`, v logu `exec format error` | image webu je pro jinou platformu než uzly — nastav `K8S_PLATFORM` a znovu `make k8s-image` |
| `make k8s-test`: chyba certifikátu | certifikát se ještě vystavuje (`make k8s-status`, sloupec `READY` u certifikátu); důvod případné chyby: `kubectl --context <kontext> -n pwe describe certificate pwe-<název>-web-tls` |
| při prvním nasazení je v logu `fcgi` několikrát `[E] … Connect to mariadb … error:2003 Can't connect` | databáze teprve startuje; engine zkouší připojení po 1 s, nejvýš 60×. Jakmile se připojí, pokračuje; když se do té doby nepřipojí, proces skončí (`Unable connect to db1`) a Kubernetes kontejner spustí znovu. Druhý pod mezitím hlásí `Dbversion is locked` (schéma právě zakládá první pod) |
| pod `fcgi` se restartuje, v logu `Connect to mariadb … connect_status:0 error:1045 Access denied` | heslo v `secrets-<název>.yml` nesouhlasí se svazkem databáze — viz [Hesla](#hesla) |
| událost `Startup probe failed: … Connection refused` krátce po startu | engine se ještě připojuje k databázi nebo provádí migrace — je to v pořádku, dokud pod do 10 minut naběhne |
| `make k8s-deploy` skončí na `context deadline exceeded` | pody se do limitu nepřipravily; `make k8s-status` a `make k8s-logs` ukážou proč (limit: `K8S_TIMEOUT`, výchozí `10m`) |
| web odpovídá `502` | kontejner `fcgi` neběží nebo neposlouchá na 7779 — `make k8s-logs K8S=<název> ARGS='-c fcgi'` |
