# 17 — Nasazení

PWE běží jako FastCGI proces v kontejneru; před ním stojí webserver, který předává requesty
a servíruje statiku. Tato kapitola popisuje image (co obsahují, jak se staví a publikují
a jak z nich vzniká image webu), vývojový compose stack, nginx, Apache, proměnné prostředí,
Kubernetes a produkční checklist.

Cesty: `PWE/…` znamená adresář enginu `PWE/` v kořeni repozitáře (na hostiteli, relativně ke kořeni
repozitáře). V image a v kontejnerech leží repozitář v `/PWE`, engine je tam proto v **`/PWE/PWE`**
a weby ve `/PWE/webapps/<web>`.

## Image

Engine se dodává jako **sedm image**. Všechny vycházejí z `pwe-base`, staví se z jednoho
vícestupňového `PWE/docker/Dockerfile` (jeden stage = jeden image) podle `docker-bake.hcl`
v kořeni repozitáře a publikuje je pipeline GitHub Actions do registru **`ghcr.io/kukam`**
(GitHub Container Registry).

| Image | Vychází z | Obsah | K čemu | Tagy |
| --- | --- | --- | --- | --- |
| `pwe-base` | `ubuntu:26.04` | jen běhové knihovny enginu a `entrypoint.sh`; **bez kódu enginu**, bez DB ovladačů, bez ladicích a build nástrojů | společný základ všech ostatních image | větev |
| `pwe` | `pwe-base` | + kód enginu v `/PWE/PWE` a `/PWE/LICENSE` — „nosič“ enginu | zdroj enginu pro image webu (`COPY --from`) | větev **a verze** |
| `pwe-static` | `pwe-base` | beze změny | běh webu bez databáze | větev |
| `pwe-mariadb` | `pwe-base` | + `DBD::mysql`, `DBD::MariaDB` | běh webu s MariaDB | větev |
| `pwe-mysql` | `pwe-base` | + `DBD::mysql` | běh webu s MySQL | větev |
| `pwe-postgres` | `pwe-base` | + `DBD::Pg` | běh webu s PostgreSQL | větev |
| `pwe-debugger` | `pwe-base` | + všechny tři DB ovladače + ladicí nástroje | služba `debugger` (VS Code) a výchozí image nástrojů (`make test`, `compile`, `check`, `cgi`, …) | větev |

```text
ubuntu:26.04
└── pwe-base            běhové knihovny enginu + entrypoint.sh (žádný kód enginu)
    ├── pwe             + kód enginu v /PWE/PWE                  tagy: <větev> a <verze>
    ├── pwe-static      beze změny                               web bez databáze
    ├── pwe-mariadb     + DBD::mysql, DBD::MariaDB
    ├── pwe-mysql       + DBD::mysql
    ├── pwe-postgres    + DBD::Pg
    └── pwe-debugger    + všechny DB ovladače + ladicí nástroje

image webu = pwe-<profil>:<větev>  +  engine zkopírovaný z pwe:<větev nebo verze>  +  webapps/<web>
```

Kde je kód enginu:

- **Jen v image `pwe`.** V `/PWE/PWE` má `pwe.fcgi`, `debug.cgi`, `VERSION`, `favicon.ico`, `README.md`,
  `CHANGELOG.md`, `Libs/`, `Pages/`, `Sites/`, `Services/`, `Entities/`, `templates/`, `assets/`, `tools/`
  a vedle toho `/PWE/LICENSE`. Testy (`PWE/t`) a `PWE/docker` v něm nejsou.
- **Profilové image a `pwe-debugger` engine neobsahují.** Ve vývojovém stacku se do nich mountuje
  repozitář (`/PWE`), takže běží pracovní kopie enginu; image vlastního webu si engine zkopíruje
  z image `pwe` ([Image vlastního webu](#image-vlastního-webu)).

`pwe-debugger` má navíc `Perl::LanguageServer` z balíčku Ubuntu `libperl-languageserver-perl` (dnes
verze 2.6.2; sestavení hlídá, že neklesne pod 2.6.2 — verzi rozšíření VS Code,
[16 — Nástroje](16-nastroje.md#debugger-ve-vs-code)) včetně jeho závislostí (`IO::AIO`, `Coro`,
`AnyEvent`, …), `perlcritic` (`Perl::Critic`), `perltidy` (`Perl::Tidy`), `perldoc` (`perl-doc`),
`cpanm` s překladačem (`build-essential`) pro doinstalování modulů z CPAN při ladění, klienty
`mariadb`/`mysql` a `psql`, `curl`, `ping`, `netstat`/`ifconfig`, `telnet`, `ps`/`pkill`, `less`
a FastCGI klienta `cgi-fcgi`. `curl` je jen tady — v běhových image není. `cpanm` stahuje index
i archivy z CPAN jen přes HTTPS (`ENV PERL_CPANM_OPT="--from https://www.cpan.org/"`; `cpanm`
z Ubuntu by jinak stahoval nešifrovaně z `http://www.cpan.org`). Do produkce nepatří.

Všech sedm image se staví **jen z balíčků Ubuntu** (`apt`): `cpanm` se při sestavení nespouští, takže
sestavení nezávisí na dostupnosti CPAN a projde i v emulaci jiné platformy (`linux/arm64` v pipeline).

### Co je v `pwe-base`

Základ obsahuje **jen to, co engine potřebuje k běhu**, databázi časových pásem a několik malých
knihoven, které používají weby nad enginem. Vše je z balíčků Ubuntu 26.04 (`apt`, bez doporučených
balíčků; Perl 5.40):

| Oblast | Balíčky |
| --- | --- |
| jádro enginu | `perl` (celý základní Perl včetně `prove` a `podchecker`), `libcgi-pm-perl`, `libcgi-fast-perl`, `libtemplate-perl`, `libclass-inspector-perl`, `libmoose-perl` (`Class::MOP` pro `pweCreator`), `libjson-perl`, `libjson-xs-perl`, `libdbi-perl` |
| e-maily, SMTP a HTTPS | `libmail-rfc822-address-perl`, `cstocs` (i modul `Cz::Cstocs`), `liblwp-mediatypes-perl` (typy příloh; samostatný balíček, `libwww-perl` v image není), `libio-socket-ssl-perl`, `libnet-ssleay-perl`, `libauthen-sasl-perl` (SMTP AUTH `PLAIN`/`LOGIN`), `ca-certificates` |
| programy volané pevnou cestou | `ruby-sass` (stránka `css`: `/usr/bin/sass`), `imagemagick` (`Libs::Pics`: `/usr/bin/identify`, `/usr/bin/convert`) |
| časová pásma | `tzdata` (`/usr/share/zoneinfo`; bez něj nemá proměnná `TZ` žádný účinek) |
| knihovny pro kód webu | `libimage-magick-perl`, `libcrypt-openssl-rsa-perl`, `openssl` (podpisy RSA platební brány), `liburi-perl`, `libhtml-parser-perl` |

Nastavení image: `ENV PWE_CONF_pwe_core=/PWE/PWE`, `WORKDIR /PWE/webapps`,
`ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`, `CMD ["perl", "/PWE/PWE/pwe.fcgi"]`, proces běží jako `root`.
Všechny odvozené image to dědí — profilové image, `pwe-debugger` i image webu.

#### Časové pásmo

Image běží v **UTC**. **Proměnná `TZ` kontejneru nestačí:** platí jen při startu enginu. FastCGI při
každém požadavku nahradí prostředí enginu parametry, které pošle webserver, takže během požadavku
(časy v logu, objednávky, e-maily, `localtime`) `TZ` chybí a engine počítá v UTC. Pásmo nastav jedním
z těchto způsobů (`tzdata` je ve všech image):

- **webserver předá `TZ` jako parametr FastCGI** — nginx: `fastcgi_param TZ Europe/Prague;`
  (tak to dělají vzorová nasazení v Kubernetes, hodnota z `generic.pweTimezone`,
  viz [`kubernetes/README.md`](../kubernetes/README.md#konfigurace-enginu));
- **soubor `/etc/localtime` kontejneru** — mount `/etc/localtime:/etc/localtime:ro` z hostitele (tak to
  dělá vývojový stack), nebo v `Dockerfile` webu
  `RUN ln -sf /usr/share/zoneinfo/Europe/Prague /etc/localtime`.

Proměnnou `TZ` kontejneru je dobré nastavit navíc, aby i řádky logu ze startu enginu měly stejné pásmo.

**Kontroly při sestavení.** Každý stage si svůj obsah ověří sám — chybějící balíček tak shodí už
sestavení, ne až provoz:

| Stage | Co sestavení ověří |
| --- | --- |
| `base` | existují `/usr/bin/sass`, `/usr/bin/identify` a `/usr/bin/convert` (engine je volá pevnou cestou; v ImageMagick 7 jsou `identify` a `convert` jen alternativy k `magick`), `/usr/bin/openssl` a `/usr/share/zoneinfo/Europe/Prague` (databáze časových pásem) a jdou načíst `CGI::Fast`, `Template`, `Class::Inspector`, `Class::MOP`, `JSON`, `JSON::XS`, `DBI`, `Mail::RFC822::Address`, `Cz::Cstocs`, `LWP::MediaTypes`, `IO::Socket::SSL`, `Authen::SASL`, `Image::Magick`, `Crypt::OpenSSL::RSA`, `URI` a `HTML::Parser` |
| `pwe` | předaná verze (`PWE_VERSION`) se shoduje s `PWE/VERSION` zkopírovaným do image — tag verze nesmí ukazovat na jiný kód |
| `mariadb`, `mysql`, `postgres` | jde načíst ovladač profilu (`DBD::mysql` + `DBD::MariaDB`, `DBD::mysql`, `DBD::Pg`) |
| `debugger` | `Perl::LanguageServer` má aspoň verzi z argumentu `PERL_LANGUAGESERVER_MIN` (výchozí 2.6.2), jdou načíst `Perl::LanguageServer::DebuggerBridge`, všechny tři DB ovladače, `Perl::Critic` a `Perl::Tidy` a existuje `/usr/bin/curl` |

**Popisky image** (`org.opencontainers.image.*`; výpis: `docker image inspect --format '{{json .Config.Labels}}' <image>`):

| Popisek | Hodnota | Které image |
| --- | --- | --- |
| `title` | název image (`pwe-base`, `pwe`, `pwe-mariadb`, …) | všechny |
| `description` | jednořádkový popis | všechny |
| `source` | adresa repozitáře (výchozí `https://github.com/kukam/PWE`; podle ní GitHub přiřadí balíček k repozitáři — u víceplatformního image z anotace indexu se stejnou hodnotou, viz [Pipeline](#pipeline-github-actions)) | všechny |
| `licenses` | `Apache-2.0` | všechny |
| `base.name` | `ubuntu:26.04` | všechny |
| `version` | obsah `PWE/VERSION` | jen `pwe` (jinde prázdný) |
| `created` | čas sestavení (RFC 3339) | jen `pwe` (jinde prázdný) |
| `revision` | commit, ze kterého engine v image pochází | jen `pwe`, a jen když je commit znám: pipeline ho vyplňuje vždy, `make images` jen z čisté pracovní kopie |

Popisky `version` a `created` zděděné z image Ubuntu se vyprazdňují, aby o image PWE netvrdily
nepravdu. Čas sestavení a commit má záměrně **jen `pwe`**: ostatní image kód enginu neobsahují,
takže se s každým commitem nemění — změní se až se změnou `PWE/docker/Dockerfile` nebo
`PWE/docker/entrypoint.sh` (a při sestavení bez mezipaměti).

**Vstupní skript** `entrypoint.sh` má jediný zdroj, `PWE/docker/entrypoint.sh`: stage `base` ho
instaluje do `/usr/local/bin/entrypoint.sh` a všechny odvozené image ho dědí, **včetně image webu** —
`Dockerfile` webu `ENTRYPOINT` nenastavuje a web žádnou vlastní kopii skriptu nemá. Pracuje
v aktuálním adresáři a jen tehdy, když v něm je `conf/web.conf`, tedy v adresáři webu:

1. je-li `PWE_PROFILE` `mariadb`, `mysql` nebo `postgres` a existuje `conf/$PWE_PROFILE.conf`,
   nasměruje symlink `conf/database.conf` → `$PWE_PROFILE.conf`. Symlink, který už na správný profil
   ukazuje, nechá být; jiný nahradí **atomicky** (nový symlink pod dočasným jménem + přejmenování),
   takže ostatní repliky nad stejným adresářem nikdy nevidí stav bez konfigurace. Běžný soubor
   `conf/database.conf` (vlastní konfigurace webu) nepřepíše. S `PWE_PROFILE=static`, s neznámou
   hodnotou nebo bez profilu se `conf/database.conf` **nemění** — existující symlink zůstane, jak je;
2. založí `ramdisk/templates`, `sessions`, `uploadfile` a `log`;
3. spustí předaný příkaz (`exec "$@"`; jeho návratový kód se zachová).

Chyby zápisu v krocích 1 a 2 ignoruje — web namountovaný jen pro čtení start neshodí, chybějící
adresář ohlásí až engine. Mimo adresář webu (`docker run … pwe-base perl -v`) jen spustí příkaz.

Start se **nikdy nepřeruší**. Když ale `PWE_PROFILE` neodpovídá stavu webu, vypíše skript na
standardní chybový výstup jednořádkové varování (`<stav>` je `conf/database.conf ukazuje na <cíl>`,
`conf/database.conf je bezny soubor` nebo `conf/database.conf neexistuje`):

| Situace | Varování |
| --- | --- |
| neznámá hodnota (překlep, velká písmena) | `[entrypoint] VAROVANI: neznamy PWE_PROFILE='<hodnota>' (platne hodnoty: static, mariadb, mysql, postgres) - conf/database.conf se nenastavuje (<stav>)` |
| databázový profil, ale web nemá `conf/<profil>.conf` (typicky web bez databáze spuštěný s profilem `mariadb`) | `[entrypoint] VAROVANI: PWE_PROFILE=<profil>, ale conf/<profil>.conf neexistuje - conf/database.conf se nenastavuje (<stav>)` |
| symlink se nepodařilo nastavit a na profil neukazuje (`conf/` jen pro čtení) | `[entrypoint] VAROVANI: conf/database.conf se nepodarilo nasmerovat na <profil>.conf (PWE_PROFILE=<profil>; neni adresar conf/ jen pro cteni?) - <stav>` |
| profil `static`, ale v `conf/` zůstal symlink `database.conf` | `[entrypoint] VAROVANI: PWE_PROFILE=static, ale conf/database.conf ukazuje na <cíl> - symlink zustava a engine nacte databazovou konfiguraci jineho profilu` |

Bez varování proběhne start s prázdným nebo chybějícím `PWE_PROFILE`, s běžným souborem
`conf/database.conf` (ten se nikdy nepřepisuje), se symlinkem, který už na profil ukazuje, a mimo
adresář webu.

**V `pwe-base` není:** kód enginu, DB ovladače (`DBD::*` — jsou v profilových image), ladicí a build
nástroje včetně `curl` (jsou v `pwe-debugger`), `node-less` (engine `lessc` nepoužívá), `IO::AIO`
(potřebuje ho jen `Perl::LanguageServer`) a knihovny, které engine ani weby v repozitáři nepoužívají:
`libwww-perl` (`LWP::UserAgent`), `liblwp-protocol-https-perl`, `libdata-uuid-perl`,
`libdata-guid-perl` a `libcrypt-openssl-x509-perl` (v základu byly do 15. 11. 2026). Web, který je
potřebuje, si je přidá ve svém `Dockerfile` ([Přidání knihovny](#přidání-knihovny)).

Na hostitele se závislosti enginu neinstalují vůbec: hostitelským Perlem (libovolný Perl 5, stačí
jádro) se jen spouštějí skripty `PWE/tools/*.pl`, které si zbytek odbaví v kontejneru.

### Moduly dostupné kódu webu

V každém image (tedy už v `pwe-base`), kromě modulů z jádra Perlu 5.40:

| Oblast | Moduly |
| --- | --- |
| web / šablony | `CGI`, `CGI::Fast`, `Template`, `Class::Inspector`, `JSON`, `JSON::XS` |
| databáze | `DBI`; **ovladače jen v profilových image**: `DBD::mysql` (`pwe-mariadb`, `pwe-mysql`), `DBD::MariaDB` (`pwe-mariadb`), `DBD::Pg` (`pwe-postgres`); `pwe-static` nemá žádný, `pwe-debugger` všechny tři |
| síť | `HTTP::Tiny` (jádro) + `IO::Socket::SSL`/`Net::SSLeay` = HTTPS klient, `URI`, `Net::SMTP` (+ `Authen::SASL` pro přihlášení k SMTP) |
| kryptografie | `Digest::SHA`, `Digest::MD5`, `MIME::Base64`, `Crypt::OpenSSL::RSA`, CLI `openssl` |
| e-mail, texty | `Mail::RFC822::Address`, `Cz::Cstocs` (+ CLI `cstocs`), `LWP::MediaTypes`, `Encode`, `HTML::Entities`, `URI::Escape` |
| soubory, obrázky | `Storable`, `Image::Magick`, CLI ImageMagick `/usr/bin/identify` a `/usr/bin/convert` (používá je `Libs::Pics`), CLI `sass` |
| čas, identifikátory | `Time::Piece`, `POSIX`, databáze časových pásem (`tzdata`, proměnná `TZ`) |

Engine se k MariaDB i MySQL připojuje přes `DBD::mysql` (`dbdriver => "mariadb"` i `"mysql"`);
`DBD::MariaDB` je v `pwe-mariadb` navíc pro kód webu. HTTPS API volá kód webu přes `HTTP::Tiny`
(tak to dělá e-shop Syrmex); `LWP::UserAgent`, `Data::UUID`, `Data::GUID`, `Crypt::OpenSSL::X509`
ani program `curl` v běhových image nejsou.

### Přidání knihovny

Knihovnu, kterou potřebuje **jeden web** (`GD`, `Text::CSV`, `Crypt::Eksblowfish`, `LWP::UserAgent`,
`Data::UUID`, `lessc`, `IO::AIO`, …), přidej do **`Dockerfile` webu**, ne do `pwe-base` — základ má
zůstat malý a společný:

```dockerfile
FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

RUN apt-get update \
    && apt-get install -y --no-install-recommends libtext-csv-perl libwww-perl liblwp-protocol-https-perl \
    && rm -rf /var/lib/apt/lists/*
```

(řádek `RUN` patří za druhý `FROM` a jeho řádky `ARG` v šabloně z oddílu
[Image vlastního webu](#image-vlastního-webu), před `COPY webapps/<web> <web>` — vrstva s balíčky se
pak při změně webu nestaví znovu). Názvy balíčků Ubuntu: `LWP::UserAgent` = `libwww-perl`, HTTPS pro
něj `liblwp-protocol-https-perl`, `Data::UUID` = `libdata-uuid-perl`, `Data::GUID` =
`libdata-guid-perl`, `Crypt::OpenSSL::X509` = `libcrypt-openssl-x509-perl`, program `curl` = `curl`.
Ve vývojovém stacku web běží v image `pwe-<profil>` a `pwe-debugger`, ne v image webu; aby tam knihovna
byla také, sestav si z nich odvozené image pod vlastním tagem a tag předej stacku:

```bash
for image in pwe-mariadb pwe-debugger; do
    printf 'FROM %s\nRUN apt-get update && apt-get install -y --no-install-recommends libtext-csv-perl && rm -rf /var/lib/apt/lists/*\n' \
        "$(bash PWE/tools/lib/images.sh pwe_image "$image")" \
        | docker build -t "$(bash PWE/tools/lib/images.sh pwe_image_registry)/$image:mujweb" -
done
PWE_IMAGE_TAG=mujweb make run WEB=mujweb.web PROFILE=mariadb
```

Základem (`FROM`) je image aktuální větve — tentýž, který by použil `make run`
(`bash PWE/tools/lib/images.sh pwe_image pwe-mariadb` → `ghcr.io/kukam/pwe-mariadb:<větev>`): místní
z `make images`, jinak ho Docker stáhne z registru. Když větev vlastní image nemá a publikované jsou
image větve `master`, nastav před smyčkou `export PWE_IMAGE_TAG=master` (a po ní `unset PWE_IMAGE_TAG`).
`PWE_IMAGE_TAG=mujweb` nastav až u `make run`, ne dřív — jinak by `FROM` ukazoval sám na sebe.
Prostý `docker build` místní image vidí;
kdo místo něj volá `docker buildx build` (nebo má nastavenou proměnnou `BUILDX_BUILDER` či alias
z `docker buildx install`), přidá `--builder <builder s ovladačem docker> --load`
([Image vlastního webu](#image-vlastního-webu)).

Do `pwe-base` (stage `base` v `PWE/docker/Dockerfile`) patří jen knihovna, bez které neběží **engine**;
ladicí nástroj patří do stage `debugger`, DB ovladač do stage profilu. Po změně `make images`.

### Registr a tagy

- **Registr:** `ghcr.io/kukam` — celé názvy jsou `ghcr.io/kukam/pwe-base`, `ghcr.io/kukam/pwe`,
  `ghcr.io/kukam/pwe-mariadb`, …
- **Tag = název větve gitu**, ze které byl image sestaven. Znaky mimo `A–Z a–z 0–9 _ . -` se nahradí
  pomlčkou, úvodní tečky a pomlčky se vypustí, délka je nejvýše 128 znaků: `master` → `master`,
  `pwe.ai` → `pwe.ai`, `feature/novy-kosik` → `feature-novy-kosik`. Pravidlo je na jednom místě
  (`pwe_image_tag_sanitize` v `PWE/tools/lib/images.sh`) a používají ho nástroje i pipeline.
- **Názvy větví, které tag nedávají jednoznačně, se odmítají.** Tag tvaru verze `X.Y.Z` (větev
  `2.1.0`, ale i `-2.1.0`) by se zaměnil s tagem verze image `pwe` — `make images` i pipeline skončí
  chybou (přejmenuj větev, např. `release-2.1.0` nebo `v2.1.0`, nebo zadej jiný `PWE_IMAGE_TAG`).
  Pipeline navíc odmítne větev, která dává stejný tag jako jiná větev repozitáře (`feature/kosik`
  a `feature-kosik`), nebo jako `master` či výchozí větev
  ([Pipeline GitHub Actions](#pipeline-github-actions)).
- **Jen image `pwe` má navíc tag verze** = obsah `PWE/VERSION`: `ghcr.io/kukam/pwe:master`
  i `ghcr.io/kukam/pwe:2.2.0`. Ostatní image mají pouze tag větve.
- **Tagy se přepisují — i tag verze.** Tag větve ukazuje na poslední sestavení té větve. Tag verze
  `pwe:<verze>` publikuje běh pipeline **z kterékoli větve**, ne jen z `master`: ukazuje na naposledy
  publikovaný engine s touto hodnotou `PWE/VERSION` a každá další publikace ho přepíše, dokud se
  verze nezvýší. Push do vývojové větve se stejnou verzí tedy `ghcr.io/kukam/pwe:2.2.0` přesměruje
  na kód té větve. Tag verze říká „engine této verze“, ne „tento konkrétní kód“.
- **Jednoznačně kód určuje jen digest nebo popisek commitu.** Kdo potřebuje přesně jeden neměnný
  obsah, odkáže se na digest (`ghcr.io/kukam/pwe@sha256:…`; vypisuje ho souhrn běhu pipeline,
  u staženého image `docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/kukam/pwe:<tag>`).
  Z jakého commitu engine v image `pwe` pochází, říká popisek
  `docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/kukam/pwe:<tag>`
  (pipeline ho vyplňuje vždy, lokální sestavení jen z čisté pracovní kopie; ostatní image popisek
  nemají — kód enginu neobsahují).
- Tag `latest` neexistuje. Stabilní řada je `master`.

### Výběr image v nástrojích

Nástroje v `PWE/tools/` i compose skládají název image ze dvou proměnných prostředí (funkce
v `PWE/tools/lib/images.sh`):

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr (fork: `ghcr.io/<vlastník>`, zrcadlo: `docker.io/<jmenný prostor>`) |
| `PWE_IMAGE_TAG` | aktuální větev gitu převedená na tag; bez gitu, v odpojeném `HEAD` nebo v kopii rozbalené uvnitř cizího gitu `master` | tag všech image; musí to být platný tag image (znaky `A–Z a–z 0–9 _ . -`, nezačíná tečkou ani pomlčkou, nejvýše 128 znaků), jinak nástroje skončí chybou |
| `PWE_TEST_IMAGE` | `<registr>/pwe-debugger:<tag>` | úplné přepsání image nástrojů (`make test`, `compile`, `check`, `cgi`, `module`, `smtp-test`); stack (`make run`) neovlivní |

```bash
make test                                                        # ghcr.io/kukam/pwe-debugger:<větev>
PWE_IMAGE_TAG=master make test                                   # image z větve master (větev nemá vlastní image)
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:master make test           # testy v jiném image (CI je pouští v pwe-base)
PWE_IMAGE_REGISTRY=ghcr.io/nekdo PWE_IMAGE_TAG=master make run WEB=mujweb.web
bash PWE/tools/lib/images.sh pwe_image pwe-mariadb               # vypíše celý název: ghcr.io/kukam/pwe-mariadb:<větev>
bash PWE/tools/lib/images.sh pwe_image_tag                       # jen tag
```

Nástroje na standardní chybový výstup hlásí, s jakým image pracují:

```text
make test (make compile: [perl-compile])
    [run-tests] image ghcr.io/kukam/pwe-debugger:pwe.ai
make run
    [run-webapp] web=mujweb.web profil=mariadb registr=ghcr.io/kukam tag=pwe.ai -> docker compose up --remove-orphans
make module (stejně make check a make smtp-test, když moduly na hostiteli chybí)
    [tools] chybi moduly Template Class::Inspector -> spoustim v kontejneru ghcr.io/kukam/pwe-debugger:pwe.ai
```

Když image v místním Dockeru není, přidá nástroj třířádkovou radu (Docker ho jinak mlčky zkusí
stáhnout a chyba registru sama neřekne, co s tím) — třetí řádek vyjmenuje tagy téhož image, které
v místním Dockeru jsou:

```text
[run-tests] image ghcr.io/kukam/pwe-debugger:feature-x neni v lokalnim Dockeru, docker ho zkusi stahnout z registru.
[run-tests]   sestaveni: make images (PWE/tools/build-images.sh)
[run-tests]   mistne dostupne tagy ghcr.io/kukam/pwe-debugger: master pwe.ai (pouziti: PWE_IMAGE_TAG=<tag>)
```

Když v místním Dockeru není žádný tag, zní poslední řádek `v lokalnim Dockeru neni zadny image
<repozitář>`; u image zadaného přes `PWE_TEST_IMAGE` radí `PWE_TEST_IMAGE=<repozitář>:<tag>`.
Stejnou radu vypisují `make compile` (`[perl-compile]`), `make cgi` (`[pwe-cgi]` — jinak o image mlčí,
jeho výstupem je HTTP odpověď), Perl nástroje (`[tools]`) a `make run` (`[run-webapp]`, zvlášť pro
`pwe-<profil>` a `pwe-debugger`; jen u příkazů compose, které vytvářejí kontejnery — `up`, `run`,
`create`). Když tedy image pro aktuální větev nejsou ani v registru (Docker hlásí `pull access denied`,
`manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden`), sestav si je lokálně
(`make images`), nebo použij tag, který místně máš, případně tag větve, která image publikované má
(`PWE_IMAGE_TAG=master`; kdy image větve `master` vznikají, říká oddíl
[Pipeline GitHub Actions](#pipeline-github-actions)).

`PWE_IMAGE_TAG` se nepřevádí — musí to už být platný tag. Nepřevedený název větve s lomítkem nástroje
odmítnou (shellové skončí kódem 2, Perl nástroje chybou) s hláškou
`PWE_IMAGE_TAG='feature/x' neni platny tag image (…). Nazev vetve preved: bash PWE/tools/lib/images.sh pwe_image_tag_sanitize 'feature/x'`.
S `PWE_TEST_IMAGE` se tag nekontroluje.

### Lokální sestavení

```bash
make images                                   # všech 7 image pro platformu tohoto stroje
make images ARGS='pwe debugger'               # jen vybrané cíle: base pwe static mariadb mysql postgres debugger
PWE/tools/build-images.sh --print             # jen vypíše cíle a tagy, nic nestaví (totéž make images ARGS=--print)
PWE/tools/build-images.sh --no-cache base     # bez mezipaměti vrstev (nové verze balíčků)
PWE/tools/build-images.sh --platform linux/amd64 base pwe             # zkušební sestavení pro jinou platformu (nenačte se)
PWE/tools/build-images.sh --push              # sestavit pro linux/amd64 i linux/arm64 a nahrát do registru (z commitnutého stavu)
PWE/tools/build-images.sh --help              # nápověda (totéž make images ARGS=--help)
make images-check                             # kouřové kontroly místních image (PWE/tools/smoke-images.sh)
```

`PWE/tools/build-images.sh [volby] [cíl…]` spustí `docker buildx bake -f docker-bake.hcl` (kontext =
kořen repozitáře) a předá mu registr a tag z `PWE_IMAGE_REGISTRY` / `PWE_IMAGE_TAG` a verzi
z `PWE/VERSION`. Na větvi `pwe.ai` tak vzniknou `ghcr.io/kukam/pwe-base:pwe.ai`,
`ghcr.io/kukam/pwe-<profil>:pwe.ai`, `ghcr.io/kukam/pwe-debugger:pwe.ai`, `ghcr.io/kukam/pwe:pwe.ai`
a `ghcr.io/kukam/pwe:2.2.0`. Všechny cíle se staví jedním voláním nad jedním `Dockerfile`, společný
stage `base` se tedy sestaví jen jednou. Cíl lze psát i celým názvem image (`pwe-base`, `pwe-mariadb`).

Skript doplní i popisky image `pwe`: čas sestavení (`created`) vždy, commit (`revision`) **jen z čisté
pracovní kopie** — s neuloženými změnami by commit obsahu image neodpovídal, popisek se proto vynechá.
Na začátku vypíše, co dělá (`[build-images] registr=ghcr.io/kukam tag=pwe.ai verze=2.2.0
platforma=stroje cile=vsechny -> nacteni do lokalniho Dockeru`), a po načtení seznam místních image
s tagem větve (u `pwe` i s tagem verze).

| Volba | Význam |
| --- | --- |
| *(bez voleb)* | sestaví pro platformu stroje a načte image do místního Dockeru |
| `--push` | publikuje do registru (vyžaduje `docker login`); nejde kombinovat s `--load`. Bez `--platform` publikuje **`linux/amd64,linux/arm64`** (a vypíše to) — jen platforma stroje by přepsala vícearchitekturní tag z pipeline; více platforem najednou potřebuje builder s ovladačem `docker-container` nebo Docker s úložištěm image containerd. Pojistky viz níže |
| `--allow-dirty` | povolí `--push` z pracovní kopie s necommitnutými změnami (popisek `revision` zůstane prázdný) |
| `--platform P` | cílová platforma nebo seznam (`linux/amd64,linux/arm64`); bez `--push` jde jen o zkušební sestavení — výsledek zůstane v mezipaměti builderu a do Dockeru se nenačte, aby pod stejným tagem nenahradil image pro platformu stroje |
| `--load` | načte výsledek do místního Dockeru i s `--platform` (více platforem najednou umí načíst jen Docker s úložištěm image containerd) |
| `--no-cache` | nepoužije mezipaměť sestavení |
| `--print` | vypíše výslednou konfiguraci (cíle, tagy, argumenty, popisky) a skončí; s `--push` pojistky jen varují („--push by skoncil chybou“) |
| `--set K=V` | předá nastavení přímo `docker buildx bake` (lze opakovat), např. `--set '*.cache-from=type=gha'` |
| `-h`, `--help` | nápověda |

Volby `--platform` a `--set` vyžadují hodnotu, která nezačíná pomlčkou (lze psát i `--platform=P`,
`--set=K=V`); `--platform --push` tedy skončí chybou, místo aby `--push` spolkl jako platformu.

**Pojistky publikace.** `--push` skončí kódem 2 a nic nestaví, když:

- tag nejde jednoznačně určit — není zadaný `PWE_IMAGE_TAG` a větev gitu určit nejde (odpojený
  `HEAD`, kopie bez gitu, kopie rozbalená uvnitř cizího gitového repozitáře): publikoval by se tag
  `master`. Totéž platí pro větev, jejíž název se na tag `master` teprve převede (např. `+master`).
  Řešení: `PWE_IMAGE_TAG=<tag>`;
- pracovní kopie má necommitnuté změny (`git status`) — publikoval by se kód, který není v žádném
  commitu, a image `pwe` by neměl popisek `revision`. Řešení: commit, nebo vědomě `--allow-dirty`.

Bez gitu, ale se zadaným `PWE_IMAGE_TAG` se publikuje s varováním, že popisek `revision` bude prázdný.
Místní sestavení bez určitelné větve jen varuje, že používá tag `master`. Nezávisle na `--push`
(i s `--print`) skript odmítne tag tvaru verze `X.Y.Z` — z `PWE_IMAGE_TAG` i z názvu větve
(`Tag 2.1.0 ma tvar verze X.Y.Z - zamenil by se s tagem verze image pwe …`, kód 2).

Kromě `PWE_IMAGE_REGISTRY` a `PWE_IMAGE_TAG` čte skript `PWE_IMAGE_REGISTRIES` (seznam registrů
oddělený čárkou, když se má publikovat do více najednou; má přednost před `PWE_IMAGE_REGISTRY`;
mezery, prázdné položky a koncová lomítka se odstraní, neplatný nebo prázdný seznam = kód 2, jmenný
prostor malými písmeny) a `PWE_IMAGE_SOURCE` (adresa repozitáře do popisku `source`, výchozí
`https://github.com/kukam/PWE`).

#### Kouřové kontroly image

`make images-check [ARGS='…']` (`PWE/tools/smoke-images.sh`) ověří, že každý image obsahuje to, co
má, a nic, co mít nemá — tentýž skript pouští pipeline před publikací:

```bash
make images-check                                         # všech 7 image aktuálního registru a tagu z místního Dockeru
make images-check ARGS='pwe debugger'                     # jen vybrané (base, pwe, static, mariadb, mysql, postgres, debugger i celé názvy)
PWE/tools/smoke-images.sh --platform linux/arm64          # image jiné platformy (na stroji amd64 v emulaci QEMU)
PWE_IMAGE_TAG=master PWE/tools/smoke-images.sh --pull always --platform linux/arm64   # publikovaný image z registru
```

| Image | Co se kontroluje (příkazy běží přes entrypoint image, bez sítě) |
| --- | --- |
| všechny | kontejner se spustí (s `--platform` i na správné architektuře); jdou načíst `CGI::Fast`, `Template`, `Class::Inspector`, `Class::MOP`, `JSON`, `JSON::XS`, `DBI`, `Mail::RFC822::Address`, `Cz::Cstocs`, `LWP::MediaTypes`, `IO::Socket::SSL`, `Net::SSLeay`, `Authen::SASL`, `Image::Magick`, `Crypt::OpenSSL::RSA`, `URI`, `HTML::Parser`; existují `sass`, `identify`, `convert`, `openssl` a pásmo `Europe/Prague` |
| `pwe-base` | `convert` a `identify` nad skutečným obrázkem, `sass` přeloží SCSS, funguje `openssl` a `TZ`; žádný DB ovladač |
| `pwe` | `perl -c pwe.fcgi`; obsah `/PWE/PWE` bez `t/` a `docker/`; `VERSION` a popisky odpovídají `PWE/VERSION`; **seznam souborů enginu v image = pracovní kopie `PWE/`** bez `t/`, `docker/` a bez toho, co vynechává `.dockerignore` |
| `pwe-static` | žádný DB ovladač |
| `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` | ovladač profilu (`DBD::mysql` + `DBD::MariaDB`, `DBD::mysql`, `DBD::Pg`) |
| `pwe-debugger` | všechny tři ovladače, `Perl::LanguageServer` ≥ 2.6.2, `perlcritic`, `perltidy`, `curl` |
| všechny kromě `pwe` | v image není kód enginu (`/PWE/PWE/pwe.fcgi`) |

Výchozí `--pull never` kontroluje jen místní image (chybějící = `FAIL`, nikdy se potichu nestáhne
starší image z registru); `--pull always` každý image nejdřív stáhne a **nahradí** místní image pod
stejným tagem. Výstup je jeden řádek na kontrolu (`OK   <image>: <popis>` nebo `FAIL <image>: <popis>`
s odsazeným důvodem), návratový kód 0 = vše prošlo, 1 = něco selhalo, 2 = špatné použití.
Kontrola souborů enginu selže, když je místní image `pwe` starší než pracovní kopie (pak
`make images ARGS=pwe`), nebo když nový adresář enginu chybí ve výčtu `COPY` stage `pwe`.

Soubory sestavení:

| Soubor | Co určuje |
| --- | --- |
| `PWE/docker/Dockerfile` | stage `base`, `pwe`, `static`, `mariadb`, `mysql`, `postgres`, `debugger` (každý `FROM base`); argumenty `UBUNTU_IMAGE` (výchozí `ubuntu:26.04`), `PWE_SOURCE` (popisek zdroje), `PWE_VERSION` (popisek verze u `pwe`; liší-li se od `PWE/VERSION`, sestavení skončí chybou), `PERL_LANGUAGESERVER_MIN` (nejnižší přípustná verze jazykového serveru v `debugger`, výchozí 2.6.2) |
| `PWE/docker/entrypoint.sh` | vstupní skript všech image (viz výše) |
| `docker-bake.hcl` | cíle `base`, `pwe`, `static`, `mariadb`, `mysql`, `postgres`, `debugger` (skupina `default` = všech 7) a jejich tagy; proměnné `REGISTRIES` (seznam oddělený čárkou, výchozí `ghcr.io/kukam`), `TAG` (výchozí `master`), `VERSION` (výchozí prázdná = bez tagu verze), `SOURCE` (adresa repozitáře do popisku všech image) a — **jen pro cíl `pwe`** — `REVISION` (commit) a `CREATED` (čas sestavení); obě jsou ve výchozím stavu prázdné a bake je sám nepočítá, aby stejné vstupy daly stejný image |
| `.dockerignore` | z kontextu sestavení vynechává `.git` i gity webů (`**/.git`), `webapps-example`, dočasná data webů (`ramdisk`, `log`, `sessions`, `uploadfile`, `temp`), `webapps/*/conf/local.env` (tajné údaje), `webapps/*/conf/database.conf` (v image ho vytvoří `RUN` šablony `Dockerfile` webu podle zapečeného profilu, za běhu ho nasměruje `entrypoint.sh`), soukromé klíče a certifikáty kdekoli pod `conf/` webu (`webapps/*/conf/**/*.pem`, `*.key`, `*.p12`, `*.pfx`; veřejné klíče `*.pub` zůstávají) a lokální nastavení vývojáře (`webapps/*/.env`, `webapps/*/.vscode`) — image webu tak nezávisí na stavu pracovní kopie a nenese tajné údaje ([Image vlastního webu](#image-vlastního-webu)) |

Platformy se v `docker-bake.hcl` nenastavují: lokálně se staví pro platformu stroje, pipeline přidává
`linux/amd64` a `linux/arm64`. Přímé volání bez skriptu (z kořene repozitáře):

```bash
TAG=test VERSION="$(cat PWE/VERSION)" docker buildx bake -f docker-bake.hcl --print      # jen vypíše, co by se stavělo
TAG=test docker buildx bake -f docker-bake.hcl --load pwe mariadb
docker build --target base -t pwe-base -f PWE/docker/Dockerfile .                        # jeden stage ručně, bez bake
```

### Pipeline GitHub Actions

V repozitáři jsou dva workflow GitHub Actions:

- **`.github/workflows/images.yml`** (název *Images*) sestaví všech sedm image přes
  `docker-bake.hcl` — stejným příkazem `docker buildx bake`, jaký lokálně spouští
  `PWE/tools/build-images.sh` —, otestuje je a publikuje do `ghcr.io/<vlastník repozitáře malými
  písmeny>` (u tohoto repozitáře `ghcr.io/kukam`);
- **`.github/workflows/tests.yml`** (název *Tests*) je lehký: jen testy enginu pro změny, které testy
  čtou, ale image z nich nevznikají; nic nepublikuje ([Workflow Tests](#workflow-tests)).

**Kdy běží Images:**

| Událost | Co se stane |
| --- | --- |
| `push` do **libovolné větve** (kromě `dependabot/**`), který mění `PWE/**`, `docker-bake.hcl`, `.dockerignore`, `LICENSE` nebo samotný workflow | sestavení, testy, kouřové kontroly obou platforem a **publikace** s tagem té větve — jen když je commit běhu stále hlavou větve |
| pull request, který mění tytéž cesty (i pull request Dependabota) | jen sestavení `linux/amd64`, testy a kouřové kontroly; nic se nepřihlašuje ani nepublikuje (tag `pr-<číslo>` existuje jen na runneru) |
| ruční spuštění (*Actions → Images → Run workflow*, volba větve) | totéž co `push`; volba `no_cache` sestaví bez mezipaměti pipeline (stáhne aktuální balíčky Ubuntu; z CPAN se při sestavení nic neinstaluje). Tlačítko je k dispozici až poté, co je workflow ve výchozí větvi repozitáře (viz [První zprovoznění](#první-zprovoznění)) |

Změna jen ve `webapps/`, `docs/` nebo v `docker-compose.yml` workflow Images nespouští (vzorové weby,
soubory stacku a `Makefile` hlídá workflow Tests, `docs/` žádný); push gitového tagu také ne (image
se tagují podle větve) a ruční spuštění nad gitovým tagem skončí chybou. Běhy nad stejnou větví (stejným
pull requestem) jdou po sobě. Nový push **zruší rozběhnutý běh jen u pull requestu**; publikující běh
se nikdy neruší (zrušení uprostřed nahrávání by v registru nechalo směs starých a nových image) —
další push čeká ve frontě a GitHub v ní drží jen ten nejnovější čekající běh.

**Co dělá Images:**

1. *Meta.* Určí tag (název větve převedený funkcí `pwe_image_tag_sanitize`; u pull requestu
   `pr-<číslo>`), verzi (`PWE/VERSION`, musí mít tvar `X.Y.Z`), registr a hodnoty popisků. Skončí
   chybou, když by tag nebyl jednoznačný:
   - **tag tvaru verze `X.Y.Z`** (kontroluje se převedený tag, takže i větev `-2.1.0`) — zaměnil by se
     s tagem verze image `pwe`; hláška radí přejmenovat větev na `release-<tag>` nebo `v<tag>`;
   - **stejný tag jako `master` nebo výchozí větev** — převod názvu na tag není prosté zobrazení
     (větev `-master` i název, ze kterého nic nezbude, dávají `master`). Je to ochrana před
     *náhodnou* kolizí, ne bezpečnostní hranice: kdo smí do repozitáře zapisovat, může si workflow
     ve své větvi upravit, a tag verze `pwe:<verze>` publikuje běh z kterékoli větve; image hlavní
     větve chrání jen pravidla větví a práva k balíčkům;
   - **stejný tag jako jiná větev repozitáře** (`feature/kosik` a `feature-kosik`; seznam větví
     z `git ls-remote --heads origin`) — jejich běhy by si image navzájem přepisovaly. Selžou běhy
     obou větví, dokud se jedna nepřejmenuje nebo nesmaže. Když seznam větví načíst nejde, běh
     pokračuje s varováním.
2. *Sestavení `linux/amd64`.* Sestaví image pro platformu runneru, načte je do Dockeru runneru
   (`--load`), zkontroluje pravidlo tagů (každý image má tag větve, který nemá tvar verze; tag verze
   má právě jen `pwe`) a ověří, že všechny tagy v Dockeru runneru opravdu jsou — testy nesmějí místo
   čerstvého sestavení potichu stáhnout starší image z registru.
3. *Testy a kompilace* v čerstvém `pwe-base` (`PWE_TEST_IMAGE=<pwe-base> PWE/tools/run-tests.sh`
   a `PWE/tools/perl-compile.sh`) — tím se zároveň hlídá, že základu nechybí žádná knihovna, kterou
   engine potřebuje.
4. *Kouřové kontroly `linux/amd64`*: `PWE/tools/smoke-images.sh --platform linux/amd64 --pull never`
   ([Kouřové kontroly image](#kouřové-kontroly-image)). Pull request končí tady.
5. *Hlava větve* (*Branch head*). Publikuje jen běh, jehož commit je stále hlavou větve (`git ls-remote`).
   Běh nad starším commitem (ruční *Re-run* starého běhu, mezitím přišel novější push) nebo nad
   zaniklou větví se sestaví a otestuje, ale publikaci přeskočí s poznámkou *Publikace preskocena*
   v logu — jinak by vrátil tagy větve i `pwe:<verze>` na starší kód. Když ověření technicky selže,
   publikuje se s varováním.
6. *Sestavení `linux/arm64`* v emulaci (QEMU), načtené do Dockeru runneru pod jménem, které existuje
   jen na runneru (`localhost/pwe-arm64/…`), aby nepřepsalo otestované image `linux/amd64`. První
   sestavení bez mezipaměti trvá desítky minut, další jednotky minut.
7. *Kouřové kontroly `linux/arm64`* — tentýž skript s `--platform linux/arm64` (limit 30 minut); po
   kontrole se image `arm64` z Dockeru runneru smažou. Testy enginu běží jen nad `linux/amd64` (kód
   enginu je čistý Perl, na platformě závisí jen balíčky image).
8. *Publikace.* Přihlásí se k registru a nahraje obě platformy s tagem větve, image `pwe` navíc
   s tagem verze z `PWE/VERSION` (z kterékoli větve — [Registr a tagy](#registr-a-tagy)). **Nic už
   nestaví:** vrstvy obou platforem se berou z mezipaměti builderu z kroků 2 a 6, publikuje se tedy
   přesně to, co prošlo testy a kouřovými kontrolami — do registru se nedostane ani `linux/arm64`,
   který kontrolami neprošel. Index obou platforem dostane anotace OCI
   `org.opencontainers.image.source`, `licenses` a `description` (hodnoty z popisků otestovaného
   image, tedy z `PWE/docker/Dockerfile`): podle anotací indexu GitHub u víceplatformního image
   zobrazuje popis balíčku a přiřazuje ho k repozitáři.
9. *Souhrn* vznikne vždy, i po chybě nebo zrušení běhu: publikované image, jejich tagy a digesty,
   jinak důvod, proč se nepublikovalo (pull request, commit už není hlavou větve, běh selhal), a commit.
   Selže-li samotná publikace, souhrn upozorní, že část image už může být v registru (cíle se nahrávají
   samostatně) — běh pak spusť znovu (*Re-run*).

Při jakékoli chybě v krocích 1–7 běh končí a nepublikuje se nic. K registru se workflow přihlašuje
vestavěným `GITHUB_TOKEN` (oprávnění `packages: write`); žádné tajemství se pro `ghcr.io` nenastavuje.

**Popisky, mezipaměť a akce.**

- Popisky image `pwe` předává workflow přes proměnné `docker-bake.hcl`: `REVISION` = commit běhu
  (`github.sha`), `CREATED` = čas určený jednou v kroku *Meta*. Všechna sestavení v běhu dostávají
  tytéž hodnoty, aby publikované image byly přesně ty otestované. Ostatní image tyto popisky nemají,
  takže se s každým commitem nemění ([Popisky image](#co-je-v-pwe-base)).
- Mezipaměť sestavení je v GitHub Actions (`type=gha`) a má pro každý cíl dva obory (scope) podle
  platformy: `images-<cíl>-amd64` zapisuje sestavení `linux/amd64` (každý běh včetně pull requestu),
  `images-<cíl>-arm64` sestavení `linux/arm64` (jen běh, který publikuje). Běh, který skončí na
  testech, tak mezipaměť `arm64` nepřepíše. Publikace mezipaměť jen čte (pojistka pro případ, že
  builder část své mezipaměti mezitím uvolnil). Dřívější obory `images-<cíl>` a `images-<cíl>-test`
  se už nepoužívají.
- `no_cache` při ručním spuštění: mezipaměť `type=gha` se nečte (všechny vrstvy včetně `apt-get`
  se staví znovu, `linux/arm64` celý v emulaci), jen se obnoví.
- Image se publikují bez atestací (`--provenance=false --sbom=false`): tag pak ukazuje na čistý
  index se dvěma platformami, který čtou všechny nástroje včetně `docker manifest inspect`.
- **Akce jsou připnuté na SHA commitu** s verzí v komentáři (`uses: actions/checkout@<sha> # v7.0.1`).
  Nové verze navrhuje jednou týdně **Dependabot** (`.github/dependabot.yml`, ekosystém
  `github-actions`) — v pull requestu změní SHA i komentář. Jeho pull request projde sestavením
  a testy jako každý jiný a nic nepublikuje; push do větví `dependabot/**` workflow nespouští (běžel by
  s tokenem jen pro čtení a pokus o publikaci by skončil chybou).

#### Workflow Tests

`.github/workflows/tests.yml` hlídá soubory, které sada `PWE/t` čte, ale workflow Images je
nesleduje: `webapps/example.web/**` a `webapps/example-db.web/**` (smoke requesty a shoda
`Dockerfile` vzorových webů s generátorem), `docker-compose.yml` a `docker-compose/**`, `kubernetes/**`,
`Makefile` a sám sebe. Spouští se na `push` (kromě větví `dependabot/**`) a pull request, které tyto
cesty mění, a ručně. Sestaví jen cíl `base` (jako `localhost/pwe-tests/pwe-base:ci`, existuje jen na
runneru), pustí `PWE/tools/run-tests.sh` a `PWE/tools/perl-compile.sh` s `PWE_TEST_IMAGE` na tento
image a nic nepublikuje: oprávnění má jen `contents: read`, do registru se nepřihlašuje a mezipaměť
`type=gha` nepoužívá. Nový push do stejné větve rozběhnutý běh zruší. Bez něj by se chyba ve vzorovém
webu projevila až červeným během Images u další, nesouvisející změny enginu.

#### První zprovoznění

**Co musí být v gitu.** Workflow vidí jen to, co je commitnuté a nahrané na GitHub: adresář `PWE/`
(engine, `PWE/docker/`, `PWE/tools/`, testy `PWE/t/`), `docker-bake.hcl`, `.dockerignore`, `LICENSE`,
vzorové weby `webapps/example.web` a `webapps/example-db.web`, `docker-compose.yml` a `kubernetes/`
(s nimi pracují testy enginu; bez nich se příslušné testy přeskočí) a samotné
`.github/workflows/images.yml`, `.github/workflows/tests.yml` a `.github/dependabot.yml`. `push`
spouští běh ve větvi, která workflow obsahuje.

**Co nastavit v repozitáři na GitHubu:**

1. **Actions musí být povolené** — ve forku jsou po založení vypnuté (viz *Fork* níže).
2. **Ruční spuštění až z výchozí větve.** Tlačítko *Run workflow* GitHub nabídne až poté, co je
   workflow začleněný do **výchozí větve** repozitáře (`master`). Do té doby workflow spouští jen
   `push`; ruční běh — a s ním volba `no_cache` — není k dispozici. Po začlenění ho lze pustit nad
   kteroukoli větví, která soubor workflow obsahuje. Platí pro *Images* i *Tests*.
3. **Dependabot** čte `.github/dependabot.yml` jen z výchozí větve, začne tedy pracovat až po
   začlenění. Aktualizace verzí potřebují zapnutý *Dependency graph* (*Settings → Code security*) —
   u veřejného repozitáře je zapnutý, ve forku a v soukromém repozitáři ho zapni ručně.
4. **Viditelnost balíčků** v `ghcr.io` nastav po prvním publikujícím běhu (balíčky vzniknou soukromé)
   a zkontroluj přístup repozitáře k nim (*Manage Actions access*) — viz níže.
5. **Povinné kontroly větve** (*required status checks*): joby *Build, test, publish* (Images)
   a *Engine tests* (Tests) jako povinné nenastavuj — oba workflow mají filtr `paths`, takže pull
   request, který sledované cesty nemění, by na výsledek čekal navždy (*Pending*).
6. **Názvy větví:** ne tvaru `X.Y.Z` a ne takové, které po převodu dávají tag jiné větve
   ([Registr a tagy](#registr-a-tagy)) — běh Images takové větve skončí chybou v kroku *Meta*.
7. Volitelné zrcadlo na Docker Hub: proměnná `DOCKERHUB_NAMESPACE` a tajemství `DOCKERHUB_USERNAME`
   a `DOCKERHUB_TOKEN` (viz níže).

**Kdy vzniknou image s tagem `master`.** Tag `master` — výchozí tag v `docker-compose.yml` a cíl rady
`PWE_IMAGE_TAG=master` — publikuje pipeline jen při běhu **nad větví `master`**: po `push` do `master`,
který mění sledované cesty, nebo při ručním spuštění nad `master`. Běh nad jinou větví publikuje pouze
tag té větve (a tag verze image `pwe`). Bez běhu nad `master` image `ghcr.io/kukam/pwe-*:master`
v registru nejsou a `PWE_IMAGE_TAG=master` skončí stejnou chybou stažení jako chybějící image větve —
pak zbývá `make images`.

**Fork.** Fork repozitáře publikuje do `ghcr.io/<vlastník forku>`; nástrojům to řekni přes
`PWE_IMAGE_REGISTRY`. Ve forku jsou workflow po jeho založení vypnuté — nejdřív je povol (záložka
*Actions* → *I understand my workflows, go ahead and enable them*), jinak `push` žádný běh nespustí.

**Chyba `denied: permission_denied: write_package`** v kroku publikace znamená, že balíček
v `ghcr.io` už existuje a tento repozitář do něj nesmí zapisovat — typicky vznikl mimo workflow
(ruční `PWE/tools/build-images.sh --push` s osobním tokenem, jiný repozitář). U každého takového
balíčku otevři *Package settings → Manage Actions access → Add repository*, vyber repozitář
a nastav mu roli **Write**; pak běh zopakuj (*Re-run jobs*).

**Volitelné zrcadlo na Docker Hub.** Když má repozitář nastavenou proměnnou `DOCKERHUB_NAMESPACE`
(např. `kukam`) a tajemství `DOCKERHUB_USERNAME` a `DOCKERHUB_TOKEN` (GitHub → repozitář → *Settings →
Secrets and variables → Actions*; proměnná na kartě *Variables*, tajemství na kartě *Secrets*), nahrají
se tytéž image se stejnými tagy i do `docker.io/<DOCKERHUB_NAMESPACE>`. Chybí-li cokoli z toho,
publikuje se jen do `ghcr.io` (je-li nastavená jen proměnná bez tajemství, běh na to upozorní
varováním). `DOCKERHUB_USERNAME` je přihlašovací jméno účtu, který smí do jmenného prostoru
zapisovat, `DOCKERHUB_TOKEN` jeho přístupový token (Docker Hub → *Account settings → Personal access
tokens*) s oprávněním **Read & Write** — s tokenem jen pro čtení nahrání selže. Repozitáře
`pwe-base`, `pwe`, `pwe-static`, … Docker Hub založí při prvním nahrání, s výchozí viditelností
nastavenou u účtu (*Default privacy*). Image ze zrcadla použiješ přes
`PWE_IMAGE_REGISTRY=docker.io/<jmenný prostor>`.

**Viditelnost balíčků v GHCR.** Nový balíček kontejneru je **soukromý**, dokud mu vlastník viditelnost
nezmění — do té doby ho bez přihlášení nestáhne nikdo (`make run`, `make test` ani `docker build`
image webu na jiném stroji). Aby šly
image stahovat bez přihlášení, nastav u každého ze sedmi balíčků (`pwe-base`, `pwe`, `pwe-static`,
`pwe-mariadb`, `pwe-mysql`, `pwe-postgres`, `pwe-debugger`) viditelnost *Public*: GitHub → profil
vlastníka → *Packages* → balíček → *Package settings* → *Change visibility*. Změna na veřejný je
nevratná. Balíčky jsou k repozitáři přiřazené přes `org.opencontainers.image.source` (u víceplatformního
image přes anotaci indexu, kterou pipeline nastavuje — [Co dělá Images](#pipeline-github-actions), krok 8),
takže je najdeš i na jeho stránce v sekci *Packages*.

**Přihlášení k soukromým balíčkům.** Dokud jsou balíčky soukromé, přihlas Docker osobním přístupovým
tokenem (classic) s oprávněním `read:packages` (pro `--push` z vlastního stroje `write:packages`):

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-login> --password-stdin
```

V Kubernetes se stejné údaje předávají jako `imagePullSecrets`.

### Image vlastního webu

Web má vlastní `Dockerfile` (vytváří ho `make new`, pro všechny weby stejná šablona — liší se jen
názvem webu a výchozím profilem). Běhové prostředí bere z image profilu, engine kopíruje z image `pwe`.
Šablona bez úvodního komentáře (ten popisuje složení image a obsahuje příkazy sestavení níže);
`<web>` je název webu, výchozí profil `mariadb` (u webu bez databáze `static`) — přesně tak vypadá
`webapps/example-db.web/Dockerfile`:

```dockerfile
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=master
ARG PWE_ENGINE_TAG=${PWE_IMAGE_TAG}
ARG PWE_PROFILE=mariadb

FROM ${PWE_IMAGE_REGISTRY}/pwe:${PWE_ENGINE_TAG} AS engine
FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

COPY --from=engine /PWE/PWE /PWE/PWE
COPY --from=engine /PWE/LICENSE /PWE/LICENSE

# PWE_CONF_pwe_core=/PWE/PWE nastavuje uz zakladni image pwe-base. PWE_PROFILE = profil, pro ktery je image
# sestaveny. Za behu ho lze prepsat (-e PWE_PROFILE=...) jen na profil, jehoz ovladac image obsahuje:
# pwe-mariadb a pwe-mysql umi mariadb i mysql (engine pro oba pouziva DBD::mysql), pwe-postgres jen
# postgres, pwe-static zadnou databazi. Entrypoint pak conf/database.conf presmeruje na novy profil.
ENV PWE_CONF_pwe_home=/PWE/webapps/<web> \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky behoveho image (nazev pwe-<profil>, popis "bez kodu
# enginu", repozitar a licence enginu), ktere o image webu neplati. source a licenses jsou proto prazdne -
# dopln adresu repozitare a licenci webu; base.name = behovy image, ze ktereho je image sestaveny.
LABEL org.opencontainers.image.title="<web>" \
      org.opencontainers.image.description="Web <web> nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/<web>" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/

COPY webapps/<web> <web>

WORKDIR /PWE/webapps/<web>

# Pracovni adresare a conf/database.conf (symlink na konfiguraci profilu, pokud ji web ma) vznikaji uz pri
# buildu: image tak bezi i s korenovym souborovym systemem jen pro cteni (pracovni adresare pak jako tmpfs
# nebo volume). Entrypoint dela totez pri startu - kvuli prepsani PWE_PROFILE a mountum pres adresar webu.
RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log; \
    if [ -f "conf/${PWE_PROFILE}.conf" ] && { [ -L conf/database.conf ] || [ ! -e conf/database.conf ]; }; then \
        ln -sfn "${PWE_PROFILE}.conf" conf/database.conf; \
    fi

# ENTRYPOINT se dedi z behoveho image (/usr/local/bin/entrypoint.sh z pwe-base), web vlastni nema.
CMD ["perl", "/PWE/PWE/pwe.fcgi"]
```

Co z šablony plyne:

- **Žádný vlastní vstupní skript.** `Dockerfile` webu `ENTRYPOINT` nenastavuje a web `entrypoint.sh`
  nemá: image webu dědí `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` z běhového image `pwe-<profil>`
  (ten ho má z `pwe-base`, zdroj `PWE/docker/entrypoint.sh`) — oprava vstupního skriptu se tak do
  image webu dostane s novým běhovým image, bez zásahu do webu ([Co je v `pwe-base`](#co-je-v-pwe-base)).
- **Profil je do image zapečený.** `ARG PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` a `PWE_PROFILE` jsou za
  druhým `FROM` deklarované znovu (argument z hlavičky platí jen pro řádky `FROM`), aby šly zapsat do
  `ENV` a `LABEL`. Kontejner z image webu tak `PWE_PROFILE` předávat nemusí. Za běhu ho lze přepsat
  (`-e PWE_PROFILE=…`) jen na profil, jehož ovladač image obsahuje: `pwe-mariadb` a `pwe-mysql` umí
  `mariadb` i `mysql` (engine pro oba používá `DBD::mysql`), `pwe-postgres` jen `postgres`,
  `pwe-static` žádnou databázi; entrypoint pak `conf/database.conf` přesměruje na nový profil.
- **Pracovní adresáře a `conf/database.conf` vznikají už při sestavení** (`RUN`): `ramdisk/templates`,
  `sessions`, `uploadfile`, `log` a — má-li web `conf/<profil>.conf` — symlink `conf/database.conf` →
  `<profil>.conf` (běžný soubor `conf/database.conf` se nepřepisuje). Image tak běží i s kořenovým
  souborovým systémem **jen pro čtení**: `docker run --read-only` (Kubernetes `readOnlyRootFilesystem`)
  a pracovní adresáře webu jako `tmpfs` nebo svazek (`emptyDir`), např.
  `--tmpfs /PWE/webapps/<web>/ramdisk --tmpfs /PWE/webapps/<web>/sessions --tmpfs /PWE/webapps/<web>/uploadfile --tmpfs /PWE/webapps/<web>/log`.
  Entrypoint totéž dělá při startu (kvůli přepsání `PWE_PROFILE` a mountům přes adresář webu); s kořenem
  jen pro čtení ale profil za běhu přepnout nejde — symlink zůstane z doby sestavení a entrypoint
  vypíše varování. Proces běží jako `root` (`runAsNonRoot` podporovaný není).
- **Vlastní popisky.** Bez `LABEL` by image webu zdědil popisky běhového image (název `pwe-<profil>`,
  popis „bez kódu enginu“, repozitář a licenci enginu). Šablona proto nastaví `title` = název webu,
  `description`, `base.name` = běhový image, ze kterého je sestavený, a **prázdné `source`
  a `licenses`** — doplň adresu repozitáře a licenci webu (hlavně když image publikuješ do `ghcr.io`:
  GitHub podle `source` přiřazuje balíček k repozitáři).

| Argument sestavení | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr a jmenný prostor image enginu |
| `PWE_IMAGE_TAG` | `master` | tag (větev) běhového image `pwe-<profil>` |
| `PWE_ENGINE_TAG` | hodnota `PWE_IMAGE_TAG` | tag image `pwe`, ze kterého se kopíruje engine: větev, nebo **verze** enginu (obsah `PWE/VERSION`, např. `2.2.0`) |
| `PWE_PROFILE` | podle webu (`mariadb`, `mysql`, `postgres`, `static`) | běhový profil = DB ovladač v image a zapečená proměnná `PWE_PROFILE` |

Sestavení (z kořene repozitáře, protože `COPY` kopíruje `webapps/<web>`; první tři příkazy jsou
i v záhlaví `Dockerfile` webu):

```bash
# z image aktuální větve - tak je označuje lokální sestavení (make images) i pipeline
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    -t muj-web -f webapps/<web>/Dockerfile .

# z image větve master (výchozí PWE_IMAGE_TAG; musí být v registru nebo v místním Dockeru)
docker build -t muj-web -f webapps/<web>/Dockerfile .

# engine připnutý na verzi: tag image pwe = obsah PWE/VERSION; běhový image dál určuje PWE_IMAGE_TAG
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    --build-arg PWE_ENGINE_TAG="$(cat PWE/VERSION)" -t registry/muj-web:1.0 -f webapps/<web>/Dockerfile .

# pro dvě platformy rovnou do registru (image enginu musí být v registru, viz níže)
docker buildx build --push --platform linux/amd64,linux/arm64 --build-arg PWE_ENGINE_TAG=2.2.0 \
    -t registry/muj-web:1.0 -f webapps/<web>/Dockerfile .
```

**Odkud se berou image enginu.** `docker build` vezme image enginu (`pwe` a `pwe-<profil>`) z místního
Dockeru, a když tam nejsou, stáhne je z registru (dokud jsou balíčky soukromé, musí být Docker
k `ghcr.io` přihlášený). Výchozí tag `master` proto potřebuje publikované image větve `master`. Nad
image sestavenými lokálně (`make images`) předej jejich tag — `--build-arg PWE_IMAGE_TAG=<větev>`,
hodnotu vypíše `bash PWE/tools/lib/images.sh pwe_image_tag` — a stačí prostý `docker build` (druhý
příkaz výše).

**Kterým builderem se staví.** Místní image vidí jen builder s ovladačem `docker` (sloupec
`DRIVER/ENDPOINT` ve výpisu `docker buildx ls`). Builder typu `docker-container` běží ve vlastním
kontejneru, místní image **nevidí** a základní image vždy stahuje z registru. Který builder se použije:

- **prostý `docker build`** staví builderem aktuálního kontextu Dockeru, tedy s ovladačem `docker` —
  i tehdy, když je v `docker buildx ls` hvězdičkou označen jiný builder. Výjimky: volba `--builder`,
  nastavená proměnná `BUILDX_BUILDER` a alias z dříve spuštěného `docker buildx install` (s ním je
  `docker build` totéž co `docker buildx build`);
- **`docker buildx build`** a `docker buildx bake` staví builderem označeným hvězdičkou. Je-li typu
  `docker-container`, skončí sestavení nad místními image chybou stažení (u `ghcr.io`
  `failed to fetch anonymous token … 403 Forbidden`). Builder s ovladačem `docker` pak vyber
  výslovně; jmenuje se podle kontextu Dockeru — v Docker Desktopu `desktop-linux`, na Linuxu
  zpravidla `default`.

```bash
docker buildx ls                                                   # hvězdička = vybraný builder; ovladač ve sloupci DRIVER/ENDPOINT
docker buildx build --builder desktop-linux --load \
    --build-arg PWE_IMAGE_TAG=pwe.ai -t muj-web -f webapps/<web>/Dockerfile .
```

Vícearchitekturní sestavení s `--push` běží zpravidla v builderu `docker-container` (ovladač `docker`
staví více platforem najednou jen s úložištěm image containerd) — pro něj musí být image enginu
v registru.

- **Připnutí enginu na verzi.** `PWE_ENGINE_TAG=2.2.0` vezme engine z `ghcr.io/kukam/pwe:2.2.0`,
  běhový image zůstává `pwe-<profil>:<větev>` (profilové image tag verze nemají). Při startu navíc
  verzi hlídá `pwe.require_core` v `conf/web.conf`. Tag verze je přepisovatelný a publikuje ho běh
  z kterékoli větve ([Registr a tagy](#registr-a-tagy)); úplně stejný engine při každém sestavení
  zaručí jen digest — pak v `Dockerfile` webu nahraď první `FROM` za
  `FROM ghcr.io/kukam/pwe@sha256:… AS engine`.
- **Engine se nebere z pracovní kopie.** Image webu obsahuje engine z image `pwe`, ne z adresáře
  `PWE/` vedle webu. Kdo chce do image webu upravený engine, sestaví nejdřív image své větve
  (`make images` — vznikne i `ghcr.io/kukam/pwe:<větev>` z pracovní kopie) a web pak prostým
  `docker build --build-arg PWE_IMAGE_TAG=<větev> …`, který místní image vidí (viz výše).
- **Image webu nezávisí na stavu pracovní kopie a nenese tajné údaje.** Kořenový `.dockerignore`
  z kontextu vynechává `webapps/*/conf/local.env` (tajné údaje), soukromé klíče a certifikáty
  kdekoli pod `conf/` webu (`*.pem`, `*.key`, `*.p12`, `*.pfx`), `webapps/*/conf/database.conf`
  (symlink podle zapečeného profilu vytvoří `RUN` šablony při sestavení), dočasné adresáře webu (`ramdisk`,
  `log`, `sessions`, `uploadfile`, `temp`), git webu (`**/.git`) a lokální nastavení vývojáře
  (`webapps/*/.env`, `webapps/*/.vscode`). Do image se tedy nedostane heslo z `conf/local.env`,
  privátní klíč (např. `conf/csob/private.pem` platební brány) ani profil, se kterým byl web
  naposledy spuštěn přes `make run`.
- **Soukromé klíče dostane kontejner až za běhu** — mountem nebo secretem — a cestu k nim přes
  `PWE_CONF_*`. Příklad e-shopu Syrmex (privátní klíč platební brány,
  [22 — Platební brána ČSOB](22-platebni-brana-csob.md#10-přechod-do-produkce)):

  ```bash
  docker run … -v /srv/secrets/csob/private.pem:/run/secrets/csob_private.pem:ro \
      -e PWE_CONF_csob_private_key=/run/secrets/csob_private.pem registry/muj-web:1.0
  ```

  Bez klíče tam platba v režimu `test`/`production` skončí chybou `error_payment_keys`. Veřejné klíče
  (`*.pub`) v image zůstávají. Vzory platí jen pro adresář `conf/` webu — klíč uložený jinde ve webu
  by se do image dostal, a naopak veřejný klíč s příponou `.pem` v `conf/` se do image nedostane.
- Image webu má zapečené `PWE_CONF_pwe_home` svého webu, `PWE_PROFILE` a z `pwe-base` zděděné
  `PWE_CONF_pwe_core=/PWE/PWE`; `FCGI_SOCKET_PATH` (např. `:7779`) a časové pásmo (image běží v UTC,
  viz [Časové pásmo](#časové-pásmo)) dodá až nasazení.
- **Web vytvořený starší šablonou** (vlastní `entrypoint.sh`, v `Dockerfile` řádky
  `ADD webapps/<web>/entrypoint.sh …` a `ENTRYPOINT`) funguje dál, ale s vlastní starou kopií vstupního
  skriptu bez varování a bez pracovních adresářů založených při sestavení. Převod: smaž
  `webapps/<web>/entrypoint.sh` a `Dockerfile` nahraď výstupem generátoru — vygeneruj web stejného
  názvu a profilu do dočasného adresáře
  (`PWE/tools/new-webapp.pl <web> --db <profil> --dir /tmp/<web>-novy`; u webu bez databáze bez `--db`)
  a zkopíruj z něj `Dockerfile`; vlastní úpravy (`RUN` s knihovnami, popisky `source`/`licenses`)
  přenes ručně.

### Přechod ze starého uspořádání image

Do 15. 11. 2026 se používaly image z Docker Hubu `kukam/pwe-base:latest` (Ubuntu, všechny knihovny
včetně DB ovladačů a ladicích nástrojů **a engine** v `/PWE/PWE`) a `kukam/pwe-<profil>:latest`
(základ + vzorový web se zapečeným `PWE_CONF_pwe_home`). Toto uspořádání je historické; existující
web a nasazení je potřeba upravit:

| Co | Dřív | Nyní |
| --- | --- | --- |
| `Dockerfile` webu | `FROM kukam/pwe-base:latest` (engine byl v základu) | šablona z oddílu [Image vlastního webu](#image-vlastního-webu): běh z `pwe-<profil>`, engine z `pwe`; `ENV PWE_CONF_pwe_core` už v něm není (má ho `pwe-base`) |
| `entrypoint.sh` webu | vlastní kopie (`ADD … entrypoint.sh` a `ENTRYPOINT` v `Dockerfile`) | smazat — image webu vstupní skript dědí z `pwe-<profil>` (zdroj `PWE/docker/entrypoint.sh`) |
| knihovna mimo nový základ (`lessc`, `IO::AIO`, překladač, `cpanm`, `curl`, `LWP::UserAgent`, `Data::UUID`, `Data::GUID`, `Crypt::OpenSSL::X509`, DB ovladač v jiném profilu) | byla v `kukam/pwe-base` | přidat do `Dockerfile` webu ([Přidání knihovny](#přidání-knihovny)) |
| image nástrojů | `kukam/pwe-mariadb:latest`, přepis `PWE_TEST_IMAGE=kukam/pwe-…:latest` | `ghcr.io/kukam/pwe-debugger:<větev>`; výběr přes `PWE_IMAGE_TAG` / `PWE_IMAGE_REGISTRY` |
| vlastní compose, Kubernetes, CI | `kukam/pwe-<profil>:latest` | `ghcr.io/kukam/pwe-<profil>:<větev>`, ladění `ghcr.io/kukam/pwe-debugger:<větev>` |
| VS Code v režimu `run` | `kukam/pwe-base:latest` v `perl.containerArgs` | `ghcr.io/kukam/pwe-debugger:<větev>` |

Nestačí ve starém `Dockerfile` jen zaměnit základ za `ghcr.io/kukam/pwe-base`: nový základ engine
nenese a kontejner by skončil chybou `Can't open perl script "/PWE/PWE/pwe.fcgi"`. Tag `latest` se
už nepublikuje — historické `kukam/pwe-*:latest` na Docker Hubu zůstávají ve starém uspořádání a dál
se neaktualizují ([zrcadlo](#pipeline-github-actions), je-li zapnuté, nahrává jen tagy větví a verze).
Staré místní image `kukam/pwe-*:latest` po přechodu nic nepoužívá a lze je smazat (`docker image rm`).

## Vývojový stack (`docker-compose.yml`)

```bash
make run WEB=<web> PROFILE=mariadb [ARGS=-d]      # = PWE_WEBAPP=<web> COMPOSE_PROFILES=mariadb PWE_IMAGE_TAG=<větev> docker compose up
```

| Služba | Co dělá |
| --- | --- |
| `webproxy` (nginx) | port `7778`; `/assets/`, `/static/` a `/uploadfile/` servíruje z disku (nejdřív `webapps/<web>` včetně volume s nahranými soubory, pak `PWE/assets`), ostatní předává FastCGI na `pwe-fcgi-1..3:7779`, `/debug.cgi` na debugger |
| `fcgi` ×3 | image `pwe-<profil>` (podle `COMPOSE_PROFILES`); engine `perl /PWE/PWE/pwe.fcgi` s `PWE_CONF_pwe_home=/PWE/webapps/<web>`, `PWE_CONF_pwe_core=/PWE/PWE`, `FCGI_SOCKET_PATH=:7779`; repozitář mountován do `/PWE` (image sám kód enginu neobsahuje) |
| `mariadb` / `mysql` / `postgres` | databáze podle profilu (porty 7776 / 7777 / 7775), přihlášení `pwe`/`pwe`, DB `pwe` (`docker-compose/docker-compose_<profil>.env`) |
| `debugger` | image `pwe-debugger` (všechny DB ovladače + ladicí nástroje), `sleep infinity` — pro VS Code debugger a ruční příkazy; repozitář mountován do `/PWE`. Má `init: true`: `sleep infinity` jako proces č. 1 by na `SIGTERM` nereagoval a `docker compose down` by na kontejner čekal až do vypršení limitu |
| `webapps/<web>/conf/local.env` | volitelný soubor s proměnnými, který načítají služby `fcgi` i `debugger` (`env_file`, `required: false`): SMTP účet, hesla a další `PWE_CONF_*` přepisy mimo git (vzor `conf/local.env.example` v e-shopu Syrmex) |
| `mailpit` | vývojový SMTP server (port `1025` uvnitř sítě, UI <http://127.0.0.1:8025>): zachytí e-maily z fronty `Services::Email`, když má web `smtp_primary => { host => "mailpit", port => 1025 }` |

Image služeb skládá compose z proměnných prostředí:

| Služba | Image |
| --- | --- |
| `fcgi` | `${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}/pwe-${COMPOSE_PROFILES:-mariadb}:${PWE_IMAGE_TAG:-master}` |
| `debugger` | `${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}/pwe-debugger:${PWE_IMAGE_TAG:-master}` |

`make run` (`PWE/tools/run-webapp.sh`) obě proměnné nastaví sám — tag podle aktuální větve gitu
([Výběr image v nástrojích](#výběr-image-v-nástrojích)) — a vypíše je
(`[run-webapp] web=… profil=… registr=ghcr.io/kukam tag=pwe.ai -> docker compose up --remove-orphans`).
Přímé `docker compose up` bez těchto proměnných použije tag `master`. Když image pro větev v registru
nejsou, sestav je (`make images`) nebo spusť stack s tagem, který místně máš (`PWE_IMAGE_TAG=<tag>`),
případně s `PWE_IMAGE_TAG=master`, jsou-li publikované. Služby `fcgi` a `debugger`
vlastní `entrypoint` nemají: adresář webu připraví `entrypoint.sh` z image podle `PWE_PROFILE`, který
jim compose předává (symlink `conf/database.conf`, dočasné adresáře).

**Profil musí odpovídat webu.** `make run` odmítne neznámý profil nebo příkaz (`PROFILE=oracle`,
`PROFILE=Mariadb` → `Neznamy profil nebo prikaz '…'`, kód 2) a u příkazů, které vytvářejí kontejnery
(`up`, `run`, `create`), varuje `[run-webapp] POZOR: …`, když web s `conf/mariadb.conf`,
`conf/mysql.conf` nebo `conf/postgres.conf` spouštíš s profilem `static` (poběží bez databáze), nebo
web bez `conf/<profil>.conf` s databázovým profilem (databáze se spustí, web ji nepoužije). Při startu
pak varuje i vstupní skript kontejnerů `fcgi` a `debugger`
(`[entrypoint] VAROVANI: PWE_PROFILE=mariadb, ale conf/mariadb.conf neexistuje …`, resp. — má-li web
v pracovní kopii symlink `conf/database.conf` — `PWE_PROFILE=static, ale conf/database.conf ukazuje na …`);
start to nepřeruší. Web bez databáze spouštěj s `PROFILE=static`.

Po `make images` (nebo jiné změně image) stačí znovu `make run`: compose kontejnery `fcgi` a `debugger`
vytvoří znovu z nového image a nginx si jejich nové adresy zjistí sám
([nginx](#nginx-docker-composedocker-compose_nginxconf)).

Proměnné pro engine jsou v `docker-compose/docker-compose_common.env` (`FCGI_SOCKET_PATH`, `PWE_CONF_log_loglevel=3`,
`PWE_CONF_pwe_save_opt_to=db`, …) a `docker-compose/docker-compose_<profil>.env` (přístup k DB přes
`PWE_CONF_dbi_db1_*`). Volumes jsou pojmenované podle webu (`pwe_mariadb_<web>`,
`pwe_uploadfile_<web>`, `pwe_sessions_<web>`), takže přepnutí na jiný web nesdílí data;
`make down … ARGS=-v` je smaže.

**Profily `mysql` a `postgres`.** Databáze běží z plovoucích image `mysql:latest` a `postgres:latest`
(při ověření 2026-11-15 MySQL 26.10 a PostgreSQL 18.7; `mariadb:latest` = MariaDB 13.0).

- **MySQL:** účet `pwe` má výchozí plugin `caching_sha2_password`; engine se po odmítnutí nešifrovaného
  přihlášení připojí přes TLS sám ([09 — Šifrované spojení a volby DSN](09-databaze-a-entity.md#šifrované-spojení-a-volby-dsn-dsn_options)),
  v `conf/mysql.conf` není potřeba nic měnit.
- **PostgreSQL:** volume `pwe_postgres_<web>` je namountovaný na `/var/lib/postgresql` (image 18+ ukládá data do
  `/var/lib/postgresql/<major>/docker`). Až `postgres:latest` přejde na další hlavní verzi, kontejner se s daty
  starší verze nespustí (hláška `Error: in 18+, these Docker images are configured…` v `docker logs`) — vývojovou
  databázi založ znovu (`make down WEB=<web> PROFILE=postgres ARGS=-v`, schéma při dalším `make run` vytvoří
  migrace), nebo data převeď (`pg_upgrade`). Při připnutí na `postgres:17` a starší vrať mount na
  `/var/lib/postgresql/data`.
- **Pořadí startu:** compose na databázi nečeká (žádný `healthcheck` ani `depends_on`). Engine zkouší připojení
  `trayconnect`-krát po 1 s (`PWE_CONF_dbi_db1_trayconnect=10` v `docker-compose/docker-compose_common.env`);
  mezitím je v logu `[E] … Connect to <driver> dbid:db1 connect_status:0 error:… Can't connect to MySQL server…`
  (u PostgreSQL `… Connection refused`) a při souběžné migraci `[E] … Dbversion is locked by lockid:…` — obojí je
  při startu v pořádku. První start MySQL (zakládání datového adresáře, zhruba 8 s) se do limitu vejde těsně;
  trvá-li déle, proces `fcgi` skončí (`Unable connect to db1, poolid 0 bye...`), Docker ho restartuje
  (`restart: unless-stopped`) a napodruhé se připojí. Další starty nad existujícím volume znamenají zpravidla
  jeden neúspěšný pokus.

## nginx (`docker-compose/docker-compose_nginx.conf`)

Konfigurace je šablona expandovaná bashem při startu kontejneru (`${PWE_WEBAPP}` doplní
název webu; nginx proměnné jsou zapsané jako `\$uri`). Podstatné části:

```nginx
location ~ ^/(assets|static|uploadfile)/ {      # statika a nahrané soubory přímo z disku
    root /PWE/webapps/${PWE_WEBAPP};
    try_files \$uri @core_assets;
    expires 7d;
    access_log off;
}
location @core_assets { root /PWE/PWE; expires 7d; access_log off; }

location /debug.cgi {                           # ladění ve VS Code: do kontejneru debugger
    fastcgi_pass pwe_balancer_debug;
    fastcgi_param SCRIPT_FILENAME \$fastcgi_script_name;
    include fastcgi_params;
}
location / {                                    # vše ostatní do enginu
    fastcgi_pass pwe_balancer;
    fastcgi_param SCRIPT_FILENAME \$fastcgi_script_name;
    include fastcgi_params;
}

resolver 127.0.0.11 valid=5s ipv6=off;          # vestavěné DNS Dockeru
upstream pwe_balancer {
    zone pwe_balancer 64k;
    server pwe-fcgi-1:7779 max_fails=0 resolve;
    server pwe-fcgi-2:7779 max_fails=0 resolve;
    server pwe-fcgi-3:7779 max_fails=0 resolve;
}
upstream pwe_balancer_debug {
    zone pwe_balancer_debug 64k;
    server pwe-debugger-1:7779 resolve;
}
```

`@core_assets` je jen název nginx location („statika z kořene enginu“); její `root /PWE/PWE` je adresář
enginu v kontejneru, takže `/assets/…` se čte z `PWE/assets/` repozitáře (compose ho do `webproxy`
mountuje jako `/PWE/PWE/assets`).

**Adresy kontejnerů sleduje nginx průběžně.** Bez parametru `resolve` si nginx názvy `pwe-fcgi-N`
a `pwe-debugger-1` přeloží na IP adresy jen jednou při svém startu. Když compose kontejnery `fcgi`
nebo `debugger` vytvoří znovu (`make run` po `make images`, změna image nebo konfigurace služby),
dostanou jiné adresy — nginx pak posílal requesty na staré a `/debug.cgi` mohlo skončit u běžného
procesu `fcgi` místo u debuggeru. Proto mají upstreamy `resolve` se sdílenou zónou (`zone`)
a konfigurace `resolver 127.0.0.11` (DNS Dockeru, platnost odpovědi 5 s): nginx změnu adresy zachytí
do několika sekund bez restartu. Parametr `resolve` vyžaduje `zone` a `resolver` a v open-source
nginx je od verze 1.27.3 (compose používá `nginx:latest`).

Engine bere IP klienta výhradně z `REMOTE_ADDR` (`Libs::User::getIP`; `X-Forwarded-For` se nečte, protože
ji může podvrhnout klient). Běží-li nginx za další proxy, load balancerem nebo CDN, nastav mu skutečnou
adresu klienta modulem real_ip, jinak mají všichni klienti IP proxy a logika postavená na IP (zámek
přihlášení, logy) se rozbije:

```nginx
set_real_ip_from 10.0.0.0/8;          # adresy důvěryhodné proxy / LB
real_ip_header   X-Forwarded-For;
real_ip_recursive on;
```

V produkci nahraď `pwe-fcgi-N:7779` adresami svých procesů (nebo `unix:/cesta/pwe.sock`
s `FCGI_SOCKET_PATH=/cesta/pwe.sock`) a `root` cestami k webu a enginu. S pevnými IP adresami nebo
unix socketem `resolve`, `zone` ani `resolver` potřeba nejsou (`127.0.0.11` existuje jen v sítích
Dockeru — jinde uveď vlastní DNS).

S touto konfigurací nginx nikdy neservíruje `.pm`, `.conf`, `.tmpl` — ty leží mimo
`assets/`/`static/`. Bez ní servíruje statiku engine (`systemPage`, pomalejší, ale funkční).

## Apache

Apache s `mod_fcgid`/`mod_proxy_fcgi` předává requesty na socket enginu; adresář webu musí
obsahovat `.htaccess` (generátor ho vytváří), který zakazuje přímý přístup ke zdrojům:

```apache
<Files ~ "\.(pm|pl|log|tmpl|tmplc|bin|html|conf)$">
    Order Deny,Allow
    Deny from all
</Files>
```

Nadřazený `webapps/.htaccess` v repozitáři je `Deny from all`.

## Proměnné prostředí

Proměnné kontejneru (čte je engine a `entrypoint.sh`):

| Proměnná | Význam |
| --- | --- |
| `PWE_CONF_pwe_home` | adresář webu (povinné, když web neleží v adresáři enginu); zapečená je jen v image vlastního webu (spolu s `PWE_PROFILE`) |
| `PWE_CONF_pwe_core` | kořen enginu (`pwe.core`) = adresář `PWE/` s `pwe.fcgi`; výchozí je adresář skriptu `pwe.fcgi`; `pwe-base` a všechny image z něj mají zapečeno `/PWE/PWE` |
| `PWE_CONF_<sekce>_<klic>` | přepis libovolného klíče `web.conf` (`PWE_CONF_pwe_development=0`, `PWE_CONF_log_loglevel=1`, `PWE_CONF_web_admin_password=…`) |
| `PWE_CONF_dbi_<dbid>_<klic>` | přepis připojení k DB (`PWE_CONF_dbi_db1_host`, `_login`, `_password`, `_database`) |
| `FCGI_SOCKET_PATH` | `:7779` (TCP) nebo cesta k unix socketu; bez něj engine obslouží jeden request a skončí (CGI/cron režim); v žádném image zapečená není |
| `FCGI_DAEMONIZE` | odpojit od terminálu (mimo kontejnery) |
| `PWE_PROFILE` | pro `entrypoint.sh`: `mariadb`, `mysql` nebo `postgres` = který `conf/<profil>.conf` nalinkovat jako `conf/database.conf`; se `static` nebo bez ní se `conf/database.conf` nemění, neznámá hodnota vypíše varování ([Co je v `pwe-base`](#co-je-v-pwe-base)). Image vlastního webu ji má zapečenou (profil, pro který byl sestaven), službám `fcgi` a `debugger` ji předává compose |
| `TZ` | časové pásmo (např. `Europe/Prague`), ale jen pro start enginu — pro požadavky ho musí předat webserver (`fastcgi_param TZ`) nebo nastavit `/etc/localtime`, viz [Časové pásmo](#časové-pásmo). Databáze pásem (`tzdata`) je ve všech image |

Přepíše se jen klíč, který v konfiguraci existuje — tajné hodnoty (hesla DB, admin heslo, SMTP)
patří do prostředí/secretů, ne do souborů v gitu.

Proměnné hostitele (výběr image pro nástroje, compose a sestavení; podrobně
[Výběr image v nástrojích](#výběr-image-v-nástrojích)):

| Proměnná | Význam |
| --- | --- |
| `PWE_IMAGE_REGISTRY` | registr image, výchozí `ghcr.io/kukam` |
| `PWE_IMAGE_TAG` | tag image; nástroje ho odvodí z aktuální větve gitu, compose bez něj použije `master` |
| `PWE_TEST_IMAGE` | celý název image pro nástroje (`make test`, `compile`, `check`, `cgi`, …); výchozí `<registr>/pwe-debugger:<tag>` |
| `PWE_IMAGE_REGISTRIES`, `PWE_IMAGE_SOURCE` | jen pro `make images`: seznam registrů pro publikaci do více najednou a adresa repozitáře do popisku `source` ([Lokální sestavení](#lokální-sestavení)) |
| `PWE_WEBAPP`, `COMPOSE_PROFILES` | web a profil pro `docker compose` (nastavuje `make run`) |
| `PWE_TEST_LOCK_WAIT` | jak dlouho (sekundy, výchozí 600, `0` = vůbec) má `make test` čekat, když nad stejnou pracovní kopií už běží jiný běh testů ([18 — Testy](18-testy.md#testy-enginu)) |
| `KUBE_CONTEXT`, `K8S_*` | nasazení do Kubernetes (`make k8s-*`, [Kubernetes](#kubernetes)) |

## Kubernetes

Web se do Kubernetes nasazuje jako **image webu** (engine i web v jednom image, ze
`webapps/<web>/Dockerfile` — [Image vlastního webu](#image-vlastního-webu)) obecným chartem
`oci://registry.nixys.ru/nuc/nxs-universal-chart` verze **3.2.2**. Co se nasadí, popisuje soubor
hodnot `kubernetes/values-<název>.yml`; release se jmenuje `pwe-<název>` a web běží na
`https://pwe-<název>.<doména>`. V repozitáři jsou dvě hotová nasazení vzorových webů:

| Název | Web | Co se nasadí |
| --- | --- | --- |
| `static` (`kubernetes/values-static.yml`) | `webapps/example.web` (bez databáze) | Deployment s pody nginx + engine (`fcgi`), Service, Ingress s certifikátem z cert-manageru |
| `generic` (`kubernetes/values-generic.yml`) | `webapps/example-db.web` | totéž + MariaDB (StatefulSet se svazkem) a Secret s hesly (vzor `kubernetes/secrets-generic.example.yml`) |

Sestavení image webu, nasazení i kontrolu dělají cíle `make` (skript `PWE/tools/k8s.sh`):

```bash
make k8s-image    K8S=static     # sestaví image webu pro platformu clusteru a nahraje ho do registru
make k8s-template K8S=static     # vypíše manifesty, které by se nasadily (ke clusteru se nepřipojuje)
make k8s-deploy   K8S=static     # nasadí nebo aktualizuje release pwe-static (helm upgrade --install)
make k8s-status   K8S=static     # stav releasu
make k8s-test     K8S=static     # ověří web přes HTTPS
make k8s-logs     K8S=static     # logy kontejnerů releasu
make k8s-delete   K8S=static     # odinstaluje release (svazek databáze zůstává)
```

**Kontext clusteru je povinný a vždy výslovný.** Cílový cluster určuje `KUBE_CONTEXT` (v místním
souboru `kubernetes/local.env`, který není v gitu — vzor `kubernetes/local.env.example`, nebo jako
proměnná `make k8s-deploy K8S=static KUBE_CONTEXT=<kontext>`). Nemá výchozí hodnotu: skript **nikdy
nepoužije aktuální kontext `kubectl`** a každému příkazu `helm` i `kubectl` ho předává výslovně;
bez něj nic nenasadí. Stejně tak ruční příkazy: `kubectl` vždy s `--context <kontext>`, `helm` vždy
s `--kube-context <kontext>`.

Požadavky na cluster (ingress controller, cert-manager, DNS, třída úložiště, přístup k registru),
proměnné `K8S_*`, nasazení bez `make`, vlastní web, hesla, škálování a řešení potíží popisuje
[`kubernetes/README.md`](../kubernetes/README.md). Pro nasazení v Kubernetes platí totéž co pro image
webu jinde: konfigurace enginu přes `PWE_CONF_*` v `env` (přepíše se jen klíč, který v konfiguraci
webu existuje), `FCGI_SOCKET_PATH=:7779`, časové pásmo přes `fastcgi_param TZ` v nginx podu, tajné hodnoty a soukromé klíče
z Secretu, ne z image.

## Běh bez Dockeru

Engine potřebuje Perl s moduly ze stage `base` v `PWE/docker/Dockerfile` a DB ovladač ze stage
profilu (seznam balíčků: [Co je v `pwe-base`](#co-je-v-pwe-base); přes CPAN `cpanm CGI::Fast
Class::Inspector Template JSON DBI DBD::mysql DBD::Pg Mail::RFC822::Address Cz::Cstocs …`), pro
`Libs::Pics` a stránku `css` navíc programy `identify`, `convert` a `sass`. Spuštění:

```bash
cd /srv/webapps/<web>
PWE_CONF_pwe_home=$PWD/ PWE_CONF_pwe_core=/srv/PWE/PWE/ FCGI_SOCKET_PATH=/run/pwe/<web>.sock perl /srv/PWE/PWE/pwe.fcgi
```

(pod `systemd` jako služba; socket pak do nginx `upstream`). `FCGI_DAEMONIZE=1` odpojí proces od
terminálu. V příkladu je `/srv/PWE` klon repozitáře a `/srv/PWE/PWE/` adresář enginu v něm; web může
ležet kdekoli (zde `/srv/webapps/<web>`), engine ho najde přes `PWE_CONF_pwe_home`.

## Produkční checklist

- [ ] `pwe.development => 0` (žádný DataDump, žádná vývojová skupina `admin`)
- [ ] unikátní `http.cookie_name`, správný `http.base_url`, `web.email_admin`, `pwe.smtp_servers`
- [ ] hesla přes `PWE_CONF_*` (DB, admin, SMTP: `PWE_CONF_smtp_primary_authpw`), ne v `conf/*`; e-mail ověřit `make smtp-test`
- [ ] soukromé klíče (platební brána, klientské certifikáty) kontejner dostává mountem nebo secretem
      a cestu přes `PWE_CONF_*` — do image webu se z `conf/` nezapékají
      ([Image vlastního webu](#image-vlastního-webu))
- [ ] `log.loglevel => 1`, `logout => "STDERR"` (sbírá Docker/k8s) nebo soubor s rotací
- [ ] ukázkové stránky enginu (`formExamples`, `ajaxExamples`, `responsive`) mimo `core_pages`;
      `pweCreator` jen pro skupinu `admin` (nebo také odebrat)
- [ ] statiku servíruje webserver (`assets/`, `static/`), zdroje webu nejsou dostupné přes HTTP
- [ ] image webu sestavený z aktuální šablony `Dockerfile` ([Image vlastního webu](#image-vlastního-webu)):
      běh z `pwe-<profil>`, engine z `pwe` připnutý na verzi (`--build-arg PWE_ENGINE_TAG=<verze>`;
      tag verze je přepisovatelný — kdo potřebuje přesně jeden kód, připne digest,
      [Registr a tagy](#registr-a-tagy)); image webu má vlastní neměnný tag, ne název větve
      (nebo se nasazuje podle digestu jako u `make k8s-deploy`); web nemá vlastní `entrypoint.sh`
      a popisky `source`/`licenses` v `Dockerfile` jsou doplněné
- [ ] časové pásmo pro požadavky: `fastcgi_param TZ` ve webserveru nebo `/etc/localtime` v kontejneru (samotná proměnná `TZ` platí jen při startu, jinak UTC)
- [ ] `pwe.require_core` odpovídá verzi enginu v image
- [ ] v produkci neběží `pwe-debugger` (ladicí nástroje, překladač, klienti databází) a kontejner
      nemá namountovaný repozitář
- [ ] registr s image webu je z produkce dostupný (soukromý registr: `docker login` /
      `imagePullSecrets`)
- [ ] migrace `dbversion` prošly (log při startu), záloha DB před nasazením nové verze
- [ ] HTTPS před nginx (cookie dostane prefix `C1`; po změně schématu se session založí znovu)
- [ ] `make check WEB=<web>` bez `FAIL`, průchod stránek bez `[E]` v logu

## Aktualizace enginu

1. V repozitáři enginu přejdi na novou verzi (`PWE/VERSION`, `PWE/CHANGELOG.md` popisuje
   změny; major = změna kontraktu).
2. Ve webu zkontroluj `pwe.require_core`, spusť `make check WEB=<web>` a projdi stránky
   (`make run`).
3. Sestav nový image webu s novým enginem (`docker build --build-arg PWE_ENGINE_TAG=<nová verze> …`,
   [Image vlastního webu](#image-vlastního-webu)) a nasaď.

Web má vlastní git; verzi enginu, se kterou byl ověřen, drží v `pwe.require_core`.

### Přechod z rozložení s adresářem `core/`

Do verze 2.1.0 se adresář enginu jmenoval `core/` (v kontejneru `/PWE/core`), od 2.2.0 je to `PWE/`
(v kontejneru `/PWE/PWE`). Mění se jen cesty; existující web a nasazení je potřeba upravit ručně:

- `Dockerfile` webu: `CMD ["perl", "/PWE/PWE/pwe.fcgi"]` a engine v `/PWE/PWE` — nejjednodušší je
  převzít aktuální šablonu ([Image vlastního webu](#image-vlastního-webu)), která zároveň řeší
  [nové uspořádání image](#přechod-ze-starého-uspořádání-image);
- soubor `vars` webu: `PERL5LIB="$(pwd):/PWE/PWE"`, `PWE_CONF_pwe_core=/PWE/PWE/`;
- nginx: `root /PWE/PWE` pro statiku enginu; vlastní compose/Kubernetes manifesty: `command`,
  `PWE_CONF_pwe_core`, mount `PWE/assets` → `/PWE/PWE/assets`;
- cron úlohy, CI a skripty: `perl /PWE/PWE/pwe.fcgi`, `PWE/tools/*`, `PWE/t/` (nebo `make`);
- image: historické `kukam/pwe-*` z Docker Hubu (engine v `/PWE/core`, zapečené
  `PWE_CONF_pwe_core=/PWE/core`) nahradit dnešními `ghcr.io/kukam/pwe-*` a image webu sestavit znovu
  (oddíl [Image](#image)).

Názvy klíčů v `conf/web.conf` se nemění: `pwe.core_pages`, `core_sites`, `core_services`, `core_entities`,
`pwe.require_core` ani název proměnné `PWE_CONF_pwe_core` se nepřejmenovaly („core“ v nich znamená
kořen enginu, ne název adresáře). Web, který už používá cesty `/PWE/PWE`, má mít
`pwe.require_core => ">=2.2"` — rozložení s `/PWE/PWE` platí až od enginu 2.2.0 a stejnou hodnotu
zapisuje do nového webu generátor (`make new`). Podrobně [`PWE/CHANGELOG.md`](../PWE/CHANGELOG.md).
