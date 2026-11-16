# 17 — Nasazení

PWE běží jako FastCGI proces v kontejneru; před ním stojí webserver, který předává requesty
a servíruje statiku. Tato kapitola popisuje image (co obsahují, jak se staví a publikují
a jak z nich vzniká image webu), vývojový compose stack, nginx, Apache, proměnné prostředí, běh
procesu enginu (FastCGI socket, ukončení signálem, migrace při startu), Kubernetes a produkční
checklist.

Cesty: `PWE/…` znamená adresář enginu `PWE/` v kořeni repozitáře (na hostiteli, relativně ke kořeni
repozitáře). V image a v kontejnerech leží repozitář v `/PWE`, engine je tam proto v **`/PWE/PWE`**
a weby ve `/PWE/webapps/<web>`.

## Image

PWE se dodává jako **devět image** dvou druhů. Publikuje je pipeline GitHub Actions do registru
**`ghcr.io/kukam`** (GitHub Container Registry) a každý má právě dva tagy: **`<verze>`** (obsah
`PWE/VERSION`, dnes `2.2.1`) a **`latest`** — tagy podle větve gitu neexistují
([Registr a tagy](#registr-a-tagy)).

- **Závislostní image** (pět) nesou jen závislosti: Perl, knihovny enginu, případně ovladač databáze
  a vstupní skript. **Kód enginu ani žádný web v nich není** — `/PWE/PWE` neexistuje a `/PWE/webapps`
  je prázdný. Staví se z jednoho vícestupňového `PWE/docker/Dockerfile` (jeden stage = jeden image)
  a všechny vycházejí z `pwe-base`.
- **Image vzorových webů** (čtyři) = závislostní image + engine + vzorový web. Staví je přímo
  `Dockerfile` vzorového webu (`webapps/example.web/Dockerfile`, `webapps/example-db.web/Dockerfile`) —
  tatáž šablona, jakou má každý jiný web ([Image vlastního webu](#image-vlastního-webu)). Jsou samy
  spustitelné a slouží jako ukázka ([Image vzorových webů](#image-vzorových-webů)).

Cíle sestavení a tagy všech devíti image určuje `docker-bake.hcl` v kořeni repozitáře.

| Image | Vychází z | Obsah | K čemu |
| --- | --- | --- | --- |
| `pwe-base` | `ubuntu:26.04` | běhové knihovny enginu a `entrypoint.sh`; bez DB ovladačů, bez ladicích a build nástrojů | společný základ ostatních image; základ image webu **bez databáze** a image služby `fcgi` vývojového stacku s profilem `static`; pipeline v něm pouští testy enginu |
| `pwe-mariadb` | `pwe-base` | + `DBD::mysql`, `DBD::MariaDB` | základ image webu s MariaDB; služba `fcgi` stacku s profilem `mariadb` |
| `pwe-mysql` | `pwe-base` | + `DBD::mysql` | totéž pro MySQL |
| `pwe-postgres` | `pwe-base` | + `DBD::Pg` | totéž pro PostgreSQL |
| `pwe-debugger` | `pwe-base` | + všechny tři DB ovladače + ladicí nástroje | služba `debugger` (VS Code) a výchozí image nástrojů (`make test`, `compile`, `check`, `cgi`, …) |
| `pwe-example-static` | `pwe-base` | + engine + vzorový web `webapps/example.web` (`PWE_PROFILE=static`) | spustitelná ukázka webu bez databáze; vzorové nasazení `static` v Kubernetes |
| `pwe-example-mariadb` | `pwe-mariadb` | + engine + vzorový web `webapps/example-db.web` (`PWE_PROFILE=mariadb`) | spustitelná ukázka webu s MariaDB; vzorové nasazení `generic` v Kubernetes |
| `pwe-example-mysql` | `pwe-mysql` | + engine + `webapps/example-db.web` (`PWE_PROFILE=mysql`) | totéž pro MySQL |
| `pwe-example-postgres` | `pwe-postgres` | + engine + `webapps/example-db.web` (`PWE_PROFILE=postgres`) | totéž pro PostgreSQL |

```text
ubuntu:26.04
└── pwe-base                  běhové knihovny enginu + entrypoint.sh
    ├── pwe-mariadb           + DBD::mysql, DBD::MariaDB
    ├── pwe-mysql             + DBD::mysql
    ├── pwe-postgres          + DBD::Pg
    └── pwe-debugger          + všechny DB ovladače + ladicí nástroje

image webu            = pwe-base (bez databáze) | pwe-<profil>  +  engine (PWE/ z repozitáře)  +  webapps/<web>
pwe-example-static    = pwe-base                                +  engine                      +  webapps/example.web
pwe-example-<profil>  = pwe-<profil>                            +  engine                      +  webapps/example-db.web
```

Kde je kód enginu:

- **V žádném závislostním image.** Nástroje (`make test`, `check`, `cgi`, …), ladění i vývojový stack
  běží nad repozitářem namountovaným do `/PWE`, tedy nad pracovní kopií enginu.
- **V image webu — vlastního i vzorového.** `Dockerfile` webu kopíruje engine z kontextu sestavení
  (kořen repozitáře): `/PWE/LICENSE` a do `/PWE/PWE` soubory `pwe.fcgi`, `debug.cgi`, `VERSION`,
  `favicon.ico`, `README.md`, `CHANGELOG.md` a adresáře `Libs/`, `Pages/`, `Sites/`, `Services/`,
  `Entities/`, `templates/`, `assets/`, `tools/`. Testy (`PWE/t`) a `PWE/docker` se do image nekopírují.
  Verzi enginu v image proto určuje **pracovní kopie v okamžiku sestavení** (v image soubor
  `/PWE/PWE/VERSION`), ne tag základního image.

Samostatný image `pwe` (jen engine) a image `pwe-static` z verze 2.2.0 **byly zrušeny**: engine se do
image webu kopíruje z repozitáře a web bez databáze běží nad `pwe-base`
([Přechod z tagů podle větve](#přechod-z-tagů-podle-větve)).

### Image vzorových webů

`pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql` a `pwe-example-postgres` jsou image webu
jako každý jiný, sestavené `Dockerfile` vzorového webu nad závislostním image téhož tagu:

- engine je v `/PWE/PWE`, vzorový web ve `/PWE/webapps/example.web` (`pwe-example-static`), resp.
  `/PWE/webapps/example-db.web` (`pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres`);
- zapečené mají `ENV PWE_CONF_pwe_home=/PWE/webapps/<vzorový web>` a `PWE_PROFILE=<profil>`, `WORKDIR`
  je adresář vzorového webu a výchozí příkaz `CMD ["perl", "/PWE/PWE/pwe.fcgi"]`; `ENTRYPOINT` dědí
  z `pwe-base`;
- pracovní adresáře (`ramdisk/templates`, `sessions`, `uploadfile`, `log`) a u databázových profilů
  symlink `conf/database.conf` → `<profil>.conf` vznikají už při sestavení.

**Jsou to ukázky, nejsou určené pro veřejný provoz.** Vzorové weby běží ve vývojovém režimu
(`pwe.development => 1`): **každý návštěvník je ve skupině `admin`** a má tak přístup i ke generátoru
kódu `pweCreator`. Při startu serveru (s `FCGI_SOCKET_PATH`) na to vstupní skript upozorní:

```text
[entrypoint] VAROVANI: bezi vzorovy web example.web zapeceny v image (ukazka: kazdy navstevnik ma skupinu admin vcetne generatoru kodu pweCreator) - neni urcen pro verejny provoz; image vlastniho webu stav podle webapps/<web>/Dockerfile
```

Pro vlastní provoz sestav image vlastního webu ([Image vlastního webu](#image-vlastního-webu)).

```bash
# jeden request v režimu CGI: bez FCGI_SOCKET_PATH engine obslouží request z prostředí a skončí
docker run --rm -e REQUEST_METHOD=GET -e QUERY_STRING='page=default&func=default' -e SCRIPT_FILENAME=/pwe.fcgi \
    ghcr.io/kukam/pwe-example-static:latest

# FastCGI server na portu 7779 (webserver před něj dodá nasazení)
docker run --rm -e FCGI_SOCKET_PATH=:7779 ghcr.io/kukam/pwe-example-static:latest
```

Databázové profily potřebují databázi: vzorový web ji podle `conf/<profil>.conf` hledá na hostu
jménem profilu (`mariadb`, `mysql`, `postgres`), databáze, uživatel i heslo `pwe` — jinou adresu
a přihlášení předej přes `PWE_CONF_dbi_db1_host`, `_login`, `_password` a `_database`. Bez dostupné
databáze engine po vyčerpání pokusů skončí hláškou `Unable connect to db1, poolid 0 bye...`.

S kořenovým souborovým systémem jen pro čtení (`docker run --read-only`) musí být pracovní adresáře
webu zapisovatelné (`--tmpfs` přes `ramdisk`, `sessions`, `uploadfile` a `log`) — bez zapisovatelného
`ramdisk` engine neobslouží ani jeden request.

Kde se které image používají:

- **image vlastního webu** vychází ze závislostního image (`pwe-base`, nebo `pwe-<profil>`) a engine
  i web do něj kopíruje z repozitáře ([Image vlastního webu](#image-vlastního-webu));
- **vývojový stack** (`make run`) pouští službu `fcgi` v závislostním image profilu (`static` =
  `pwe-base`) a mountuje do něj kořen repozitáře do `/PWE`: běží pracovní kopie enginu i webu a který
  web běží, určuje `working_dir` a `PWE_CONF_pwe_home` služby v `docker-compose.yml`
  ([Vývojový stack](#vývojový-stack-docker-composeyml));
- **vzorová nasazení v Kubernetes** (`static`, `generic`) nasazují přímo `pwe-example-static`
  a `pwe-example-mariadb`, bez sestavování dalšího image ([Kubernetes](#kubernetes)).

Vrstvy image webu jdou v pořadí závislostní image → engine → web → pracovní adresáře. Engine i web se
kopírují přes `COPY --link` (vyžaduje BuildKit, tedy Docker Engine 23 a novější): vrstva nezávisí na
vrstvách pod sebou, takže ji změna základu nezneplatní a image webů nad stejným enginem ji sdílejí —
čtyři image vzorových webů mají vrstvy enginu v registru uložené jednou. Závislostní image se se změnou
kódu enginu ani webu nemění (z kontextu sestavení berou jen `PWE/docker/entrypoint.sh`); jejich digest
se mění jen se závislostmi.

`pwe-debugger` má navíc `Perl::LanguageServer` z balíčku Ubuntu `libperl-languageserver-perl` (dnes
verze 2.6.2; sestavení hlídá, že neklesne pod 2.6.2 — verzi rozšíření VS Code,
[16 — Nástroje](16-nastroje.md#debugger-ve-vs-code)) včetně jeho závislostí (`IO::AIO`, `Coro`,
`AnyEvent`, …), `perlcritic` (`Perl::Critic`), `perltidy` (`Perl::Tidy`), `perldoc` (`perl-doc`),
`cpanm` s překladačem (`build-essential`) pro doinstalování modulů z CPAN při ladění, klienty
`mariadb`/`mysql` a `psql`, `curl`, `ping`, `netstat`/`ifconfig`, `telnet`, `ps`/`pkill`, `less`
a FastCGI klienta `cgi-fcgi`. `curl` je jen tady — v běhových image není. `cpanm` stahuje index
i archivy z CPAN jen přes HTTPS (`ENV PERL_CPANM_OPT="--from https://www.cpan.org/"`; `cpanm`
z Ubuntu by jinak stahoval nešifrovaně z `http://www.cpan.org`). V tomto režimu nejde verzi modulu
připnout zápisem `cpanm Modul@1.50` (index zrcadla zná jen nejnovější verzi; skončí chybou
`doesn't satisfy == 1.50`) — určitou verzi nainstaluje úplná adresa archivu:
`cpanm https://cpan.metacpan.org/authors/id/A/AU/AUTOR/Dist-1.50.tar.gz`. Do produkce nepatří.

Závislostní image se staví **jen z balíčků Ubuntu** (`apt`) a image vzorových webů k nim přidávají
jen soubory z repozitáře: `cpanm` se při sestavení nespouští, takže sestavení nezávisí na dostupnosti
CPAN a projde i v emulaci jiné platformy (`linux/arm64` v pipeline).

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
Všechny odvozené image to dědí — `pwe-mariadb`, `pwe-mysql`, `pwe-postgres`, `pwe-debugger` i image
webu; image webu (vlastního i vzorového) k tomu přidává `PWE_CONF_pwe_home`, `PWE_PROFILE` a `WORKDIR`
svého webu.

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

**Kontroly při sestavení.** Každý stage závislostních image si svůj obsah ověří sám — chybějící balíček
tak shodí už sestavení, ne až provoz:

| Stage | Co sestavení ověří |
| --- | --- |
| `base` | existují `/usr/bin/sass`, `/usr/bin/identify` a `/usr/bin/convert` (engine je volá pevnou cestou; v ImageMagick 7 jsou `identify` a `convert` jen alternativy k `magick`), `/usr/bin/openssl` a `/usr/share/zoneinfo/Europe/Prague` (databáze časových pásem) a jdou načíst `CGI::Fast`, `Template`, `Class::Inspector`, `Class::MOP`, `JSON`, `JSON::XS`, `DBI`, `Mail::RFC822::Address`, `Cz::Cstocs`, `LWP::MediaTypes`, `IO::Socket::SSL`, `Authen::SASL`, `Image::Magick`, `Crypt::OpenSSL::RSA`, `URI` a `HTML::Parser` |
| `mariadb`, `mysql`, `postgres` | jde načíst ovladač profilu (`DBD::mysql` + `DBD::MariaDB`, `DBD::mysql`, `DBD::Pg`) |
| `debugger` | `Perl::LanguageServer` má aspoň verzi z argumentu `PERL_LANGUAGESERVER_MIN` (výchozí 2.6.2), jdou načíst `Perl::LanguageServer::DebuggerBridge`, všechny tři DB ovladače, `Perl::Critic` a `Perl::Tidy` a existuje `/usr/bin/curl` |

`Dockerfile` webu (i vzorového) při sestavení nic neověřuje: zkopíruje engine a web a založí pracovní
adresáře a symlink `conf/database.conf` (jen když web má `conf/<profil>.conf`; běžný soubor
`conf/database.conf` nepřepíše). Že image vzorových webů obsahují to, co mají, a že jejich popisek
`version` odpovídá souboru `/PWE/PWE/VERSION` v image, ověřují
[kouřové kontroly](#kouřové-kontroly-image) — pipeline je pouští před publikací.

**Popisky image** (`org.opencontainers.image.*`; výpis: `docker image inspect --format '{{json .Config.Labels}}' <image>`):

| Popisek | Závislostní image | Image vzorových webů |
| --- | --- | --- |
| `title` | název image (`pwe-base`, `pwe-mariadb`, …) | název image (`pwe-example-static`, …) |
| `description` | jednořádkový popis | jednořádkový popis včetně upozornění, že jde o ukázku |
| `source` | adresa repozitáře (výchozí `https://github.com/kukam/PWE`; podle ní GitHub přiřadí balíček k repozitáři — u víceplatformního image z anotace indexu se stejnou hodnotou, viz [Pipeline](#pipeline-github-actions)) | totéž |
| `licenses` | `Apache-2.0` | `Apache-2.0` |
| `base.name` | základní image Ubuntu: `ubuntu:26.04` u místního sestavení, `ubuntu:26.04@sha256:<digest>` u image z pipeline (ta základ připíná na digest) | závislostní image, ze kterého vychází: `<registr>/pwe-base:<verze>`, resp. `<registr>/pwe-<profil>:<verze>` |
| `version` | prázdný — engine neobsahují | obsah `PWE/VERSION` |
| `created` | prázdný | čas sestavení (RFC 3339); vyplňuje ho pipeline i `make images` |
| `revision` | není | commit, ze kterého engine a web v image pocházejí — jen když je znám: pipeline ho vyplňuje vždy, `make images` jen z čisté pracovní kopie |

Popisky `version` a `created` zděděné z image Ubuntu se v závislostních image vyprazdňují, aby o image
PWE netvrdily nepravdu. Verzi enginu, čas sestavení a commit mají záměrně **jen image vzorových webů**
(doplňuje je `docker-bake.hcl`; `Dockerfile` vzorového webu sám má `title` = název webu a `version`,
`source` a `licenses` prázdné jako u každého webu): závislostní image engine neobsahují a jejich digest
se tak mění jen se závislostmi, `PWE/docker/Dockerfile` a `PWE/docker/entrypoint.sh`, ne s každým
commitem. Image vlastního webu si popisky nastavuje sám ([Image vlastního webu](#image-vlastního-webu)).

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

Start se **nikdy nepřeruší**. Když ale `PWE_PROFILE` neodpovídá stavu webu nebo image, vypíše skript
na standardní chybový výstup jednořádkové varování (`<stav>` je `conf/database.conf ukazuje na <cíl>`,
`conf/database.conf je bezny soubor` nebo `conf/database.conf neexistuje`):

| Situace | Varování |
| --- | --- |
| neznámá hodnota (překlep, velká písmena) | `[entrypoint] VAROVANI: neznamy PWE_PROFILE='<hodnota>' (platne hodnoty: static, mariadb, mysql, postgres) - conf/database.conf se nenastavuje (<stav>)` |
| databázový profil, ale web nemá `conf/<profil>.conf` (typicky web bez databáze spuštěný s profilem `mariadb`) | `[entrypoint] VAROVANI: PWE_PROFILE=<profil>, ale conf/<profil>.conf neexistuje - conf/database.conf se nenastavuje (<stav>)` |
| symlink se nepodařilo nastavit a na profil neukazuje (`conf/` jen pro čtení) | `[entrypoint] VAROVANI: conf/database.conf se nepodarilo nasmerovat na <profil>.conf (PWE_PROFILE=<profil>; neni adresar conf/ jen pro cteni?) - <stav>` |
| profil `static`, ale v `conf/` zůstal symlink `database.conf` | `[entrypoint] VAROVANI: PWE_PROFILE=static, ale conf/database.conf ukazuje na <cíl> - symlink zustava a engine nacte databazovou konfiguraci jineho profilu` |
| `conf/database.conf` ukazuje na konfiguraci profilu, ale image nemá jeho ovladač databáze (např. `-e PWE_PROFILE=postgres` v image z `pwe-mariadb`, nebo databázový profil v image z `pwe-base`) | `[entrypoint] VAROVANI: PWE_PROFILE=<profil>, ale image nema ovladac databaze <ovladač> (maji ho <image>) - engine se k databazi nepripoji` |
| jako server (je nastavená `FCGI_SOCKET_PATH`) se spouští vzorový web zapečený v image — `pwe-example-*` nebo jiný image sestavený `Dockerfile` vzorového webu | `[entrypoint] VAROVANI: bezi vzorovy web <web> zapeceny v image (ukazka: kazdy navstevnik ma skupinu admin vcetne generatoru kodu pweCreator) - neni urcen pro verejny provoz; image vlastniho webu stav podle webapps/<web>/Dockerfile` |

Ovladač se ověřuje příkazem `perl -M<ovladač> -e 1`: profily `mariadb` a `mysql` potřebují `DBD::mysql`
(mají ho `pwe-mariadb`, `pwe-mysql` a `pwe-debugger`), profil `postgres` `DBD::Pg` (`pwe-postgres`
a `pwe-debugger`). Kontroluje se jen tehdy, když `conf/database.conf` je symlink na `<profil>.conf` —
u vlastní konfigurace webu (běžný soubor) ne.

Poslední varování se profilu netýká: upozorňuje, že jako server běží **vzorový web** — ukázka, ve
které je každý návštěvník ve skupině `admin` ([Image vzorových webů](#image-vzorových-webů)). Vzorový
web se pozná bez zvláštní značky v image: adresář webu se jmenuje `example.web` nebo `example-db.web`
a engine je zapečený v image — v kořeni enginu (`PWE_CONF_pwe_core`) je `pwe.fcgi` a **není** tam
`docker/entrypoint.sh` (šablona `Dockerfile` webu adresář `PWE/docker` nekopíruje, pracovní kopie ho má
vždy). Ve vývojovém stacku a v nástrojích (repozitář namountovaný do `/PWE`), při jednorázovém requestu
v režimu CGI (bez `FCGI_SOCKET_PATH`) a u jiných příkazů se proto nevypisuje. Vlastní web pojmenovaný
`example.web` nebo `example-db.web` by ho dostal také — tato jména patří vzorovým webům.

Bez varování proběhne start s prázdným nebo chybějícím `PWE_PROFILE`, s běžným souborem
`conf/database.conf` (ten se nikdy nepřepisuje), se symlinkem, který už na profil ukazuje (a image
ovladač profilu má), a mimo adresář webu.

**V `pwe-base` není:** kód enginu, DB ovladače (`DBD::*` — jsou v `pwe-mariadb`, `pwe-mysql`,
`pwe-postgres` a `pwe-debugger`), ladicí a build
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
| databáze | `DBI`; **ovladače jen v závislostních image profilu**: `DBD::mysql` (`pwe-mariadb`, `pwe-mysql`), `DBD::MariaDB` (`pwe-mariadb`), `DBD::Pg` (`pwe-postgres`); `pwe-base` nemá žádný, `pwe-debugger` všechny tři |
| síť | `HTTP::Tiny` (jádro) + `IO::Socket::SSL`/`Net::SSLeay` = HTTPS klient, `URI`, `Net::SMTP` (+ `Authen::SASL` pro přihlášení k SMTP) |
| kryptografie | `Digest::SHA`, `Digest::MD5`, `MIME::Base64`, `Crypt::OpenSSL::RSA`, CLI `openssl` |
| e-mail, texty | `Mail::RFC822::Address`, `Cz::Cstocs` (+ CLI `cstocs`), `LWP::MediaTypes`, `Encode`, `HTML::Entities`, `URI::Escape` |
| soubory, obrázky | `Storable`, `Image::Magick`, CLI ImageMagick `/usr/bin/identify` a `/usr/bin/convert` (používá je `Libs::Pics`), CLI `sass` |
| čas, identifikátory | `Time::Piece`, `POSIX`, databáze časových pásem (`tzdata`, proměnná `TZ`) |

Engine se k MariaDB i MySQL připojuje přes `DBD::mysql` (`dbdriver => "mariadb"` i `"mysql"`);
`DBD::MariaDB` je v `pwe-mariadb` navíc pro kód webu. HTTPS API volá kód webu přes `HTTP::Tiny`
(tak to dělá e-shop); `LWP::UserAgent`, `Data::UUID`, `Data::GUID`, `Crypt::OpenSSL::X509`
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

(řádek `RUN` patří za `FROM` a jeho řádky `ARG` v šabloně z oddílu
[Image vlastního webu](#image-vlastního-webu), před první `COPY --link` s enginem — vrstva s balíčky se
pak při změně enginu ani webu nestaví znovu; web bez databáze má na řádku `FROM` základ `pwe-base`).
Názvy balíčků Ubuntu: `LWP::UserAgent` = `libwww-perl`, HTTPS pro
něj `liblwp-protocol-https-perl`, `Data::UUID` = `libdata-uuid-perl`, `Data::GUID` =
`libdata-guid-perl`, `Crypt::OpenSSL::X509` = `libcrypt-openssl-x509-perl`, program `curl` = `curl`.
Ve vývojovém stacku web běží v závislostním image profilu (`pwe-<profil>`, u profilu `static` `pwe-base`)
a v `pwe-debugger`, ne v image webu; aby tam knihovna byla také, sestav si z nich odvozené image pod vlastním tagem a tag předej stacku:

```bash
for image in pwe-mariadb pwe-debugger; do
    printf 'FROM %s\nRUN apt-get update && apt-get install -y --no-install-recommends libtext-csv-perl && rm -rf /var/lib/apt/lists/*\n' \
        "$(bash PWE/tools/lib/images.sh pwe_image "$image")" \
        | docker build -t "$(bash PWE/tools/lib/images.sh pwe_image_registry)/$image:mujweb" -
done
PWE_IMAGE_TAG=mujweb make run WEB=mujweb.web PROFILE=mariadb
```

Základem (`FROM`) je závislostní image s tagem verze enginu v pracovní kopii — tentýž, který by použil `make run`
(`bash PWE/tools/lib/images.sh pwe_image pwe-mariadb` → `ghcr.io/kukam/pwe-mariadb:<verze>`): místní
z `make images`, jinak ho Docker stáhne z registru. Když image této verze nemáš místně ani v registru,
nastav před smyčkou `export PWE_IMAGE_TAG=latest` (a po ní `unset PWE_IMAGE_TAG`).
`PWE_IMAGE_TAG=mujweb` nastav až u `make run`, ne dřív — jinak by `FROM` ukazoval sám na sebe.
Prostý `docker build` místní image vidí;
kdo místo něj volá `docker buildx build` (nebo má nastavenou proměnnou `BUILDX_BUILDER` či alias
z `docker buildx install`), přidá `--builder <builder s ovladačem docker> --load`
([Image vlastního webu](#image-vlastního-webu)).

Do `pwe-base` (stage `base` v `PWE/docker/Dockerfile`) patří jen knihovna, bez které neběží **engine**;
ladicí nástroj patří do stage `debugger`, DB ovladač do stage profilu. Kód enginu ani web do
`PWE/docker/Dockerfile` nepatří. Po změně `make images` a `make images-check`.

### Registr a tagy

- **Registr:** `ghcr.io/kukam` — celé názvy jsou `ghcr.io/kukam/pwe-base`, `ghcr.io/kukam/pwe-mariadb`,
  …, `ghcr.io/kukam/pwe-example-static`, …
- **Každý image má právě dva tagy:** `<verze>` = obsah `PWE/VERSION` (tvar `X.Y.Z`, dnes `2.2.1`)
  a `latest` — např. `ghcr.io/kukam/pwe-mariadb:2.2.1` a `ghcr.io/kukam/pwe-mariadb:latest`. V okamžiku
  publikace ukazují oba na tentýž image (index platforem `linux/amd64` a `linux/arm64`). Pravidlo je
  na jednom místě (funkce `image_tags` v `docker-bake.hcl`) a pipeline ho před sestavením ověřuje.
- **Tagy podle větve gitu neexistují** — žádné `master`, `pwe.ai` ani `pr-<číslo>`; název větve do
  jména image nevstupuje. Která větev smí publikovat, rozhoduje pipeline (výchozí větev repozitáře
  a větve z proměnné `PUBLISH_BRANCHES`, [Pipeline GitHub Actions](#pipeline-github-actions)), ne jméno
  tagu. Tagy podle větve z verze 2.2.0 (`…:pwe.ai`) a balíčky zrušených image `pwe` a `pwe-static`,
  které v registru zůstaly, už nic neaktualizuje a pipeline je nemaže — smaž je ručně v nastavení
  balíčků.
- **Oba tagy se přepisují.** `latest` ukazuje na naposledy publikované image, `<verze>` na naposledy
  publikované image s touto hodnotou `PWE/VERSION` — každá další publikace (i místní `make images`
  v místním Dockeru) ho přepíše, dokud se verze nezvýší. Všechny publikující větve píší **stejné**
  tagy: platí image z běhu, který publikoval naposled, bez ohledu na větev, a běh z větve s nižší
  `PWE/VERSION` vrátí `latest` na starší verzi. Tag verze tedy říká „image pro engine této verze“, ne
  „tento konkrétní kód“.
- **Jednoznačně kód určuje jen digest nebo popisek commitu.** Kdo potřebuje přesně jeden neměnný
  obsah, odkáže se na digest (`ghcr.io/kukam/pwe-mariadb@sha256:…`; vypisuje ho souhrn běhu pipeline,
  u staženého image `docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/kukam/pwe-mariadb:<tag>`).
  Z jakého commitu engine a vzorový web pocházejí, říká popisek image vzorového webu:
  `docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/kukam/pwe-example-static:<tag>`
  (pipeline ho vyplňuje vždy, lokální sestavení jen z čisté pracovní kopie; závislostní image popisek
  nemají — kód enginu neobsahují).
- **Který tag kde platí jako výchozí:** nástroje (`make test`, `check`, `cgi`, `run`, …) berou
  `<verze>` z pracovní kopie, přímé `docker compose up` a `Dockerfile` webu `latest`. Pro produkci
  připni závislostní image, nad kterým image webu stavíš, na verzi (`--build-arg PWE_IMAGE_TAG=<verze>`),
  případně na digest.
- **Nová verze = zvýšení `PWE/VERSION`.** Image s novým tagem pak v místním Dockeru nejsou, dokud
  neproběhne `make images`, a v registru, dokud je pipeline nepublikuje; do té doby poslouží
  `PWE_IMAGE_TAG=latest` nebo předchozí verze. `PWE/VERSION` musí mít tvar `X.Y.Z` (tři čísla) —
  příponu jako `2.3.0-rc1` nástroje, `make images`, `docker-bake.hcl` ani pipeline nepřijmou.

### Výběr image v nástrojích

Nástroje v `PWE/tools/` i compose skládají název image ze dvou proměnných prostředí (funkce
v `PWE/tools/lib/images.sh`):

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr (fork: `ghcr.io/<vlastník>`, zrcadlo: `docker.io/<jmenný prostor>`) |
| `PWE_IMAGE_TAG` | verze enginu z `PWE/VERSION` (na gitu ani na větvi nezávisí) | tag všech image, typicky `latest` nebo starší verze; musí to být platný tag image (znaky `A–Z a–z 0–9 _ . -`, nezačíná tečkou ani pomlčkou, nejvýše 128 znaků), jinak nástroje skončí chybou |
| `PWE_TEST_IMAGE` | `<registr>/pwe-debugger:<tag>` | úplné přepsání image nástrojů (`make test`, `compile`, `check`, `cgi`, `module`, `smtp-test`); tag se pak nezjišťuje ani nekontroluje; stack (`make run`) neovlivní |

```bash
make test                                                        # ghcr.io/kukam/pwe-debugger:<verze>
PWE_IMAGE_TAG=latest make test                                   # image s tagem latest (naposledy publikovaný nebo sestavený)
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:latest make test           # testy v jiném image (CI je pouští v pwe-base)
PWE_IMAGE_REGISTRY=ghcr.io/nekdo PWE_IMAGE_TAG=latest make run WEB=mujweb.web
bash PWE/tools/lib/images.sh pwe_image pwe-mariadb               # vypíše celý název: ghcr.io/kukam/pwe-mariadb:<verze>
bash PWE/tools/lib/images.sh pwe_image_tag                       # jen tag
bash PWE/tools/lib/images.sh pwe_image_version                   # verze enginu z PWE/VERSION
bash PWE/tools/lib/images.sh pwe_image_names                     # názvy všech 9 image (deps = závislostní, examples = vzorové weby)
bash PWE/tools/lib/images.sh pwe_profile_image static            # závislostní image profilu: static → pwe-base, jinak pwe-<profil>
```

Nástroje na standardní chybový výstup hlásí, s jakým image pracují:

```text
make test (make compile: [perl-compile])
    [run-tests] image ghcr.io/kukam/pwe-debugger:2.2.1
make run
    [run-webapp] web=mujweb.web profil=mariadb registr=ghcr.io/kukam tag=2.2.1 image=pwe-mariadb -> docker compose up --remove-orphans
make module (stejně make check a make smtp-test, když moduly na hostiteli chybí)
    [tools] chybi moduly Template Class::Inspector -> spoustim v kontejneru ghcr.io/kukam/pwe-debugger:2.2.1
```

Když image v místním Dockeru není, přidá nástroj třířádkovou radu (Docker ho jinak mlčky zkusí
stáhnout a chyba registru sama neřekne, co s tím) — třetí řádek vyjmenuje tagy téhož image, které
v místním Dockeru jsou:

```text
[run-tests] image ghcr.io/kukam/pwe-debugger:2.3.0 neni v lokalnim Dockeru, docker ho zkusi stahnout z registru.
[run-tests]   sestaveni: make images ARGS=debugger (PWE/tools/build-images.sh debugger)
[run-tests]   mistne dostupne tagy ghcr.io/kukam/pwe-debugger: 2.2.1 latest (pouziti: PWE_IMAGE_TAG=<tag>)
```

Když v místním Dockeru není žádný tag, zní poslední řádek `v lokalnim Dockeru neni zadny image
<repozitář>`; u image zadaného přes `PWE_TEST_IMAGE` radí `PWE_TEST_IMAGE=<repozitář>:<tag>`.
Druhý řádek jmenuje cíl sestavení chybějícího image; u image, který k PWE nepatří, radí jen
`make images`, a u zrušeného image místo rady k sestavení řekne, co ho nahrazuje
(`image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, vzorovy web bez databaze je image
pwe-example-static`, `image pwe byl zrusen: engine se do image webu kopiruje z repozitare
(webapps/<web>/Dockerfile), nastroje a vyvojovy stack ho berou z mountu repozitare`).
Stejnou radu vypisují `make compile` (`[perl-compile]`), `make cgi` (`[pwe-cgi]` — jinak o image mlčí,
jeho výstupem je HTTP odpověď), Perl nástroje (`[tools]`) a `make run` (`[run-webapp]`, zvlášť pro
závislostní image profilu a `pwe-debugger`; jen u příkazů compose, které vytvářejí kontejnery — `up`, `run`,
`create`). Typicky se to stane po zvýšení `PWE/VERSION`: image s novým tagem ještě nikdo nesestavil.
Když tedy image této verze nejsou ani v registru (Docker hlásí `pull access denied`,
`manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden`), sestav si je lokálně
(`make images`), nebo použij tag, který místně máš, případně `PWE_IMAGE_TAG=latest`, jsou-li image
publikované (kdy vznikají, říká oddíl [Pipeline GitHub Actions](#pipeline-github-actions)).

`PWE_IMAGE_TAG` musí být platný tag — hodnotu s lomítkem (třeba název větve) nástroje odmítnou
(shellové skončí kódem 2, Perl nástroje chybou) s hláškou
`PWE_IMAGE_TAG='feature/x' neni platny tag image (…). Image PWE maji tagy <verze> (obsah PWE/VERSION) a latest.`
Když `PWE_IMAGE_TAG` zadaný není a `PWE/VERSION` neobsahuje verzi tvaru `X.Y.Z`, končí nástroje hláškou
`Soubor …/PWE/VERSION neobsahuje verzi enginu tvaru X.Y.Z (obsah: '…') - verzi image nelze urcit. Oprav PWE/VERSION, nebo zadej tag vyslovne: PWE_IMAGE_TAG=<tag> (napr. latest)`.
S `PWE_TEST_IMAGE` se tag nezjišťuje ani nekontroluje.

### Lokální sestavení

```bash
make images                                   # všech 9 image pro platformu tohoto stroje, tagy <verze> a latest
make images ARGS='base debugger'              # jen vybrané cíle: base mariadb mysql postgres debugger example-static example-mariadb example-mysql example-postgres
PWE/tools/build-images.sh --print             # jen vypíše cíle a tagy, nic nestaví (totéž make images ARGS=--print)
PWE/tools/build-images.sh --no-cache base     # bez mezipaměti vrstev (nové verze balíčků)
PWE/tools/build-images.sh --platform linux/amd64 base example-static  # zkušební sestavení pro jinou platformu (nenačte se)
PWE/tools/build-images.sh --push              # sestavit pro linux/amd64 i linux/arm64 a nahrát do registru (z commitnutého stavu)
PWE/tools/build-images.sh --help              # nápověda (totéž make images ARGS=--help)
make images-check                             # kouřové kontroly místních image (PWE/tools/smoke-images.sh)
```

`PWE/tools/build-images.sh [volby] [cíl…]` spustí `docker buildx bake -f docker-bake.hcl` (kontext =
kořen repozitáře) a předá mu registr z `PWE_IMAGE_REGISTRY` a verzi z `PWE/VERSION`. Každý image
dostane tagy `<verze>` a `latest` — s verzí `2.2.1` tedy vzniknou `ghcr.io/kukam/pwe-base:2.2.1`
a `:latest`, `ghcr.io/kukam/pwe-<profil>:2.2.1` a `:latest`, `ghcr.io/kukam/pwe-debugger:2.2.1`
a `:latest` a `ghcr.io/kukam/pwe-example-<profil>:2.2.1` a `:latest`. Na větvi gitu sestavení nezávisí
a **`PWE_IMAGE_TAG` se při něm nepoužívá** (vybírá image jen pro nástroje); je-li nastaven na něco
jiného než verzi nebo `latest`, skript na to upozorní (`[build-images] PWE_IMAGE_TAG=<x> se pri sestaveni
nepouziva: image dostanou tagy <verze> (PWE/VERSION) a latest`). Cíl `<cíl>` dává image `pwe-<cíl>`
a lze ho psát i celým názvem image (`pwe-base`, `pwe-example-static`). Zrušené cíle `pwe` a `static`
skript odmítne (kód 2) a řekne, co je nahrazuje (`Cil static (image pwe-static) byl zrusen: web bez
databaze bezi nad pwe-base (cil base), vzorovy web bez databaze je cil example-static. …`).

**Vzorový cíl a jeho základ.** Všechny cíle se staví jedním voláním bake, společný stage `base` se tedy
sestaví jen jednou. Image vzorového webu staví `Dockerfile` vzorového webu a image z jeho řádku `FROM`
(`<registr>/pwe-base:<verze>`, `<registr>/pwe-<profil>:<verze>`) nahrazuje `docker-bake.hcl` právě
sestaveným cílem (`contexts`: `target:base`, `target:mariadb`, …). Vzorový image tak vždy vychází
z čerstvého základu z téhož volání — i bez registru, i s builderem, který místní image nevidí
(`docker-container`), a pro více platforem. Základ se ale do místního Dockeru (s `--push` do registru)
**uloží jen tehdy, když je také mezi cíli**: `make images ARGS=example-static` sestaví
`pwe-example-static` nad čerstvým základem, místní `pwe-base:<verze>` ale nechá beze změny a skript na
to upozorní (`[build-images] cil example-static: zaklad pwe-base se sestavi z pracovni kopie, ale
neulozi se (neni mezi cili) …`). Po změně základu (`PWE/docker/`) proto stav oba cíle, nebo všechno.

Skript doplní i popisky image vzorových webů: čas sestavení (`created`) vždy, commit (`revision`) **jen
z čisté pracovní kopie** — s neuloženými změnami by commit obsahu image neodpovídal, popisek se proto
vynechá. Na začátku vypíše, co dělá (`[build-images] registr=ghcr.io/kukam tagy=2.2.1,latest
platforma=stroje cile=vsechny -> nacteni do lokalniho Dockeru`), a po načtení seznam místních image
s oběma tagy (`[build-images] lokalni image s tagy 2.2.1 a latest:`).

Každé sestavení oba tagy v místním Dockeru přepíše. Po zvýšení `PWE/VERSION` proto spusť `make images`
znovu — nástroje berou image s tagem nové verze, který do té doby neexistuje. Image vzorových webů
obsahují engine a vzorový web z pracovní kopie: po změně v `PWE/`, ve vzorových webech nebo ve vstupním
skriptu je sestav znovu, jinak `make images-check` ohlásí rozdíl obsahu.

| Volba | Význam |
| --- | --- |
| *(bez voleb)* | sestaví pro platformu stroje a načte image do místního Dockeru |
| `--push` | publikuje do registru (vyžaduje `docker login`); nejde kombinovat s `--load`. Bez `--platform` publikuje **`linux/amd64,linux/arm64`** (a vypíše to) — jen platforma stroje by přepsala vícearchitekturní tag z pipeline; více platforem najednou potřebuje builder s ovladačem `docker-container` nebo Docker s úložištěm image containerd. Ruční `--push` přepíše v registru tagy `<verze>` i `latest` tím, co je v pracovní kopii; běžně publikuje pipeline. Pojistky viz níže |
| `--allow-dirty` | povolí `--push` z pracovní kopie s necommitnutými změnami (popisek `revision` zůstane prázdný) |
| `--platform P` | cílová platforma nebo seznam (`linux/amd64,linux/arm64`); bez `--push` jde jen o zkušební sestavení — výsledek zůstane v mezipaměti builderu a do Dockeru se nenačte, aby pod stejnými tagy nenahradil image pro platformu stroje |
| `--load` | načte výsledek do místního Dockeru i s `--platform` (více platforem najednou umí načíst jen Docker s úložištěm image containerd) |
| `--no-cache` | nepoužije mezipaměť sestavení |
| `--print` | vypíše výslednou konfiguraci (cíle, tagy, argumenty, popisky) a skončí; s `--push` pojistky jen varují („--push by skoncil chybou“) |
| `--set K=V` | předá nastavení přímo `docker buildx bake` (lze opakovat), např. `--set '*.cache-from=type=gha'` |
| `-h`, `--help` | nápověda |

Volby `--platform` a `--set` vyžadují hodnotu, která nezačíná pomlčkou (lze psát i `--platform=P`,
`--set=K=V`); `--platform --push` tedy skončí chybou, místo aby `--push` spolkl jako platformu.

**Pojistky.** Skript skončí kódem 2 a nic nestaví, když:

- `PWE/VERSION` neobsahuje verzi tvaru `X.Y.Z` — verze je tagem všech image (hláška
  `Soubor …/PWE/VERSION neobsahuje verzi enginu tvaru X.Y.Z …`);
- registr v `PWE_IMAGE_REGISTRY` / `PWE_IMAGE_REGISTRIES` není platný, nebo je seznam prázdný;
- `--push`: pracovní kopie má necommitnuté změny (`git status`) — publikoval by se kód, který není
  v žádném commitu, a image vzorových webů by neměly popisek `revision`. Řešení: commit, nebo vědomě
  `--allow-dirty`;
- cíl je `pwe`, `static` nebo `pwe-static` (zrušené), nebo jiný neznámý cíl.

Bez gitu se s `--push` publikuje s varováním, že popisek `revision` bude prázdný. Pojistky z doby tagů
podle větve (odpojený `HEAD`, tag tvaru verze, větev dávající tag `master`) zanikly — tag už z větve
nevzniká; ruční `--push` proto **žádnou pojistku větve nemá** a z kterékoli větve přepíše v registru
tagy `<verze>` i `latest` (co se chystá publikovat, ukáže `--push --print`). Kontrola při sestavení, že
předaná verze odpovídá `PWE/VERSION` v image, zanikla se stage `pwe`; shodu popisku `version` se
souborem `/PWE/PWE/VERSION` v image vzorových webů hlídají kouřové kontroly.

Kromě `PWE_IMAGE_REGISTRY` čte skript `PWE_IMAGE_REGISTRIES` (seznam registrů oddělený čárkou, když se
má publikovat do více najednou; má přednost před `PWE_IMAGE_REGISTRY`; mezery, prázdné položky
a koncová lomítka se odstraní, neplatný nebo prázdný seznam = kód 2, jmenný prostor malými písmeny;
image vzorových webů berou základ z prvního registru seznamu)
a `PWE_IMAGE_SOURCE` (adresa repozitáře do popisku `source`, výchozí `https://github.com/kukam/PWE`).

#### Kouřové kontroly image

`make images-check [ARGS='…']` (`PWE/tools/smoke-images.sh [--platform P] [--pull never|always]
[--tree|--no-tree] [image…]`) ověří, že každý image obsahuje to, co má, a nic, co mít nemá — tentýž
skript pouští pipeline před publikací:

```bash
make images-check                                         # všech 9 image aktuálního registru a tagu (= verze) z místního Dockeru
make images-check ARGS='base example-static'              # jen vybrané (base, mariadb, …, example-static, … i celé názvy)
PWE/tools/smoke-images.sh --platform linux/arm64          # image jiné platformy (na stroji amd64 v emulaci QEMU)
PWE_IMAGE_TAG=latest PWE/tools/smoke-images.sh --pull always --platform linux/arm64   # publikovaný image z registru
```

| Image | Co se kontroluje (příkazy běží přes entrypoint image, bez sítě) |
| --- | --- |
| všechny | kontejner se spustí (s `--platform` i na správné architektuře); jdou načíst `CGI::Fast`, `Template`, `Class::Inspector`, `Class::MOP`, `JSON`, `JSON::XS`, `DBI`, `Mail::RFC822::Address`, `Cz::Cstocs`, `LWP::MediaTypes`, `IO::Socket::SSL`, `Net::SSLeay`, `Authen::SASL`, `Image::Magick`, `Crypt::OpenSSL::RSA`, `URI`, `HTML::Parser`; existují `sass`, `identify`, `convert`, `openssl` a pásmo `Europe/Prague`; popisek `title` = název image. U image, který odpovídá pracovní kopii (viz `--tree` níže), navíc vstupní skript v image = `PWE/docker/entrypoint.sh` pracovní kopie |
| závislostní image (`pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres`, `pwe-debugger`) | v image **není** kód enginu (`/PWE/PWE` neexistuje) ani žádný web (`/PWE/webapps` je prázdný); `ENV PWE_CONF_pwe_core=/PWE/PWE` a žádné `PWE_CONF_pwe_home` ani `PWE_PROFILE`; popisek `version` je prázdný |
| `pwe-base` | `convert` a `identify` nad skutečným obrázkem, `sass` přeloží SCSS, funguje `openssl` a `TZ`; žádný DB ovladač |
| `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` | ovladač profilu (`DBD::mysql` + `DBD::MariaDB`, `DBD::mysql`, `DBD::Pg`) a žádný ovladač jiného profilu |
| `pwe-debugger` | všechny tři ovladače, `Perl::LanguageServer` ≥ 2.6.2, `perlcritic`, `perltidy`, `curl` |
| image vzorových webů (`pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres`) | **vychází ze závislostního image téhož tagu** — vrstvy základu jsou začátkem vrstev image (jen když se základ kontroluje v témže běhu, jinak `SKIP`); ovladače databáze svého základu; `perl -c pwe.fcgi`; v `/PWE` jen `LICENSE`, `PWE` a `webapps`, `/PWE/PWE` bez `t/` a `docker/`; popisek `version` = `VERSION` v image; vzorový web tak, jak ho založilo sestavení: `ENV PWE_CONF_pwe_home` a `PWE_PROFILE`, pracovní adresář, soubory webu, prázdné pracovní adresáře, `conf/database.conf` → `<profil>.conf` (`pwe-example-static` žádný), v `/PWE/webapps` nic dalšího; při startu serveru (`FCGI_SOCKET_PATH`) entrypoint varuje, že běží vzorový web. U image, který odpovídá pracovní kopii, navíc `VERSION` a popisek = `PWE/VERSION` a **soubory enginu i vzorového webu v image = pracovní kopie, seznam i obsah** (bez `PWE/t`, `PWE/docker` a bez toho, co vynechává `.dockerignore`) |
| `pwe-example-static` | výchozí příkaz image obslouží jeden request v režimu CGI a vrátí stránku vzorového webu (HTML, bez chyby v logu) — jednou běžně a jednou s kořenovým souborovým systémem jen pro čtení (`--read-only` a `tmpfs` přes `ramdisk`, `sessions`, `uploadfile` a `log`) |
| `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres` | bez databáze (kontroly běží bez sítě) výchozí příkaz image načte konfiguraci profilu a ovladač a skončí až na připojení k databázi (`Connect to <profil> dbid:db1 …` a `Unable connect to db1`) |

Image se kontrolují vždy ve stejném pořadí (závislostní image před vzorovými, které se s nimi
srovnávají), každý jednou, bez ohledu na pořadí argumentů. Zrušené názvy `pwe`, `static` a `pwe-static`
skript odmítne (kód 2) s vysvětlením. Výchozí `--pull never` kontroluje jen místní image (chybějící =
`FAIL`, nikdy se potichu nestáhne starší image z registru); `--pull always` každý image nejdřív stáhne
a **nahradí** místní image pod stejným tagem.

**Srovnání s pracovní kopií** (`PWE/VERSION`, popisek `version`, soubory enginu a vzorového webu,
vstupní skript) má smysl jen u image, který z ní pochází. Bez voleb se proto provádí jen pro místní
image (`--pull never`) s tagem rovným verzi v `PWE/VERSION` — starý image je pak `FAIL`. U jiného tagu
(`PWE_IMAGE_TAG=latest`, jiná verze) a u `--pull always` se místo něj vypíše
`SKIP <image>: srovnani s pracovni kopii (…)` s důvodem (jeden řádek na image) a u image vzorových webů
se ověří jen vnitřní soulad (`VERSION` tvaru `X.Y.Z` = popisek `version`). `--tree` srovnání vynutí
(pipeline ho používá vždy — image vznikly z checkoutu o pár kroků dřív), `--no-tree` ho vypne.
Srovnává se **obsah souborů** (kontrolní součet a velikost), ne jen jejich seznam: image sestavený před
poslední změnou enginu, vzorového webu nebo vstupního skriptu je `FAIL`, dokud neproběhne `make images`.

Výstup je jeden řádek na kontrolu: `OK   <image>: <popis>`, `FAIL <image>: <popis>` s odsazeným
důvodem, nebo `SKIP <image>: <popis>` (kontrola se neprovádí, důvod pod ním; návratový kód nemění).
Úvodní řádek říká, co se kontroluje (`[smoke-images] registr=… tag=… verze=… platforma=… pull=…
srovnani-s-pracovni-kopii=ano|ne image=…`), závěrečný `[smoke-images] OK: N kontrol (preskoceno: M)`.
Návratový kód 0 = vše prošlo, 1 = něco selhalo, 2 = špatné použití.

Časté příčiny `FAIL`:

- `… v image maji jiny obsah nez v pracovni kopii`: místní image je starší než poslední změna v `PWE/`,
  ve vzorovém webu nebo ve vstupním skriptu — `make images`. Týká se i změn dokumentace, která je
  součástí enginu (`PWE/README.md`, `PWE/CHANGELOG.md`);
- v image chybí položka enginu: nový soubor nebo adresář přímo v `PWE/` není ve výčtu `COPY` šablony
  `Dockerfile` webu — doplň ho do `gen_dockerfile` v `PWE/tools/new-webapp.pl` a `Dockerfile` vzorových
  webů vygeneruj znovu (hlídá to i `PWE/t/14-tools.t`);
- `vychazi z image <základ> tehoz tagu`: vzorový image byl sestaven nad jiným základem, než jaký je
  v místním Dockeru — typicky po `make images ARGS=example-static`, které základ neuloží; náprava je
  `make images` bez výběru cílů (nebo se základem mezi cíli).

Soubory sestavení:

| Soubor | Co určuje |
| --- | --- |
| `PWE/docker/Dockerfile` | závislostní image: stage `base`, `mariadb`, `mysql`, `postgres`, `debugger` (každý `FROM base`); z kontextu sestavení bere jen `PWE/docker/entrypoint.sh`. Argumenty `UBUNTU_IMAGE` (výchozí `ubuntu:26.04` — hodnota musí mít tvar `<image>:<tag>` bez digestu a bez uvozovek, pipeline ji čte a připíná na digest sama), `PWE_SOURCE` (popisek zdroje), `PERL_LANGUAGESERVER_MIN` (nejnižší přípustná verze jazykového serveru v `debugger`, výchozí 2.6.2) |
| `webapps/example.web/Dockerfile`, `webapps/example-db.web/Dockerfile` | image vzorových webů — přesný výstup generátoru `PWE/tools/new-webapp.pl` (hlídá `PWE/t/14-tools.t`), stejná šablona jako u vlastního webu ([Image vlastního webu](#image-vlastního-webu)) |
| `PWE/docker/entrypoint.sh` | vstupní skript všech image (viz výše) |
| `docker-bake.hcl` | cíle `base`, `mariadb`, `mysql`, `postgres`, `debugger`, `example-static`, `example-mariadb`, `example-mysql`, `example-postgres` (skupina `default` = všech 9; cíl `<cíl>` = image `pwe-<cíl>`) a jejich tagy — funkce `image_tags` dává každému cíli `<registr>/<název>:<VERSION>` a `<registr>/<název>:latest`. Vzorovým cílům nastavuje `Dockerfile` vzorového webu, argumenty `PWE_IMAGE_REGISTRY` (první registr seznamu), `PWE_IMAGE_TAG` (= `VERSION`) a `PWE_PROFILE`, základ z téhož volání (`contexts`) a popisky. Proměnné `REGISTRIES` (seznam oddělený čárkou, výchozí `ghcr.io/kukam`), `VERSION` (**povinná**, tvar `X.Y.Z`; bez ní nebo s jiným tvarem bake skončí chybou validace), `SOURCE` (adresa repozitáře do popisku všech image) a — **jen pro image vzorových webů** — `REVISION` (commit) a `CREATED` (čas sestavení); obě jsou ve výchozím stavu prázdné a bake je sám nepočítá, aby stejné vstupy daly stejný image. Proměnná `TAG` už neexistuje. Soubor používá bloky `validation`, potřebuje tedy novější `docker buildx` (ověřeno s verzí 0.34) |
| `.dockerignore` | z kontextu sestavení vynechává `.git` i gity webů (`**/.git`), testy enginu (`PWE/t`), `webapps-example`, dočasná data webů (`ramdisk`, `log`, `sessions`, `uploadfile`, `temp`), `webapps/*/conf/local.env` (tajné údaje), `webapps/*/conf/database.conf` (v image ho vytvoří `RUN` podle zapečeného profilu, za běhu ho nasměruje `entrypoint.sh`), soukromé klíče, certifikáty a soubory `*.env` kdekoli v adresáři webu (`webapps/*/**/*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.env`; veřejné klíče `*.pub` a vzory `*.env.example` zůstávají) a lokální nastavení editoru (`webapps/*/.vscode`). Platí pro image vlastního webu i pro image vzorových webů — ani jedny tak nezávisí na stavu pracovní kopie a nenesou tajné údaje ([Image vlastního webu](#image-vlastního-webu)) |

Platformy se v `docker-bake.hcl` nenastavují: lokálně se staví pro platformu stroje, pipeline přidává
`linux/amd64` a `linux/arm64`. Přímé volání bez skriptu (z kořene repozitáře):

```bash
VERSION="$(cat PWE/VERSION)" docker buildx bake -f docker-bake.hcl --print               # jen vypíše, co by se stavělo
VERSION="$(cat PWE/VERSION)" docker buildx bake -f docker-bake.hcl --load base mariadb example-mariadb
docker build --target base -t pwe-base -f PWE/docker/Dockerfile .                        # jeden stage ručně, bez bake
```

### Pipeline GitHub Actions

V repozitáři jsou dva workflow GitHub Actions:

- **`.github/workflows/images.yml`** (název *Images*) sestaví všech devět image — pět závislostních
  a čtyři image vzorových webů — přes `docker-bake.hcl`, stejným příkazem `docker buildx bake`, jaký
  lokálně spouští `PWE/tools/build-images.sh` (cíl bake `<cíl>` = image `pwe-<cíl>`, seznam cílů je
  v proměnné `BAKE_TARGETS` jobu), otestuje je a z vybraných větví publikuje do `ghcr.io/<vlastník
  repozitáře malými písmeny>` (u tohoto repozitáře `ghcr.io/kukam`);
- **`.github/workflows/tests.yml`** (název *Tests*) je lehký: jen testy enginu pro změny, které testy
  čtou, ale image z nich nevznikají; nic nepublikuje ([Workflow Tests](#workflow-tests)).

**Kdo publikuje.** Image publikuje jen běh nad **výchozí větví repozitáře** (dnes `master`) a nad
větvemi vyjmenovanými v proměnné repozitáře **`PUBLISH_BRANCHES`** — při `push` i při ručním spuštění.
Všechno ostatní image jen sestaví a otestuje pro `linux/amd64`; nic se nepřihlašuje ani nepublikuje
a image existují jen v Dockeru runneru.

| Událost | Co se stane |
| --- | --- |
| `push` do **výchozí větve**, který mění vstupy image | sestavení, testy, kouřové kontroly obou platforem a **publikace** s tagy `<verze>` a `latest` — jen když je commit běhu stále hlavou větve |
| `push` do větve z `PUBLISH_BRANCHES`, který mění vstupy image | totéž, **publikace** |
| `push` do jiné větve (kromě `dependabot/**`), který mění vstupy image | jen sestavení `linux/amd64`, testy a kouřové kontroly; nic se nepublikuje |
| pull request, který mění vstupy image (i pull request Dependabota) | totéž; nepublikuje nikdy — ani když je jeho větev v `PUBLISH_BRANCHES`. Sestaví a otestuje se při každém pushi do své větve, i u větve téhož repozitáře, kde vedle něj běží i běh `push` (job nemá podmínku `if` — přeskočený job by se v kontrolách pull requestu počítal jako úspěšný) |
| ruční spuštění (*Actions → Images → Run workflow*) nad výchozí větví nebo větví z `PUBLISH_BRANCHES` | jako `push` do ní, **publikace**; volba `no_cache` sestaví bez mezipaměti pipeline (stáhne aktuální balíčky Ubuntu; z CPAN se při sestavení nic neinstaluje). Tlačítko je k dispozici až poté, co je workflow ve výchozí větvi repozitáře (viz [První zprovoznění](#první-zprovoznění)) |
| ruční spuštění nad jinou větví nebo nad gitovým tagem | jen sestavení a testy |

**Vstupy image** (cesty, jejichž změna workflow Images spouští): `PWE/**`, `docker-bake.hcl`,
`.dockerignore`, `LICENSE`, vzorové weby `webapps/example.web/**` a `webapps/example-db.web/**` (z nich
a z jejich `Dockerfile` vznikají image vzorových webů) a samotný workflow. Změna jen v `docs/`, v `docker-compose.yml`,
`kubernetes/` nebo `Makefile` workflow Images nespouští (soubory stacku, `kubernetes/` a `Makefile`
hlídá workflow Tests, `docs/` žádný); push gitového tagu také ne — tagy image určuje `PWE/VERSION`,
ne tagy gitu.

**Proměnná `PUBLISH_BRANCHES`** je proměnná repozitáře (ne tajemství): GitHub → repozitář →
*Settings → Secrets and variables → Actions* → karta *Variables* → *New repository variable*, nebo
z příkazové řádky `gh variable set PUBLISH_BRANCHES --body "pwe.ai"`. Hodnota jsou **přesné názvy
větví** oddělené mezerou nebo čárkou (i obojím, i konci řádků), např. `pwe.ai, release-2`. Rozlišuje
se velikost písmen a vzory (`release/*`) se nepodporují — běh na vzor jen upozorní varováním a vzor
ničemu neodpovídá. Prázdná nebo nenastavená proměnná znamená, že publikuje jen výchozí větev; ta se do
proměnné nepíše. Všechny publikující větve píší **stejné tagy** (`<verze>` a `latest`), platí tedy image
z běhu, který publikoval naposled — do `PUBLISH_BRANCHES` patří jen větev, ze které se image opravdu
mají brát (typicky jedna dlouhodobá vývojová větev vedle výchozí).

Běhy nad stejnou větví (stejným pull requestem) jdou po sobě. Nový push **zruší rozběhnutý běh jen
u pull requestu**; běh nad větví se neruší (publikující běh zrušený uprostřed nahrávání by v registru
nechal směs starých a nových image) — další push čeká ve frontě a GitHub v ní drží jen ten nejnovější
čekající běh. Běhy dvou různých publikujících větví se navzájem neřadí.

**Co dělá Images:**

1. *Meta.* Přečte verzi z `PWE/VERSION` (musí mít tvar `X.Y.Z`, jinak běh končí chybou dřív, než se
   cokoli staví), určí registr a hodnoty popisků a **rozhodne, jestli běh publikuje**: jen `push` nebo
   ruční spuštění nad větví, která je výchozí větví repozitáře nebo je v `PUBLISH_BRANCHES`. Důvod
   zapíše do logu kroku (řádky `udalost:`, `ref:`, `vychozi vetev:`, `PUBLISH_BRANCHES:`), do anotace
   běhu (*Publikace* / *Bez publikace*) a do souhrnu.
2. *Digest základního image* (*Base image digest*). Výchozí hodnota `ARG UBUNTU_IMAGE`
   z `PWE/docker/Dockerfile` se v registru vyhledá **jednou** a všechna tři volání bake (kroky 3, 7 a 9)
   stavějí nad `ubuntu:26.04@sha256:<digest>`. Tag základu se v registru posouvá — bez připnutí by
   publikace mohla sestavit a nahrát image nad jiným základem, než jaký prošel testy. Když digest
   zjistit nejde (tři pokusy), běh končí chybou a nic se nestaví.
3. *Sestavení `linux/amd64`.* Před sestavením zkontroluje pravidlo cílů a tagů (bake staví právě cíle
   z `BAKE_TARGETS` a cíl `<cíl>` má v každém registru právě tagy `pwe-<cíl>:<verze>`
   a `pwe-<cíl>:latest`), pak sestaví všech devět image pro platformu runneru, načte je do Dockeru
   runneru (`--load`) a ověří, že všechny tagy v Dockeru runneru opravdu jsou — testy nesmějí místo
   čerstvého sestavení potichu stáhnout starší image z registru. Image vzorových webů se staví nad
   závislostním image z téhož volání bake, ne nad image z registru.
4. *Testy a kompilace* v čerstvém `pwe-base` (`PWE_TEST_IMAGE=<registr>/pwe-base:<verze> PWE/tools/run-tests.sh`
   a `PWE/tools/perl-compile.sh`) — tím se zároveň hlídá, že základu nechybí žádná knihovna, kterou
   engine potřebuje. `pwe-base` engine neobsahuje; nástroje do něj montují checkout do `/PWE`.
5. *Kouřové kontroly `linux/amd64`* všech devíti image:
   `PWE/tools/smoke-images.sh --platform linux/amd64 --pull never --tree`
   ([Kouřové kontroly image](#kouřové-kontroly-image)); krok má časový limit 15 minut — kontroly
   spouštějí i engine z image vzorových webů a zaseknutý proces by jinak visel až do limitu jobu.
   Mezi sestavením a kontrolou se nesmí změnit `PWE/` ani vzorové weby (srovnává se obsah souborů).
   **Běh, který nepublikuje, končí tady.**
6. *Hlava větve* (*Branch head*). Publikuje jen běh, jehož commit je stále hlavou větve (`git ls-remote`),
   nebo se od hlavy liší jen mimo vstupy image. Běh nad starším commitem (ruční *Re-run* starého běhu,
   mezitím přišel novější push se změnou image) nebo nad zaniklou větví se sestaví a otestuje, ale
   publikaci přeskočí s poznámkou *Publikace preskocena* v logu — jinak by vrátil tagy `<verze>`
   a `latest` na starší kód. Když ověření technicky selže, publikuje se s varováním. Krok hlídá jen
   pořadí commitů **jedné** větve; která z více publikujících větví psala tagy naposled, neřeší.
7. *Sestavení `linux/arm64`* v emulaci (QEMU), načtené do Dockeru runneru pod jménem, které existuje
   jen na runneru (`localhost/pwe-arm64/pwe-<cíl>:<verze>` a `:latest`), aby nepřepsalo otestované image
   `linux/amd64`. Bake přitom dostává tytéž proměnné jako ostatní kroky a místní jméno je jen přepsaný
   tag (`--set <cíl>.tags=…`): z `REGISTRIES` se odvozuje argument `PWE_IMAGE_REGISTRY` image vzorových
   webů a s jinou hodnotou by publikace jejich vrstvy `arm64` nenašla v mezipaměti. První sestavení bez
   mezipaměti trvá desítky minut, další jednotky minut.
8. *Kouřové kontroly `linux/arm64`* — tentýž skript s `--platform linux/arm64` (limit 30 minut); po
   kontrole se image `arm64` z Dockeru runneru smažou. Testy enginu běží jen nad `linux/amd64` (kód
   enginu je čistý Perl, na platformě závisí jen balíčky image).
9. *Publikace.* Přihlásí se k registru a každý image nahraje pro obě platformy s oběma tagy (`<verze>`
   a `latest`; ukazují na tentýž index). **Nic už nestaví:** vrstvy obou platforem se berou z mezipaměti
   builderu z kroků 3 a 7, publikuje se tedy přesně to, co prošlo testy a kouřovými kontrolami — do
   registru se nedostane ani `linux/arm64`, který kontrolami neprošel. Index obou platforem dostane
   anotace OCI `org.opencontainers.image.source`, `licenses` a `description` (hodnoty z popisků
   otestovaného image — u závislostních image z `PWE/docker/Dockerfile`, u image vzorových webů
   z `docker-bake.hcl`): podle anotací indexu GitHub u víceplatformního
   image zobrazuje popis balíčku a přiřazuje ho k repozitáři.
10. *Souhrn* vznikne vždy, i po chybě nebo zrušení běhu: publikované image, jejich tagy a digesty,
    jinak důvod, proč se nepublikovalo, rozhodnutí kroku *Meta* (`Krok Meta: beh **smi publikovat** - …`
    nebo `beh **nepublikuje** - …`), událost, větev, verzi a commit. Selže-li samotná publikace, souhrn
    upozorní, že část image už může být v registru (cíle se nahrávají samostatně) — běh pak spusť
    znovu (*Re-run*).

Při jakékoli chybě v krocích 1–8 běh končí a nepublikuje se nic. K registru se workflow přihlašuje
vestavěným `GITHUB_TOKEN` (oprávnění `packages: write`); žádné tajemství se pro `ghcr.io` nenastavuje.

Hlášky, podle kterých se v běhu orientovat:

| Kde | Hláška |
| --- | --- |
| anotace běhu | `Publikace: Po kontrolach se image publikuji s tagy <verze> a latest - <důvod>` nebo `Bez publikace: Image se jen sestavi a otestuji (linux/amd64) - <důvod>` |
| důvody | `vetev je vychozi vetvi repozitare`, `vetev je v promenne repozitare PUBLISH_BRANCHES`, `vetev neni vychozi vetvi repozitare ani neni v promenne repozitare PUBLISH_BRANCHES`, `pull request nepublikuje nikdy`, `workflow bezi nad gitovym tagem, ne nad vetvi` |
| varování | `Promenna repozitare PUBLISH_BRANCHES obsahuje vzor (…) - vzory se nepodporuji, vetev se uvadi presnym nazvem`; `Vychozi vetev repozitare neni znama … - publikuji jen vetve z PUBLISH_BRANCHES` |
| chyby | `PWE/VERSION nema tvar X.Y.Z - verze je tagem vsech image`; `Cile nebo tagy neodpovidaji pravidlu: bake stavi prave cile z BAKE_TARGETS a cil <cil> ma v kazdem registru prave tagy pwe-<cil>:<verze> a pwe-<cil>:latest`; `Digest zakladniho image … se nepodarilo zjistit - nic se nestavi`; `ARG UBUNTU_IMAGE nema vychozi hodnotu tvaru <image>:<tag> (bez digestu) - zakladni image nejde pripnout` |
| krok *Base image digest* | `Zakladni image vsech buildu: ubuntu:26.04@sha256:…` |

**Popisky, mezipaměť a akce.**

- Popisky image vzorových webů předává workflow přes proměnné `docker-bake.hcl`: `REVISION` = commit
  běhu (`github.sha`), `CREATED` = čas určený jednou v kroku *Meta*. Všechna sestavení v běhu dostávají
  tytéž hodnoty, aby publikované image byly přesně ty otestované. Závislostní image tyto popisky nemají,
  takže se s každým commitem nemění ([Popisky image](#co-je-v-pwe-base)). Popisek `base.name`
  publikovaných závislostních image nese i digest základu (`ubuntu:26.04@sha256:…`), u image vzorových
  webů publikovaný závislostní image (`ghcr.io/<vlastník>/pwe-<profil>:<verze>`).
- Všechna volání bake dostávají stejné proměnné `REGISTRIES`, `VERSION`, `SOURCE`, `REVISION`
  a `CREATED`; žádná proměnná s tagem neexistuje — tagy `<verze>` a `latest` určuje `docker-bake.hcl`
  z `VERSION`.
- Mezipaměť sestavení je v GitHub Actions (`type=gha`) a má pro každý cíl dva obory (scope) podle
  platformy (dohromady 18): `images-<cíl>-amd64` zapisuje sestavení `linux/amd64` (každý běh včetně pull requestu),
  `images-<cíl>-arm64` sestavení `linux/arm64` (jen běh, který publikuje). Běh, který skončí na
  testech, tak mezipaměť `arm64` nepřepíše. Publikace mezipaměť jen čte (pojistka pro případ, že
  builder část své mezipaměti mezitím uvolnil).
- `no_cache` při ručním spuštění: mezipaměť `type=gha` se nečte (všechny vrstvy včetně `apt-get`
  se staví znovu, `linux/arm64` celý v emulaci), jen se obnoví.
- Image se publikují bez atestací (`--provenance=false --sbom=false`): tag pak ukazuje na čistý
  index se dvěma platformami, který čtou všechny nástroje včetně `docker manifest inspect`.
- **Akce jsou připnuté na SHA commitu** s verzí v komentáři (`uses: actions/checkout@<sha> # v7.0.1`).
  Nové verze navrhuje jednou týdně **Dependabot** (`.github/dependabot.yml`, ekosystém
  `github-actions`) — v pull requestu změní SHA i komentář. Jeho pull request projde sestavením
  a testy jako každý jiný a nic nepublikuje; push do větví `dependabot/**` workflow nespouští (dělal by
  tutéž práci podruhé).

#### Workflow Tests

`.github/workflows/tests.yml` hlídá soubory, které sada `PWE/t` čte, ale workflow Images je
nesleduje: `docker-compose.yml` a `docker-compose/**`, `kubernetes/**`, `.gitignore`, `Makefile`
a sám sebe. Vzorové weby `webapps/example.web` a `webapps/example-db.web` už k němu nepatří — jsou
vstupem image, sleduje je Images (a testy enginu po jejich změně pouští sám). Seznamy cest obou
workflow se nepřekrývají; push, který mění cesty z obou seznamů, spustí oba. Tests se spouští na
`push` (kromě větví `dependabot/**`) a pull request, které tyto cesty mění, a ručně. Sestaví jen cíl
`base` (jako `localhost/pwe-tests/pwe-base:latest`, existuje jen na runneru; verzi pro bake bere
z `PWE/VERSION`; engine a vzorové weby dostává image mountem checkoutu do `/PWE`), pustí `PWE/tools/run-tests.sh` a `PWE/tools/perl-compile.sh` s `PWE_TEST_IMAGE` na
tento image a nic nepublikuje: oprávnění má jen `contents: read`, do registru se nepřihlašuje
a mezipaměť `type=gha` nepoužívá. Nový push do stejné větve rozběhnutý běh zruší. Stejně jako u Images
nemá job podmínku `if`: push do větve s otevřeným pull requestem pustí testy dvakrát (běh `push`
a běh pull requestu). Na větvi nezáleží —
proměnná `PUBLISH_BRANCHES` se tohoto workflow netýká.

#### První zprovoznění

**Co musí být v gitu.** Workflow vidí jen to, co je commitnuté a nahrané na GitHub: adresář `PWE/`
(engine, `PWE/docker/`, `PWE/tools/`, testy `PWE/t/`), `docker-bake.hcl`, `.dockerignore`, `LICENSE`,
vzorové weby `webapps/example.web` a `webapps/example-db.web` včetně jejich `Dockerfile` (vznikají
z nich image vzorových webů a pracují s nimi testy enginu), `docker-compose.yml` a `kubernetes/` (s nimi pracují testy enginu; bez
nich se příslušné testy přeskočí) a samotné `.github/workflows/images.yml`,
`.github/workflows/tests.yml` a `.github/dependabot.yml`. `push` spouští běh ve větvi, která workflow
obsahuje.

**Co nastavit v repozitáři na GitHubu:**

1. **Actions musí být povolené** — ve forku jsou po založení vypnuté (viz *Fork* níže).
2. **Kdo publikuje:** výchozí větev publikuje sama. Mají-li image vznikat i z jiné větve (např.
   z dlouhodobé vývojové větve `pwe.ai`, dokud není začleněná do výchozí), nastav proměnnou repozitáře
   `PUBLISH_BRANCHES` ([Pipeline GitHub Actions](#pipeline-github-actions)) a pak do té větve pošli
   commit, který mění vstupy image, nebo běh spusť ručně.
3. **Ruční spuštění až z výchozí větve.** Tlačítko *Run workflow* GitHub nabídne až poté, co je
   workflow začleněný do **výchozí větve** repozitáře (`master`). Do té doby workflow spouští jen
   `push`; ruční běh — a s ním volba `no_cache` — není k dispozici. Po začlenění ho lze pustit nad
   kteroukoli větví, která soubor workflow obsahuje. Platí pro *Images* i *Tests*.
4. **Dependabot** čte `.github/dependabot.yml` jen z výchozí větve, začne tedy pracovat až po
   začlenění. Aktualizace verzí potřebují zapnutý *Dependency graph* (*Settings → Code security*) —
   u veřejného repozitáře je zapnutý, ve forku a v soukromém repozitáři ho zapni ručně.
5. **Viditelnost balíčků** v `ghcr.io` nastav po prvním publikujícím běhu (balíčky vzniknou soukromé)
   a zkontroluj přístup repozitáře k nim (*Manage Actions access*) — viz níže.
6. **Povinné kontroly větve** (*required status checks*): joby *Build, test, publish* (Images)
   a *Engine tests* (Tests) jako povinné nenastavuj — oba workflow mají filtr `paths`, takže pull
   request, který sledované cesty nemění, by na výsledek čekal navždy (*Pending*).
7. Volitelné zrcadlo na Docker Hub: proměnná `DOCKERHUB_NAMESPACE` a tajemství `DOCKERHUB_USERNAME`
   a `DOCKERHUB_TOKEN` (viz níže).

**Kdy vzniknou image v registru.** Tagy `<verze>` a `latest` publikuje pipeline jen při běhu nad
výchozí větví nebo nad větví z `PUBLISH_BRANCHES`: po `push`, který mění vstupy image, nebo při ručním
spuštění. Dokud takový běh neproběhl — typicky když se pracuje ve větvi, která není výchozí ani
v `PUBLISH_BRANCHES`, nebo hned po zvýšení `PWE/VERSION` —, image `ghcr.io/kukam/pwe-*:<verze>`
v registru nejsou: nástroje i `docker-compose.yml` pak fungují jen nad místními image z `make images`
a nasazení do Kubernetes skončí chybou `digest image … nelze zjistit`.

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
se tytéž image (všech devět) se stejnými tagy i do `docker.io/<DOCKERHUB_NAMESPACE>` — jen u běhu,
který publikuje.
Chybí-li cokoli z toho, publikuje se jen do `ghcr.io` (je-li nastavená jen proměnná bez tajemství, běh
na to upozorní varováním). `DOCKERHUB_USERNAME` je přihlašovací jméno účtu, který smí do jmenného
prostoru zapisovat, `DOCKERHUB_TOKEN` jeho přístupový token (Docker Hub → *Account settings → Personal
access tokens*) s oprávněním **Read & Write** — s tokenem jen pro čtení nahrání selže. Repozitáře
`pwe-base`, `pwe-mariadb`, …, `pwe-example-static`, … Docker Hub založí při prvním nahrání, s výchozí
viditelností nastavenou u účtu (*Default privacy*). Image ze zrcadla použiješ přes
`PWE_IMAGE_REGISTRY=docker.io/<jmenný prostor>`.

**Viditelnost balíčků v GHCR.** Nový balíček kontejneru je **soukromý**, dokud mu vlastník viditelnost
nezmění — do té doby ho bez přihlášení nestáhne nikdo (`make run`, `make test` ani `docker build`
image webu na jiném stroji). Aby šly
image stahovat bez přihlášení, nastav u každého z devíti balíčků (`pwe-base`, `pwe-mariadb`,
`pwe-mysql`, `pwe-postgres`, `pwe-debugger`, `pwe-example-static`, `pwe-example-mariadb`,
`pwe-example-mysql`, `pwe-example-postgres`) viditelnost *Public*: GitHub → profil
vlastníka → *Packages* → balíček → *Package settings* → *Change visibility*. Změna na veřejný je
nevratná. Balíčky jsou k repozitáři přiřazené přes `org.opencontainers.image.source` (u víceplatformního
image přes anotaci indexu, kterou pipeline nastavuje — [Co dělá Images](#pipeline-github-actions), krok 9),
takže je najdeš i na jeho stránce v sekci *Packages*. Balíčky zrušených image `pwe` a `pwe-static`
z verze 2.2.0 pipeline nemaže — pokud v registru jsou, smaž je ručně.

**Přihlášení k soukromým balíčkům.** Dokud jsou balíčky soukromé, přihlas Docker osobním přístupovým
tokenem (classic) s oprávněním `read:packages` (pro `--push` z vlastního stroje `write:packages`):

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-login> --password-stdin
```

V Kubernetes se stejné údaje předávají jako `imagePullSecrets`.

### Image vlastního webu

Web má vlastní `Dockerfile` (vytváří ho `make new`; pro všechny weby stejná šablona — liší se jen
názvem webu a základním image podle toho, jestli web má databázi). Image webu má tři části:

1. **závislostní image** — `pwe-<profil>` u webu s databází, `pwe-base` u webu bez databáze: běhové
   knihovny, ovladač databáze a vstupní skript; kód enginu ani žádný web v něm není;
2. **engine** zkopírovaný z kontextu sestavení, tedy z adresáře `PWE/` repozitáře enginu (bez `PWE/t`
   a `PWE/docker`), do `/PWE/PWE`;
3. **web** z `webapps/<web>` do `/PWE/webapps/<web>`.

Žádný další image se nepoužívá (jediný `FROM`, žádné `COPY --from`) a **sestavuje se vždy z kořene
repozitáře enginu**. Šablona je na jediném místě — funkce `gen_dockerfile` v `PWE/tools/new-webapp.pl`
— a stejnou šablonou vznikají i image vzorových webů `pwe-example-*`. Šablona bez úvodního komentáře
(ten popisuje složení image a obsahuje příkazy sestavení níže); `<web>` je název webu, zde web
s databází a výchozím profilem `mariadb` — přesně tak vypadá `webapps/example-db.web/Dockerfile`:

```dockerfile
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=latest
ARG PWE_PROFILE=mariadb

FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

# Engine z kontextu sestaveni do /PWE/PWE: vsechny polozky adresare PWE/ krome testu (PWE/t) a sestaveni
# zavislostnich image (PWE/docker). Vycet musi byt uplny - make check (PWE/tools/check-webapp.pl) upozorni,
# kdyz v nem nektera polozka enginu chybi (napr. po aktualizaci enginu: pak Dockerfile vygeneruj znovu).
# Poradi od nejmene po nejcasteji menene. COPY --link: vrstva nezavisi na vrstvach pod sebou - zmena zakladu
# ji nezneplatni a image webu nad stejnym enginem ji sdili.
COPY --link LICENSE /PWE/LICENSE
COPY --link PWE/assets /PWE/PWE/assets
COPY --link PWE/templates /PWE/PWE/templates
COPY --link PWE/tools /PWE/PWE/tools
COPY --link PWE/Entities /PWE/PWE/Entities
COPY --link PWE/Services /PWE/PWE/Services
COPY --link PWE/Sites /PWE/PWE/Sites
COPY --link PWE/Pages /PWE/PWE/Pages
COPY --link PWE/Libs /PWE/PWE/Libs
COPY --link PWE/pwe.fcgi PWE/debug.cgi PWE/favicon.ico PWE/README.md PWE/CHANGELOG.md PWE/VERSION /PWE/PWE/

# Web (bez toho, co vynechava .dockerignore - viz zahlavi).
COPY --link webapps/<web> /PWE/webapps/<web>

# PWE_CONF_pwe_core=/PWE/PWE nastavuje uz zakladni image. PWE_PROFILE = profil, pro ktery je image sestaveny.
# Za behu ho lze prepsat (-e PWE_PROFILE=...) jen na profil, jehoz ovladac zakladni image obsahuje:
# pwe-mariadb a pwe-mysql umi mariadb i mysql (engine pro oba pouziva DBD::mysql), pwe-postgres jen
# postgres, pwe-base zadnou databazi. Entrypoint pak conf/database.conf presmeruje na novy profil.
ENV PWE_CONF_pwe_home=/PWE/webapps/<web> \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky zakladniho image (nazev, popis, repozitar a licence
# zavislostniho image PWE), ktere o image webu neplati. version, source a licenses jsou proto prazdne - dopln
# verzi, adresu repozitare a licenci webu; base.name = image, ze ktereho je image webu sestaveny (verzi
# enginu v image rika soubor /PWE/PWE/VERSION).
LABEL org.opencontainers.image.title="<web>" \
      org.opencontainers.image.description="Web <web> nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/<web>" \
      org.opencontainers.image.version="" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/<web>

# Pracovni adresare a conf/database.conf (symlink na konfiguraci profilu, pokud ji web ma) vznikaji uz pri
# buildu. Image tak jde spustit i s korenovym souborovym systemem jen pro cteni (docker run --read-only,
# Kubernetes readOnlyRootFilesystem) - engine ale do ramdisk, sessions, uploadfile a log zapisuje, takze
# tyto ctyri adresare pak musi byt zapisovatelne (tmpfs nebo volume pres adresare z image); bez
# zapisovatelneho ramdisk neobslouzi ani jeden request. Entrypoint dela totez pri startu - kvuli prepsani
# PWE_PROFILE a mountum pres adresar webu.
RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log; \
    if [ -f "conf/${PWE_PROFILE}.conf" ] && { [ -L conf/database.conf ] || [ ! -e conf/database.conf ]; }; then \
        ln -sfn "${PWE_PROFILE}.conf" conf/database.conf; \
    fi

# ENTRYPOINT se dedi ze zakladniho image (/usr/local/bin/entrypoint.sh z pwe-base), web vlastni nema.
CMD ["perl", "/PWE/PWE/pwe.fcgi"]
```

Web **bez databáze** se liší jen na třech místech: `ARG PWE_PROFILE=static`,
`FROM ${PWE_IMAGE_REGISTRY}/pwe-base:${PWE_IMAGE_TAG}` a tentýž image v popisku `base.name` (tak vypadá
`webapps/example.web/Dockerfile`).

Co z šablony plyne:

- **Engine se bere z pracovní kopie, ne z image.** Do image webu se dostane adresář `PWE/` tak, jak
  v okamžiku sestavení leží vedle webu; verzi enginu v image říká soubor `/PWE/PWE/VERSION`.
  `PWE_IMAGE_TAG` vybírá **jen závislostní image** a verzi enginu neurčuje — starší tag závislostí
  s novějším enginem se sestaví bez varování. Nový engine do webu = aktualizovat repozitář enginu
  a image webu sestavit znovu. Samostatný image `pwe` s enginem, druhý `FROM`, `COPY --from=engine`
  a argument `PWE_ENGINE_TAG` z verze 2.2.0 zanikly.
- **Výčet `COPY` enginu musí být úplný.** Šablona vyjmenovává všechny položky adresáře `PWE/` kromě `t`
  a `docker`. Přibude-li v enginu soubor nebo adresář přímo v `PWE/`, doplní se do šablony
  a `Dockerfile` webu je potřeba vygenerovat znovu; `make check` na chybějící položku upozorní
  (`chybi COPY polozek enginu: PWE/…`).
- **`COPY --link`** vyžaduje BuildKit (výchozí od Dockeru 23). Vrstva s enginem ani vrstva s webem
  nezávisí na vrstvách pod sebou: změna závislostního image je nezneplatní a image webů nad stejným
  enginem je sdílejí.
- **Ve `/PWE/webapps` je jen vlastní web.** Závislostní image žádný web neobsahuje, šablona proto nic
  nemaže (a má jediný `RUN`).
- **Žádný vlastní vstupní skript.** `Dockerfile` webu `ENTRYPOINT` nenastavuje a web `entrypoint.sh`
  nemá: image webu dědí `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` ze základního image
  (ten ho má z `pwe-base`, zdroj `PWE/docker/entrypoint.sh`) — oprava vstupního skriptu se tak do
  image webu dostane s novým závislostním image, bez zásahu do webu ([Co je v `pwe-base`](#co-je-v-pwe-base)).
- **Profil je do image zapečený.** `ARG PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` a `PWE_PROFILE` jsou za
  `FROM` deklarované znovu (argument z hlavičky platí jen pro řádek `FROM`), aby šly zapsat do
  `ENV` a `LABEL`. Kontejner z image webu tak `PWE_PROFILE` předávat nemusí. Za běhu ho lze přepsat
  (`-e PWE_PROFILE=…`) jen na profil, jehož ovladač základní image obsahuje: `pwe-mariadb` a `pwe-mysql`
  umí `mariadb` i `mysql` (engine pro oba používá `DBD::mysql`), `pwe-postgres` jen `postgres`,
  `pwe-base` žádnou databázi; entrypoint pak `conf/database.conf` přesměruje na nový profil
  a na chybějící ovladač upozorní varováním.
- **Web, který dostal databázi až později,** potřebuje `Dockerfile` vygenerovaný s `--db <profil>` —
  základ `pwe-base` ovladače databáze nemá. `make check` na to upozorní (`WARN Dockerfile je pro web bez
  databaze (PWE_PROFILE=static, zaklad pwe-base nema ovladace databaze), ale web ma conf/…`).
- **Pracovní adresáře a `conf/database.conf` vznikají už při sestavení** (`RUN`): `ramdisk/templates`,
  `sessions`, `uploadfile`, `log` a — má-li web `conf/<profil>.conf` — symlink `conf/database.conf` →
  `<profil>.conf` (běžný soubor `conf/database.conf` se nepřepisuje). Image tak jde spustit
  i s kořenovým souborovým systémem **jen pro čtení** (`docker run --read-only`, Kubernetes
  `readOnlyRootFilesystem`). Engine ale do `ramdisk`, `sessions`, `uploadfile` a `log` zapisuje — tyto
  čtyři adresáře pak musí být zapisovatelné (`tmpfs` nebo svazek, v Kubernetes `emptyDir`), např.
  `--tmpfs /PWE/webapps/<web>/ramdisk --tmpfs /PWE/webapps/<web>/sessions --tmpfs /PWE/webapps/<web>/uploadfile --tmpfs /PWE/webapps/<web>/log`;
  bez zapisovatelného `ramdisk` engine neobslouží ani jeden request.
  Entrypoint totéž dělá při startu (kvůli přepsání `PWE_PROFILE` a mountům přes adresář webu); s kořenem
  jen pro čtení ale profil za běhu přepnout nejde — symlink zůstane z doby sestavení a entrypoint
  vypíše varování. Proces běží jako `root` (`runAsNonRoot` podporovaný není).
- **Vlastní popisky.** Bez `LABEL` by image webu zdědil popisky závislostního image (název, popis,
  repozitář a licenci). Šablona proto nastaví `title` = název webu, `description`,
  `base.name` = image, ze kterého je sestavený, a **prázdné `version`, `source` a `licenses`** — doplň
  verzi, adresu repozitáře a licenci webu (hlavně když image publikuješ do `ghcr.io`: GitHub podle
  `source` přiřazuje balíček k repozitáři). Verzi enginu v image webu říká soubor `/PWE/PWE/VERSION`.

| Argument sestavení | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr a jmenný prostor závislostních image PWE |
| `PWE_IMAGE_TAG` | `latest` | tag závislostního image (`pwe-<profil>`, u webu bez databáze `pwe-base`): `latest`, nebo **verze** (obsah `PWE/VERSION`, např. `2.2.1`). Verzi enginu v image webu neurčuje — ta je dána pracovní kopií |
| `PWE_PROFILE` | web s databází: profil z `--db` (`mariadb`, `mysql`, `postgres`); web bez databáze: `static` | u webu s databází určuje základ `pwe-<profil>` a cíl symlinku `conf/database.conf`; v obou případech zapečená proměnná `PWE_PROFILE` |

Sestavení (**vždy z kořene repozitáře enginu** — `COPY` bere `LICENSE`, `PWE/…` i `webapps/<web>`; první
dva příkazy jsou i v záhlaví `Dockerfile` webu):

```bash
# nad nejnovějším závislostním image (výchozí PWE_IMAGE_TAG=latest; z registru nebo z místního Dockeru po make images)
docker build -t muj-web -f webapps/<web>/Dockerfile .

# závislosti připnuté na verzi enginu: tag image pwe-<profil> = obsah PWE/VERSION
docker build --build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)" -t registry/muj-web:1.0 -f webapps/<web>/Dockerfile .

# web s databází pro jiný profil, než je výchozí profil jeho Dockerfile
docker build --build-arg PWE_PROFILE=postgres -t registry/muj-web:1.0 -f webapps/<web>/Dockerfile .

# pro dvě platformy rovnou do registru (závislostní image musí být v registru, viz níže)
docker buildx build --push --platform linux/amd64,linux/arm64 --build-arg PWE_IMAGE_TAG=2.2.1 \
    -t registry/muj-web:1.0 -f webapps/<web>/Dockerfile .
```

**Odkud se bere závislostní image.** `docker build` vezme image `pwe-<profil>` (nebo `pwe-base`)
z místního Dockeru, a když tam není, stáhne ho z registru (dokud jsou balíčky soukromé, musí být Docker
k `ghcr.io` přihlášený). `make images` označuje místní image oběma tagy (`<verze>` i `latest`), takže
nad nimi funguje výchozí `latest` i připnutá verze. Pozor na `latest`: Docker použije místní image
s tímto tagem a sám ho neaktualizuje — novější publikovaný image stáhne
`docker pull ghcr.io/kukam/pwe-<profil>:latest` nebo `docker build --pull …`.

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
    --build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)" -t muj-web -f webapps/<web>/Dockerfile .
```

Vícearchitekturní sestavení s `--push` běží zpravidla v builderu `docker-container` (ovladač `docker`
staví více platforem najednou jen s úložištěm image containerd) — pro něj musí být závislostní image
v registru.

- **Připnutí závislostí na verzi.** `PWE_IMAGE_TAG=2.2.1` staví web nad `ghcr.io/kukam/pwe-<profil>:2.2.1`.
  Verzi enginu při startu hlídá `pwe.require_core` v `conf/web.conf`. Tag verze je přepisovatelný
  ([Registr a tagy](#registr-a-tagy)); úplně stejný základ při každém sestavení zaručí jen digest — pak
  v `Dockerfile` webu nahraď řádek `FROM` za `FROM ghcr.io/kukam/pwe-<profil>@sha256:…` (`make check`
  na `FROM` odlišný od šablony upozorní řádkem `WARN`, chyba to není). Výchozí `latest` se hodí pro
  vývoj, ne pro reprodukovatelné sestavení produkčního image.
- **Produkční image stav z čistého checkoutu.** Engine i web se kopírují tak, jak v pracovní kopii jsou —
  včetně necommitnutých změn. Kdo chce do image webu upravený engine, nemusí stavět žádný další image:
  stačí sestavit image webu z pracovní kopie s úpravou.
- **Do image se nedostanou dočasná data ani tajné údaje.** Kořenový `.dockerignore`
  z kontextu vynechává `webapps/*/conf/local.env` (tajné údaje), soukromé klíče, certifikáty a soubory
  `*.env` kdekoli v adresáři webu (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.env`, úložiště klíčů `*.jks`
  a `*.keystore` a soukromé klíče SSH `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`; soukromý klíč
  s jiným názvem by se do image dostal — pojmenuj ho některou z těchto přípon, nebo ho drž mimo adresář webu),
  `webapps/*/conf/database.conf` (symlink podle zapečeného profilu vytvoří `RUN` šablony při
  sestavení), dočasné adresáře webu (`ramdisk`, `log`, `sessions`, `uploadfile`, `temp`), git webu
  (`**/.git`), lokální nastavení editoru (`webapps/*/.vscode`) a testy enginu (`PWE/t`). Do image se tedy
  nedostane heslo z `conf/local.env`, privátní klíč (např. `conf/csob/private.pem` platební brány) ani
  profil, se kterým byl web naposledy spuštěn přes `make run`.
- **Soukromé klíče dostane kontejner až za běhu** — mountem nebo secretem — a cestu k nim přes
  `PWE_CONF_*`. Příklad e-shopu (privátní klíč platební brány,
  [22 — Platební brána ČSOB](22-platebni-brana-csob.md#10-přechod-do-produkce)):

  ```bash
  docker run … -v /srv/secrets/csob/private.pem:/run/secrets/csob_private.pem:ro \
      -e PWE_CONF_csob_private_key=/run/secrets/csob_private.pem registry/muj-web:1.0
  ```

  Bez klíče tam platba v režimu `test`/`production` skončí chybou `error_payment_keys`. Veřejné klíče
  (`*.pub`) v image zůstávají. Vzory rozhodují jen podle přípony — veřejný klíč nebo certifikát
  s příponou `.pem` se do image nedostane také.
- Image webu má zapečené `PWE_CONF_pwe_home` svého webu, `PWE_PROFILE` a z `pwe-base` zděděné
  `PWE_CONF_pwe_core=/PWE/PWE`; `FCGI_SOCKET_PATH` (např. `:7779`,
  [FastCGI socket](#fastcgi-socket)) a časové pásmo (image běží v UTC, viz
  [Časové pásmo](#časové-pásmo)) dodá až nasazení.

#### Dockerfile ze starší šablony

Web založený před verzí 2.2.1 má `Dockerfile` ze šablony, která s dnešními image nepočítá — image by se
buď nesestavil, nebo by neobsahoval engine:

| Šablona | Podle čeho se pozná | Co se stane nad dnešními image |
| --- | --- | --- |
| verze 2.2.0 | dva `FROM` (`FROM …/pwe:${PWE_ENGINE_TAG} AS engine`), `COPY --from=engine`, výchozí `PWE_IMAGE_TAG=master` | image `pwe` ani tag `master` už nevznikají: sestavení skončí chybou stažení, nebo — zůstal-li starý image `pwe` v registru či v místním Dockeru — vznikne image se starým enginem |
| starší (Docker Hub) | `FROM kukam/pwe-base:latest`, vlastní `entrypoint.sh` (`ADD … entrypoint.sh`, `ENTRYPOINT`) | image vznikne nad historickým základem ([Přechod ze starého uspořádání image](#přechod-ze-starého-uspořádání-image)); se základem zaměněným za dnešní `pwe-base` by v něm chyběl engine |

`make check WEB=<web>` na takový `Dockerfile` upozorní (jen varování, kontrolu neshodí) a vyjmenuje
znaky, podle kterých starou šablonu poznal:

```text
WARN Dockerfile je ze stare sablony (2x FROM - image pwe jako zdroj enginu; ARG PWE_ENGINE_TAG; COPY --from=engine; …): … Vygeneruj novy: PWE/tools/new-webapp.pl <web> --db <profil> --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne)
```

Převod:

```bash
# web stejného názvu a profilu vygeneruj do dočasného adresáře (u webu bez databáze bez --db) …
PWE/tools/new-webapp.pl <web> --db <profil> --dir /tmp/<web>-novy
# … a převezmi z něj jen Dockerfile
cp /tmp/<web>-novy/Dockerfile webapps/<web>/Dockerfile
rm -rf /tmp/<web>-novy
```

Vlastní úpravy (`RUN` s knihovnami, popisky `version`/`source`/`licenses`) přenes ručně, případný
`webapps/<web>/entrypoint.sh` smaž a image webu sestav znovu z kořene repozitáře. `make k8s-image`
`Dockerfile` ze starší šablony odmítne ještě před sestavením (`webapps/<web>/Dockerfile je z drivejsi
sablony (…)`).

### Přechod ze starého uspořádání image

Do 15. 11. 2026 se používaly image z Docker Hubu `kukam/pwe-base:latest` (Ubuntu, všechny knihovny
včetně DB ovladačů a ladicích nástrojů **a engine** v `/PWE/PWE`) a `kukam/pwe-<profil>:latest`
(základ + vzorový web se zapečeným `PWE_CONF_pwe_home`). Toto uspořádání je historické; existující
web a nasazení je potřeba upravit:

| Co | Dřív | Nyní |
| --- | --- | --- |
| `Dockerfile` webu | `FROM kukam/pwe-base:latest` (engine byl v základu) | šablona z oddílu [Image vlastního webu](#image-vlastního-webu): `FROM ghcr.io/kukam/pwe-<profil>:<tag>` (web bez databáze `pwe-base`) + engine zkopírovaný z repozitáře; `ENV PWE_CONF_pwe_core` už v něm není (má ho `pwe-base`). `Dockerfile` vygeneruj znovu ([Dockerfile ze starší šablony](#dockerfile-ze-starší-šablony)) |
| `entrypoint.sh` webu | vlastní kopie (`ADD … entrypoint.sh` a `ENTRYPOINT` v `Dockerfile`) | smazat — image webu vstupní skript dědí ze závislostního image (zdroj `PWE/docker/entrypoint.sh`) |
| knihovna mimo nový základ (`lessc`, `IO::AIO`, překladač, `cpanm`, `curl`, `LWP::UserAgent`, `Data::UUID`, `Data::GUID`, `Crypt::OpenSSL::X509`, DB ovladač v jiném profilu) | byla v `kukam/pwe-base` | přidat do `Dockerfile` webu ([Přidání knihovny](#přidání-knihovny)) |
| image nástrojů | `kukam/pwe-mariadb:latest`, přepis `PWE_TEST_IMAGE=kukam/pwe-…:latest` | `ghcr.io/kukam/pwe-debugger:<verze>`; výběr přes `PWE_IMAGE_TAG` / `PWE_IMAGE_REGISTRY` |
| vlastní compose a CI nad repozitářem | `kukam/pwe-<profil>:latest` | `ghcr.io/kukam/pwe-<profil>:<verze>` nebo `latest` (web bez databáze `pwe-base`) s repozitářem namountovaným do `/PWE`, ladění `ghcr.io/kukam/pwe-debugger:<verze>` |
| nasazení (Kubernetes, produkční compose) | `kukam/pwe-<profil>:latest` nebo image webu nad `kukam/pwe-base` | image vlastního webu sestavený dnešní šablonou; ukázka: `ghcr.io/kukam/pwe-example-<profil>` |
| VS Code v režimu `run` | `kukam/pwe-base:latest` v `perl.containerArgs` | `ghcr.io/kukam/pwe-debugger:latest` |

Nestačí ve starém `Dockerfile` jen zaměnit základ za `ghcr.io/kukam/pwe-base` nebo `pwe-<profil>`:
dnešní závislostní image engine nenesou a kontejner by skončil chybou
`Can't open perl script "/PWE/PWE/pwe.fcgi"`. Historické
`kukam/pwe-*:latest` na Docker Hubu zůstávají ve starém uspořádání, dokud je něco nepřepíše — pozor na
[zrcadlo](#pipeline-github-actions): je-li zapnuté se jmenným prostorem `kukam`, nahrává dnešní image
pod tagy `<verze>` **a `latest`**, takže historické `kukam/pwe-base:latest` a `kukam/pwe-<profil>:latest`
nahradí závislostní image bez enginu a `kukam/pwe-example-static` dnešní image vzorového webu. Staré
místní image `kukam/pwe-*:latest` po přechodu nic nepoužívá a lze je smazat (`docker image rm`).

### Přechod z tagů podle větve

Mezi 15. a 16. 11. 2026 (engine 2.2.0) měly image tag podle větve gitu (`…:master`, `…:pwe.ai`; jen
`pwe` navíc tag verze), engine nesl samostatný image `pwe`, web bez databáze běžel v `pwe-static`
a `Dockerfile` webu měl dva `FROM`. Od verze 2.2.1 platí:

| Co | Dřív (2.2.0) | Nyní (od 2.2.1) |
| --- | --- | --- |
| tagy image | `<větev>`; `pwe` navíc `<verze>`; `latest` neexistoval | každý image právě `<verze>` a `latest`; tagy podle větve neexistují |
| výchozí tag nástrojů (`PWE_IMAGE_TAG` nezadán) | aktuální větev gitu, bez gitu `master` | verze z `PWE/VERSION`, bez závislosti na gitu |
| `PWE_IMAGE_TAG=master …` | image větve `master` | tag `master` už nevzniká → `PWE_IMAGE_TAG=latest …` |
| `docker compose up` bez `PWE_IMAGE_TAG` | tag `master` | tag `latest` |
| image `pwe` (základ + kód enginu) | zdroj enginu pro `Dockerfile` webu (`COPY --from`) | **zrušen** — engine se do image webu kopíruje z repozitáře; nástroje a vývojový stack ho berou z mountu repozitáře |
| image `pwe-static` (základ bez DB ovladače) | běh webu bez databáze | **zrušen** — web bez databáze běží nad `pwe-base`; `make run … PROFILE=static` ho vybere sám, přímé `docker compose` potřebuje `PWE_FCGI_IMAGE=pwe-base` ([Vývojový stack](#vývojový-stack-docker-composeyml)) |
| `pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres`, `pwe-debugger` | závislosti, bez enginu a bez webu | totéž — závislostní image; popisek `version` je prázdný |
| image vzorových webů | neexistovaly (vzorová nasazení v Kubernetes si image stavěla sama) | `pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres`; staví je `make images` i pipeline ([Image vzorových webů](#image-vzorových-webů)) |
| `Dockerfile` webu | `FROM …/pwe:${PWE_ENGINE_TAG} AS engine`, `FROM …/pwe-<profil>:${PWE_IMAGE_TAG}`, `COPY --from=engine`; výchozí `PWE_IMAGE_TAG=master` | jediný `FROM …/pwe-<profil>:${PWE_IMAGE_TAG}` (web bez databáze `pwe-base`), výchozí `latest`, engine `COPY` z kontextu sestavení; `PWE_ENGINE_TAG` zanikl → `Dockerfile` vygeneruj znovu ([Dockerfile ze starší šablony](#dockerfile-ze-starší-šablony)) |
| `make images` | 7 image; tag z větve nebo z `PWE_IMAGE_TAG`; pojistky kolem větve a tagu tvaru verze | 9 image s tagy `<verze>` a `latest`; `PWE_IMAGE_TAG` se při sestavení nepoužívá; cíle `pwe` a `static` skript odmítne |
| `docker-bake.hcl` | proměnné `TAG` a nepovinná `VERSION` | proměnná `TAG` zanikla, `VERSION` je povinná |
| pipeline Images | publikoval `push` do kterékoli větve | publikuje jen výchozí větev a větve z proměnné repozitáře `PUBLISH_BRANCHES` |
| vzorová nasazení v Kubernetes | `make k8s-image` stavěl image `pwe-example-static` / `pwe-example-generic` a nahrával je do `K8S_REGISTRY` | nasazují se hotové `pwe-example-static` a `pwe-example-mariadb` z registru image PWE, nic se nestaví; `pweImage: pwe-example-generic` ve vlastní kopii values přepiš na `pwe-example-mariadb` ([Kubernetes](#kubernetes)) |
| `pwe_image_branch`, `pwe_image_tag_sanitize` (`images.sh`), `image_tag_sanitize()` (`PWE::ToolEnv`) | převod názvu větve na tag | zrušené; nové `pwe_image_version`, `pwe_image_names`, `pwe_profile_image` (`image_version()`, `image_names()`, `profile_image()`) |

Co udělat s existujícím webem a prostředím:

- **`Dockerfile` webu vygeneruj znovu** — `PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <dočasný
  adresář>` a převezmi z výsledku `Dockerfile`; `make check WEB=<web>` na starou šablonu upozorní
  ([Dockerfile ze starší šablony](#dockerfile-ze-starší-šablony));
- **názvy zrušených image** v prostředí, `.env`, vlastním compose a CI nahraď: `pwe-static` → `pwe-base`,
  `pwe` → `pwe-debugger` (image nástrojů, `PWE_TEST_IMAGE`) nebo `pwe-example-static` (spustitelná
  ukázka). Nástroje na zrušený image upozorní samy (`image pwe-static byl zrusen: web bez databaze bezi
  nad pwe-base, vzorovy web bez databaze je image pwe-example-static`);
- **přímé `docker compose` s profilem `static`** doplň o `PWE_FCGI_IMAGE=pwe-base`.

Místní image s tagy podle větve (`ghcr.io/kukam/pwe-*:pwe.ai`, `…:master`) a místní image `pwe`
a `pwe-static` už nic nepoužívá ani neaktualizuje — po `make images` je lze smazat (`docker image rm`).
Běžící vývojový stack je používá do příštího `make run`, který kontejnery vytvoří znovu z image
`<verze>`. Totéž platí pro registr: tagy podle větve ani balíčky `pwe` a `pwe-static` pipeline nemaže,
smaž je ručně v nastavení balíčků.

## Vývojový stack (`docker-compose.yml`)

```bash
make run WEB=<web> PROFILE=mariadb [ARGS=-d]      # = PWE_WEBAPP=<web> COMPOSE_PROFILES=mariadb PWE_FCGI_IMAGE=pwe-mariadb PWE_IMAGE_TAG=<verze> docker compose up
make run WEB=<web> PROFILE=static                 # web bez databáze: služba fcgi běží v pwe-base (PWE_FCGI_IMAGE=pwe-base)
```

| Služba | Co dělá |
| --- | --- |
| `webproxy` (nginx) | port `7778`; `/assets/`, `/static/` a `/uploadfile/` servíruje z disku (nejdřív `webapps/<web>` včetně volume s nahranými soubory, pak `PWE/assets`), ostatní předává FastCGI na `pwe-fcgi-1..3:7779`, `/debug.cgi` na debugger |
| `fcgi` ×3 | závislostní image profilu: `pwe-<profil>`, u profilu `static` `pwe-base` (`PWE_FCGI_IMAGE`); engine `perl /PWE/PWE/pwe.fcgi` s `PWE_CONF_pwe_home=/PWE/webapps/<web>`, `PWE_CONF_pwe_core=/PWE/PWE`, `FCGI_SOCKET_PATH=:7779`; repozitář mountován do `/PWE` — image engine ani web neobsahuje, běží pracovní kopie |
| `mariadb` / `mysql` / `postgres` | databáze podle profilu (porty 7776 / 7777 / 7775), přihlášení `pwe`/`pwe`, DB `pwe` (`docker-compose/docker-compose_<profil>.env`) |
| `debugger` | image `pwe-debugger` (všechny DB ovladače + ladicí nástroje, bez enginu a bez webu), `sleep infinity` — pro VS Code debugger a ruční příkazy; repozitář mountován do `/PWE`. Má `init: true`: `sleep infinity` jako proces č. 1 by na `SIGTERM` nereagoval a `docker compose down` by na kontejner čekal až do vypršení limitu |
| `webapps/<web>/conf/local.env` | volitelný soubor s proměnnými, který načítají služby `fcgi` i `debugger` (`env_file`, `required: false`): SMTP účet, hesla a další `PWE_CONF_*` přepisy mimo git (vzor `conf/local.env.example` v e-shopu) |
| `mailpit` | vývojový SMTP server (port `1025` uvnitř sítě, UI <http://127.0.0.1:8025>): zachytí e-maily z fronty `Services::Email`, když má web `smtp_primary => { host => "mailpit", port => 1025 }` |

Image služeb skládá compose z proměnných prostředí:

| Služba | Image |
| --- | --- |
| `fcgi` | `${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}/${PWE_FCGI_IMAGE:-pwe-${COMPOSE_PROFILES:-mariadb}}:${PWE_IMAGE_TAG:-latest}` |
| `debugger` | `${PWE_IMAGE_REGISTRY:-ghcr.io/kukam}/pwe-debugger:${PWE_IMAGE_TAG:-latest}` |

`PWE_FCGI_IMAGE` je název závislostního image služby `fcgi` bez registru a tagu. Výchozí
`pwe-<COMPOSE_PROFILES>` platí pro databázové profily; **profil `static` vlastní image nemá a běží nad
`pwe-base`**, což compose z názvu profilu odvodit neumí. `make run` (`PWE/tools/run-webapp.sh`)
proměnnou nastavuje sám; **přímé volání `docker compose` s profilem `static` ji potřebuje výslovně** —
bez ní hledá neexistující image `pwe-static`:

```bash
COMPOSE_PROFILES=mariadb docker compose up                                                # vzorový web s databází (example-db.web)
PWE_WEBAPP=example.web COMPOSE_PROFILES=static PWE_FCGI_IMAGE=pwe-base docker compose up  # vzorový web bez databáze
```

`make run` nastaví sám i registr a tag — tag na verzi enginu z `PWE/VERSION`
([Výběr image v nástrojích](#výběr-image-v-nástrojích)) — a vše vypíše
(`[run-webapp] web=… profil=… registr=ghcr.io/kukam tag=2.2.1 image=pwe-mariadb -> docker compose up --remove-orphans`).
Přímé `docker compose up` bez těchto proměnných použije tag `latest`. Když image této verze nemáš
místně ani v registru (typicky po zvýšení `PWE/VERSION`), sestav je (`make images`) nebo spusť stack
s tagem, který místně máš (`PWE_IMAGE_TAG=<tag>`), případně s `PWE_IMAGE_TAG=latest`.

**Který web běží, určuje compose, ne image.** Závislostní image žádný web ani engine neobsahuje
a nemá zapečené `PWE_CONF_pwe_home` ani `PWE_PROFILE`; služba `fcgi` je nastavuje sama (`working_dir`,
`PWE_CONF_pwe_home=/PWE/webapps/${PWE_WEBAPP}`, `PWE_PROFILE=${COMPOSE_PROFILES}`) a engine i web
dostává mountem repozitáře do `/PWE`. Služby `fcgi` a `debugger`
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
([nginx](#nginx-docker-composedocker-compose_nginxconf)). Zastavení (`make down`, `make restart`,
`Ctrl+C`) posílá procesům `fcgi` signál `SIGTERM`: rozpracovaný request doběhne a proces skončí
s kódem 0 ([Ukončení procesu](#ukončení-procesu-sigterm)).

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
  (u PostgreSQL `… Connection refused`). Migraci schématu provede jen jeden ze tří procesů `fcgi`, ostatní na něj
  počkají — v logu `[I] … Dbversion: migraci databaze dbid:db1 provadi jiny proces, cekam na zamek spojeni (…)`
  ([Migrace schématu při startu](#migrace-schématu-při-startu)). Obojí je při startu v pořádku. První start MySQL
  (zakládání datového adresáře, zhruba 8 s) se do limitu vejde těsně; trvá-li déle, proces `fcgi` skončí
  (`Unable connect to db1, poolid 0 bye...`), Docker ho restartuje (`restart: unless-stopped`) a napodruhé se
  připojí. Další starty nad existujícím volume znamenají zpravidla jeden neúspěšný pokus.

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
Dockeru — jinde uveď vlastní DNS). Běží-li nginx na stejném stroji (nebo ve stejném podu) jako engine,
nech engine poslouchat jen na loopbacku (`FCGI_SOCKET_PATH=127.0.0.1:7779`); k unix socketu se nginx
připojí jen tehdy, když do něj smí zapisovat — výchozí práva jsou 0770, viz
[FastCGI socket](#fastcgi-socket).

**`fastcgi_keep_conn on` nezapínej** (v dodané konfiguraci je zakomentované). Jeden proces enginu
obsluhuje jedno spojení: spojení, které si drží jeden worker nginx, blokuje proces pro ostatní
workery a jejich requesty čekají až do vypršení limitu. Při ukončování procesu navíc knihovna FastCGI
request, na který čeká na drženém spojení, neobslouží ([Ukončení procesu](#ukončení-procesu-sigterm)).

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
| `PWE_CONF_pwe_home` | adresář webu (povinné, když web neleží v adresáři enginu); zapečenou ji má jen image webu — vlastního i vzorového (`pwe-example-*`) — spolu s `PWE_PROFILE`; závislostní image ji nemají, ve vývojovém stacku ji nastavuje compose |
| `PWE_CONF_pwe_core` | kořen enginu (`pwe.core`) = adresář `PWE/` s `pwe.fcgi`; výchozí je adresář skriptu `pwe.fcgi`; `pwe-base` a všechny image z něj mají zapečeno `/PWE/PWE` |
| `PWE_CONF_<sekce>_<klic>` | přepis libovolného klíče `web.conf` (`PWE_CONF_pwe_development=0`, `PWE_CONF_log_loglevel=1`, `PWE_CONF_web_admin_password=…`) |
| `PWE_CONF_dbi_<dbid>_<klic>` | přepis připojení k DB (`PWE_CONF_dbi_db1_host`, `_login`, `_password`, `_database`) a dalších klíčů databáze (`_trayconnect`, `_dbversion_session_lock`, …) |
| `FCGI_SOCKET_PATH` | kde engine poslouchá: `:7779` (TCP, všechna rozhraní), `127.0.0.1:7779` (TCP, jen dané rozhraní) nebo cesta k unix socketu; bez ní engine obslouží jeden request a skončí (CGI/cron režim); v žádném image zapečená není ([FastCGI socket](#fastcgi-socket)) |
| `FCGI_SOCKET_PERM` | práva unix socketu zapsaná **osmičkově** (`0660`, `660`, `0777`), výchozí `0770`; u adresy TCP se nepoužívá |
| `FCGI_LISTEN_QUEUE` | délka fronty čekajících spojení (výchozí 100) |
| `FCGI_DAEMONIZE` | odpojit od terminálu (mimo kontejnery) |
| `PWE_PROFILE` | pro `entrypoint.sh`: `mariadb`, `mysql` nebo `postgres` = který `conf/<profil>.conf` nalinkovat jako `conf/database.conf`; se `static` nebo bez ní se `conf/database.conf` nemění, neznámá hodnota vypíše varování ([Co je v `pwe-base`](#co-je-v-pwe-base)). Image webu (vlastního i vzorového) ji má zapečenou (profil, pro který byl sestaven), službám `fcgi` a `debugger` ji předává compose |
| `TZ` | časové pásmo (např. `Europe/Prague`), ale jen pro start enginu — pro požadavky ho musí předat webserver (`fastcgi_param TZ`) nebo nastavit `/etc/localtime`, viz [Časové pásmo](#časové-pásmo). Databáze pásem (`tzdata`) je ve všech image |

Přepíše se jen klíč, který v konfiguraci existuje — tajné hodnoty (hesla DB, admin heslo, SMTP)
patří do prostředí/secretů, ne do souborů v gitu.

Proměnné hostitele (výběr image pro nástroje, compose a sestavení; podrobně
[Výběr image v nástrojích](#výběr-image-v-nástrojích)):

| Proměnná | Význam |
| --- | --- |
| `PWE_IMAGE_REGISTRY` | registr image, výchozí `ghcr.io/kukam` |
| `PWE_IMAGE_TAG` | tag image; nástroje bez ní berou verzi enginu z `PWE/VERSION`, compose `latest`; při `make images` se nepoužívá |
| `PWE_TEST_IMAGE` | celý název image pro nástroje (`make test`, `compile`, `check`, `cgi`, …); výchozí `<registr>/pwe-debugger:<tag>` |
| `PWE_IMAGE_REGISTRIES`, `PWE_IMAGE_SOURCE` | jen pro `make images`: seznam registrů pro publikaci do více najednou a adresa repozitáře do popisku `source` ([Lokální sestavení](#lokální-sestavení)) |
| `PWE_WEBAPP`, `COMPOSE_PROFILES` | web a profil pro `docker compose` (nastavuje `make run`) |
| `PWE_FCGI_IMAGE` | název závislostního image služby `fcgi` bez registru a tagu; výchozí `pwe-<COMPOSE_PROFILES>`, pro profil `static` musí být `pwe-base` (`make run` ho nastavuje sám, přímé `docker compose` ne — [Vývojový stack](#vývojový-stack-docker-composeyml)) |
| `PWE_TEST_LOCK_WAIT` | jak dlouho (sekundy, výchozí 600, `0` = vůbec) má `make test` čekat, když nad stejnou pracovní kopií už běží jiný běh testů ([18 — Testy](18-testy.md#testy-enginu)) |
| `KUBE_CONTEXT`, `K8S_*` | nasazení do Kubernetes (`make k8s-*`, [Kubernetes](#kubernetes)) |

## Běh procesu enginu

Jak proces `pwe.fcgi` naslouchá, jak startuje nad databází a jak se ukončuje. Popis platí pro engine
od verze 2.2.1; co se proti starším verzím změnilo a co má udělat provozovatel, shrnuje
[Přechod na verzi 2.2.1](#přechod-na-verzi-221).

### FastCGI socket

Kde engine poslouchá, určuje `FCGI_SOCKET_PATH`. Socket otevírá až **po startu** — po připojení
k databázi a po migracích schématu; do té doby jsou spojení odmítána (s tím počítá `startupProbe`
ve vzorových nasazeních v Kubernetes).

| Hodnota | Kde engine poslouchá |
| --- | --- |
| `:7779` | TCP port 7779 na všech rozhraních (`*:7779` je totéž) |
| `127.0.0.1:7779` | TCP port 7779 jen na daném rozhraní — číslo IPv4, nebo jméno s jedinou adresou |
| `/run/pwe/web.sock` | unix socket (starý soubor na téže cestě se před otevřením smaže) |
| *(nenastavena)* | žádný socket: engine obslouží jeden request z prostředí a skončí (režim CGI); spustí-li ho webserver nebo správce procesů FastCGI s naslouchajícím socketem na deskriptoru 0, obsluhuje requesty z něj |

- **Adresa `host:port`** funguje od verze 2.2.1. Starší engine uměl jen `:7779` a cestu k unix socketu
  — s `127.0.0.1:7779` skončil při startu chybou `Couldn't chmod(127.0.0.1:7779)`.
- Tvar hodnoty rozlišuje knihovna FastCGI: když za **první** dvojtečkou následuje nenulové číslo portu,
  jde o adresu TCP, jinak o cestu k unix socketu. Jméno hosta musí mít jedinou adresu — `localhost`
  v kontejneru zpravidla neprojde (`Cannot resolve host name …`), piš IP adresu. Obsazený port hlásí
  knihovna (`bind/listen: Address already in use`) a proces skončí.
- **Engine za webserverem na stejném stroji nebo ve stejném podu** nech poslouchat jen na loopbacku
  (`127.0.0.1:7779`): port pak není dostupný odjinud a nikdo nemůže obejít webserver a podvrhnout
  enginu adresu klienta nebo HTTPS. Tak to mají vzorová nasazení v Kubernetes. Ve vývojovém stacku
  běží nginx v jiném kontejneru, proto tam zůstává `:7779`.
- Úspěšné otevření zapíše do logu (úroveň info) `FastCGI socket :7779: adresa TCP`, resp.
  `FastCGI socket /run/pwe/web.sock: unix socket s pravy 0770`.

**Práva unix socketu.** K unix socketu se smí připojit ten, kdo do něj smí zapisovat. Výchozí práva
jsou **0770** — vlastník a skupina procesu enginu; jiná nastaví `FCGI_SOCKET_PERM` zapsaná osmičkově
(`0660`, `660`, `0777`). Jiná hodnota než tři až čtyři osmičkové číslice ukončí start chybou
`FCGI_SOCKET_PERM='…' neni osmickovy zapis prav unix socketu (napr. 0660 nebo 0777)`.

> **Proměnnou `FCGI_SOCKET_PERM` jsi nastavoval už dřív?** Do verze 2.2.0 ji četla knihovna
> `CGI::Fast` jako **desítkové** číslo, takže fungující hodnoty byly `432` (= 0660), `438` (= 0666)
> nebo `511` (= 0777). Od 2.2.1 se čte osmičkově: přepiš ji na `0660`, `0666`, `0777`. Hodnotu
> s číslicí 8 nebo 9 (`438`) engine při startu odmítne; `432` nebo `511` jsou ale platný osmičkový
> zápis a daly by jiná práva (0432, 0511) — skutečná práva socketu proto po aktualizaci zkontroluj
> v logu (`FastCGI socket …: unix socket s pravy …`).

> **Změna proti verzím do 2.2.0.** Engine měl dostat práva 0770, kvůli chybě se ale hodnota četla
> desítkově a socket vznikal s právy **1402**: vlastník směl jen číst, skupina nic a zapisovat — tedy
> připojit se — směli „ostatní“. Od 2.2.1 má socket skutečných 0770. **Nasazení, kde webserver běží
> pod jiným uživatelem než engine a není ve skupině jeho procesu** (typicky engine jako `root`
> a nginx jako `www-data` nebo `nginx`), se po aktualizaci k socketu nepřipojí — nginx hlásí
> `connect() to unix:… failed (13: Permission denied)` a vrací 502. Řešení (jedno z nich):
>
> - dej webserver a engine do společné skupiny (uživatele webserveru přidej do skupiny procesu
>   enginu, nebo engine spouštěj se skupinou webserveru — v `systemd` `Group=www-data`) a nech
>   výchozí 0770, případně `FCGI_SOCKET_PERM=0660`;
> - nastav `FCGI_SOCKET_PERM=0666` — připojit se pak smí kdokoli, kdo se dostane do adresáře
>   socketu; přístup omez právy toho adresáře;
> - přejdi na TCP na loopbacku: `FCGI_SOCKET_PATH=127.0.0.1:7779`.

### Ukončení procesu (SIGTERM)

Signál `TERM` (`docker stop`, `docker compose down`, ukončení podu v Kubernetes, `systemctl stop`)
ukončí engine **pořádaně a s návratovým kódem 0**:

| Kdy signál přijde | Co engine udělá |
| --- | --- |
| proces čeká na request | skončí hned: odpojí databáze a skončí |
| běží request | request doběhne s funkční databází a klient dostane **celou odpověď**; teprve pak se odpojí databáze a proces skončí. Naslouchající socket se zavře hned po signálu — další spojení už engine nepřijme (webserver dostane „connection refused“ a může request poslat jinému procesu) |
| engine startuje | start se přeruší na bezpečném místě — mezi pokusy o připojení k databázi nebo mezi kroky migrace (rozběhnutý krok se vždy dokončí a zapíše) —, nebo doběhne; v obou případech proces skončí, aniž otevře socket a přijme request |
| druhý `TERM` během dobíhání requestu | nic nemění |

- Signál `USR1` má stejný účinek jako `TERM` (ukončovací signál knihovny FastCGI, posílá ho
  `mod_fastcgi`). `INT` handler nemá — `Ctrl+C` ukončí proces hned (pod debuggerem ho používá
  `debug.cgi`).
- Do logu (úroveň info) se zapíše `PWE server ukoncen signalem TERM`; při ukončení během startu
  `Start PWE serveru prerusen signalem TERM` (s dovětkem `(start dobehl, socket se neotevira)`, když
  start doběhl celý) a při přerušené migraci navíc
  `Dbversion: migrace dbid:<dbid> prerusena zadosti o ukonceni (dokoncene kroky: <n>), zamky uvolneny`.
- Na Linuxu čeká engine na spojení sám (neblokující socket, probuzení nejpozději po 1 s), takže se
  signál neztratí a nezdrží ho ani prázdná spojení (TCP sondy load balanceru nebo Kubernetes).
- Skutečná chyba čekání na request ukončí engine s kódem **1** a hláškou
  `[E] … PWE server konci: cekani na request FastCGI selhalo (<chyba>)` (dřív tichý konec s kódem 0).

Do verze 2.2.0 handler `TERM` jen odpojil databázi: rozpracovaný request pak doběhl bez ní a proces
po něm — stejně jako po signálu, který přišel těsně po odeslání odpovědi — neskončil, takže na něj
orchestrátor čekal až do `SIGKILL`. Signál během startu končil chybou
`Can't call method "getDbidList" on an undefined value`.

Co z toho plyne pro nasazení:

- limit na ukončení (`docker stop -t`, `terminationGracePeriodSeconds`) stačí o něco delší než
  nejdelší request — proces už na konci limitu nečeká;
- před ukončením proces nejdřív vyřaď z provozu (v Kubernetes `preStop` s krátkým čekáním, než
  ingress pod vyřadí; u vlastního nginx odebrání z `upstream`): spojení, která v okamžiku signálu
  čekala ve frontě socketu, dostanou reset a nginx request zopakuje na jiném procesu jen u metod,
  které opakovat smí;
- omezení daná knihovnou FastCGI: signál, který přijde ve chvíli, kdy knihovna čte hlavičku právě
  přijatého requestu nebo čeká na další request na spojení drženém webserverem
  (`fastcgi_keep_conn on`), tento request neobslouží — engine skončí. Volání, která signál přeruší
  vždy (`sleep`, `select`), se v rozpracovaném requestu vrátí dřív. Jiný signál s vlastním handlerem
  (handler webu) může rozpracovaný request poškodit dál — před `TERM` a `USR1` ho engine chrání.

### Migrace schématu při startu

Engine při startu provede migrace z `conf/<driver>.dbversion`
([03 — Migrace schématu](03-struktura-webu.md#migrace-schématu-confdriverdbversion)). Proti souběžné
migraci z více procesů (repliky, pody) se chrání **zámkem vázaným na databázové spojení**
(MySQL/MariaDB `GET_LOCK`, PostgreSQL poradní zámek úrovně session), který server uvolní sám, jakmile
spojení zanikne. Co to znamená v provozu:

- **Po pádu procesu uprostřed migrace** (`SIGKILL`, OOM, výměna podu) se další start zotaví sám:
  zámek spojení je volný, opuštěný zámek ve sloupci `dbversion.lockid` proces převezme, migraci dokončí
  a zapíše to do logu jako `[E]` (zkontroluj, že start doběhl). Do verze 2.2.0 zůstal `lockid`
  nastavený a všechny další starty čekaly donekonečna, dokud ho někdo ručně nevynuloval.
- **Současně startující procesy:** tabulku `dbversion` založí jen jeden a každý krok migrace proběhne
  právě jednou; ostatní na něj počkají. První start nad čistou databází trvá o zhruba sekundu déle:
  řádek do nové tabulky engine vloží až po kontrolním čtení, aby v ní při souběhu se starší verzí
  enginu nezůstaly dva. Čekání nemá časový limit — první hláška je na úrovni info,
  opakování po 30 s už na úrovni error, aby bylo vidět i při `log.loglevel => 1`. `startupProbe`
  v Kubernetes musí dlouhou migraci jiného podu unést.
- **Proces, který nemá co migrovat,** na cizí migraci nečeká — s výjimkou procesu, který si strukturu
  tabulek čte z databáze (`dao => 1` bez souboru `daomap_file`, což je výchozí stav webů
  z generátoru): ten počká, aby si nenačetl rozpracované schéma. Platí to i pro migraci procesu bez
  zámku spojení (starší verze enginu, kladný `lockid`): čeká, dokud migrace postupuje, a zámek, který
  se `dbversion_legacy_lock_wait` sekund nezměnil, převezme a hned uvolní.
- **`SIGTERM` během migrace:** rozběhnutý krok se dokončí a zapíše, další se nespustí, zámky se
  uvolní; další start pokračuje následujícím krokem.
- **Po `SIGKILL` server zámek neuvolní okamžitě**, ale až si všimne mrtvého spojení, tedy až dokončí
  nebo přeruší osiřelý příkaz (jednotky sekund, u dlouhého příkazu až do jeho konce); další start
  mezitím čeká. V MySQL a MariaDB není DDL transakční: osiřelý příkaz zůstane proveden, opakovaný krok
  pak selže a start skončí chybou s nápovědou — schéma je potřeba zkontrolovat ručně a hotový krok
  zapsat (`UPDATE dbversion SET dbversion = N`).

Nastavení v `conf/<profil>.conf` (sekce `dbi`, [03](03-struktura-webu.md#confdatabaseconf-a-driverconf)):

| Klíč | Výchozí | Význam |
| --- | --- | --- |
| `dbversion_session_lock` | zapnuto | `0` = bez zámku spojení: chování starších verzí (jen sloupec `lockid`; po pádu procesu uprostřed migrace je potřeba ruční `UPDATE dbversion SET lockid = 0`) |
| `dbversion_legacy_lock_wait` | `300` | po kolika sekundách **beze změny** převezme proces se zámkem spojení cizí `lockid` procesu bez něj (starší verze enginu); `0` = nikdy |

Hodnoty mají být **stejné u všech procesů jednoho webu**. Přepis proměnnou
(`PWE_CONF_dbi_db1_dbversion_session_lock=0`) funguje jen tehdy, když klíč v konfiguraci webu
existuje: generátor ho zapisuje od verze 2.2.1, do staršího webu ho doplň ručně.

Kdy zámek spojení **vypnout** (u všech procesů webu): PostgreSQL za poolerem v režimu transaction
pooling (PgBouncer `pool_mode = transaction` — serverová spojení se mezi transakcemi střídají, zámek
úrovně session tam držet nejde; ovladač takový stav pozná jen jako pojistku) a MySQL/MariaDB
v clusteru s více zapisovacími uzly (Galera — `GET_LOCK` platí jen na jednom uzlu). Galera ověřená
není. Za PgBouncerem (1.24 a 1.26, `pool_mode = transaction`) je ověřeno toto: se zapnutým zámkem
spojení se kroky migrace neopakují (ovladač pozná serverové spojení, na kterém zámek drží jiný klient,
a pokračuje jen se sloupcem `lockid`), ale zámek často zůstane viset na serverovém spojení poolu
a další start s čekající migrací na něj čeká, dokud pooler spojení nezavře — proto ho tam vypni.

**Postupná výměna starší verze enginu (≤ 2.2.0) za novou.** Starší engine zámek spojení nezná
a chrání se jen sloupcem `lockid`:

- starší proces na novější počká (vidí nenulový `lockid`);
- novější proces pozná zámek staršího podle znaménka — proces se zámkem spojení zapisuje `lockid`
  záporný, proces bez něj kladný. Na kladný cizí `lockid` čeká, dokud migrace postupuje (mění se
  verze nebo zámek), a převezme ho až po `dbversion_legacy_lock_wait` sekundách beze změny;
- krok migrace, který staršímu enginu trvá déle než tato doba, se od opuštěného zámku rozlišit nedá
  — nová verze by ho převzala a kroky by proběhly dvakrát. Má-li web takto dlouhé kroky, nastav
  dobu delší než nejdelší krok (nebo `0`), případně nenasazuj novou verzi ve chvíli, kdy proces
  starší verze právě migruje. Běžící starší procesy, které nemigrují, nevadí.

Kontrola zámku přímo v databázi: MySQL/MariaDB `SELECT IS_USED_LOCK('pwe.dbversion.<databáze>')`
(jméno delší než 64 znaků se nahrazuje `pwe.<md5>`), PostgreSQL
`SELECT * FROM pg_locks WHERE locktype = 'advisory'`; stav migrace `SELECT * FROM dbversion`.

Hlášky v logu:

| Hláška | Význam |
| --- | --- |
| `[I] Dbversion update to id <N>` | krok migrace `N` proběhl a je zapsaný |
| `Dbversion: migraci databaze dbid:<dbid> provadi jiny proces, cekam na zamek spojeni (<n> s)` | migruje jiný proces, tento čeká; poprvé `[I]`, pak každých 30 s `[E]`. V pořádku, dokud cizí migrace běží; dovětek `… cekam kvuli nacteni struktury tabulek (dao)` = sám nemá co migrovat. U PostgreSQL opakovaná hláška připomíná, že za poolerem v režimu transaction pooling mohl zámek zůstat na serverovém spojení poolu, i když nikdo nemigruje — pak zámek spojení vypni (`dbversion_session_lock => 0`); uvolní se, až pooler spojení zavře |
| `[E] Dbversion: zamek lockid:<N> v tabulce dbversion (dbid:<dbid>) je opusteny - proces, ktery ho nastavil, uz nebezi (zamek spojeni je volny). Prebiram ho; posledni krok migrace (po verzi <V>) mohl zustat nedokonceny.` | zotavení po pádu procesu uprostřed migrace; zkontroluj, že start doběhl |
| `[I] Dbversion: zamek lockid:<N> … nastavil proces bez zamku spojeni - migraci zrejme provadi starsi verze enginu … Cekam, dokud migrace postupuje (…); kdyz se verze ani zamek nezmeni, prevezmu ho za <n> s (…)` | migruje proces starší verze (nebo s vypnutým zámkem spojení), tento čeká |
| `[E] Dbversion: zamek lockid:<N> … se <n> s nezmenil (…) - proces bez zamku spojeni, ktery ho nastavil (zrejme starsi verze enginu), uz nejspis nebezi. Prebiram ho; …` | zámek procesu bez zámku spojení se po `dbversion_legacy_lock_wait` sekundách nezměnil a byl převzat |
| `[E] Dbversion is locked by lockid:<N> (dbid:<dbid>) - migraci provadi jiny proces, cekam (<n> s). Pokud zadny proces nemigruje (zamek zustal po padu procesu), uvolni ho rucne: UPDATE dbversion SET lockid = 0` | jen **bez zámku spojení** (vypnutý, nebo ho ovladač nedal): čekání bez limitu, hláška poprvé a pak každých 30 s. Když žádný proces nemigruje, uvolni zámek ručně |
| `[E] Dbversion: zamek spojeni neni k dispozici (dbid:<dbid>, …) - soubezne migraci brani jen sloupec dbversion.lockid` | ovladač zámek spojení nedal (chyba dotazu, pooler v režimu transaction pooling); proces pokračuje ve starém režimu |
| `[E] Dbversion: tabulka dbversion (dbid:<dbid>) nema zadny radek …` | pád mezi založením tabulky a prvním řádkem; se zámkem spojení engine řádek doplní sám (až když je tabulka bez řádku i po dalším čtení za cca 1 s — může ji právě zakládat starší verze enginu), bez něj čeká a radí ruční `INSERT INTO dbversion (dbversion,lockid) VALUES (0,0)` |
| `[E] Dbversion: tabulka dbversion (dbid:<dbid>) existuje, ale ne tam, kde ji hleda kontrola existence … - pouzivam ji; CREATE TABLE selhal: …` | PostgreSQL: tabulka leží v jiném schématu, než je klíč `schema` v konfiguraci (rozhoduje `search_path` účtu); engine ji použije. Srovnej `schema` s `search_path` |
| `[I] Dbversion: tabulku dbversion (dbid:<dbid>) mezitim zalozil jiny proces … - pouzivam ji; CREATE TABLE selhal: …` | souběžný první start nad čistou databází se starší verzí enginu: tabulku založila ona. V pořádku (chybu samotného `CREATE TABLE` engine i tak zapíše jako `[E]`) |
| `[E] Dbversion: zamek spojeni (dbid:<dbid>) se nepodarilo uvolnit dotazem - spojeni pool 0 se zavira, zamek uvolni server` | úklid po migraci; engine spojení otevře znovu. U PostgreSQL hláška dodává, že za poolerem v režimu transaction pooling zámek zůstane na serverovém spojení poolu, dokud ho pooler nezavře (výchozí `server_idle_timeout` PgBounceru je 600 s), a další starty na něj čekají — zámek spojení tam vypni |

Start končí chybou (proces skončí a orchestrátor ho spustí znovu), když migrace selže:
`Dbversion fail id:<N> : <chyba> …` s textem SQL (po převzetí opuštěného zámku navíc s upozorněním,
že krok `N` mohl být už dřív částečně proveden), `Dbversion fail id:<N> : krok probehl, ale jeho verzi
se nepodarilo zapsat …`, `Dbversion: <soubor>: <důvod>` (soubor migrací nejde načíst) a
`Dbversion: tabulku dbversion nelze precist | nelze zalozit …`, `zamek lockid nelze nastavit …`,
`opusteny zamek migrace nelze prevzit …`, `zamek lockid se nepodarilo ziskat ani na 20 pokusu …`.
Dřív engine v části těchto situací tiše pokračoval nebo čekal donekonečna.

## Kubernetes

Web se do Kubernetes nasazuje jako **jeden image se závislostmi, enginem i webem** obecným chartem
`oci://registry.nixys.ru/nuc/nxs-universal-chart` verze **3.2.2**. Co se nasadí, popisuje soubor
hodnot `kubernetes/values-<název>.yml`; release se jmenuje `pwe-<název>` a web běží na
`https://pwe-<název>.<doména>`. Jsou dva druhy nasazení a liší se jen tím, odkud se image bere —
rozhoduje `generic.pweImage` ve values:

- **vzorové nasazení** (`pweImage` je `pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql`
  nebo `pwe-example-postgres`; `pweWeb` a `pweProfile` musí názvu odpovídat) používá hotový image
  vzorového webu z registru image PWE — **nic se nestaví**;
- **vlastní web** (jakýkoli jiný název image) má vlastní image: `make k8s-image` ho sestaví
  z `webapps/<web>/Dockerfile` z kořene repozitáře — závislostní image `pwe-<profil>` (web bez databáze
  `pwe-base`) + engine z pracovní kopie + web ([Image vlastního webu](#image-vlastního-webu)) —
  a nahraje do registru `K8S_REGISTRY`.

Názvy image PWE jsou **vyhrazené**: jako `pweImage` vlastního webu je skript odmítne
(`generic.pweImage '…' je vyhrazeny nazev image PWE (…)`), i s cestou (`ns/pwe-base`). Jsou to
závislostní image `pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` a `pwe-debugger`, všechny názvy
`pwe-example-*` a zrušené `pwe` a `pwe-static`.

V repozitáři jsou dvě hotová vzorová nasazení:

| Název | Image | Co se nasadí |
| --- | --- | --- |
| `static` (`kubernetes/values-static.yml`) | `ghcr.io/kukam/pwe-example-static` (`pwe-base` + engine + `example.web`, bez databáze) | Deployment s pody nginx + engine (`fcgi`), Service, Ingress s certifikátem z cert-manageru |
| `generic` (`kubernetes/values-generic.yml`) | `ghcr.io/kukam/pwe-example-mariadb` (`pwe-mariadb` + engine + `example-db.web`) | totéž + MariaDB (StatefulSet se svazkem) a Secret s hesly (vzor `kubernetes/secrets-generic.example.yml`) |

Vzorová nasazení jsou **ukázka, ne veřejný provoz**: vzorový web běží ve vývojovém režimu a každý
návštěvník je ve skupině `admin` včetně generátoru kódu `pweCreator`. Kontejner `fcgi` to při každém
startu připomene varováním `[entrypoint] VAROVANI: bezi vzorovy web …`
([Image vzorových webů](#image-vzorových-webů)).

Nasazení i kontrolu dělají cíle `make` (skript `PWE/tools/k8s.sh`):

```bash
make k8s-deploy   K8S=static     # nasadí nebo aktualizuje release pwe-static (helm upgrade --install)
make k8s-status   K8S=static     # stav releasu
make k8s-test     K8S=static     # ověří web přes HTTPS
make k8s-template K8S=static     # vypíše manifesty, které by se nasadily (ke clusteru se nepřipojuje)
make k8s-logs     K8S=static     # logy kontejnerů releasu
make k8s-delete   K8S=static     # odinstaluje release (svazek databáze zůstává)
make k8s-image    K8S=mujweb     # jen vlastní web: sestaví image webu pro platformu clusteru a nahraje ho do registru
```

U vzorového nasazení `make k8s-image` nic nestaví — vypíše
`[k8s] nasazeni <název> je vzorove: pouziva hotovy image vzoroveho webu … - nic se nestavi` a skončí
kódem 0. U vlastního webu odmítne `Dockerfile` ze starší šablony ještě před sestavením
(`webapps/<web>/Dockerfile je z drivejsi sablony (…)`,
[Dockerfile ze starší šablony](#dockerfile-ze-starší-šablony)) a `Dockerfile` webu s databází
nasazovaný s `pweProfile: static`.

**Kontext clusteru je povinný a vždy výslovný.** Cílový cluster určuje `KUBE_CONTEXT` (v místním
souboru `kubernetes/local.env`, který není v gitu — vzor `kubernetes/local.env.example`, nebo jako
proměnná `make k8s-deploy K8S=static KUBE_CONTEXT=<kontext>`). Nemá výchozí hodnotu: skript **nikdy
nepoužije aktuální kontext `kubectl`** a každému příkazu `helm` i `kubectl` ho předává výslovně;
bez něj nic nenasadí. Přepínače, které by cluster, přihlášení nebo namespace určily jinak
(`--kube-context`, `--kubeconfig`, `--context`, `--server`, `--namespace`, … v `ARGS`), skript odmítne;
proměnné prostředí se stejným účinkem (`HELM_KUBE*`, `HELM_NAMESPACE`, `KUBERNETES_MASTER`) před
spuštěním zruší a oznámí to. Stejně tak ruční příkazy: `kubectl` vždy s `--context <kontext>`, `helm`
vždy s `--kube-context <kontext>`.

**Který image se nasadí.** Nasazuje se podle digestu: `make k8s-deploy` si v registru zjistí digest
tagu a pody dostanou odkaz `<image>:<tag>@sha256:…` — oba tagy image se přepisují, takže jen tak
v clusteru běží přesně to, co bylo v registru v okamžiku nasazení.

| Proměnná | Vzorové nasazení | Vlastní web |
| --- | --- | --- |
| `K8S_REGISTRY` — registr, ve kterém image je | výchozí `PWE_IMAGE_REGISTRY`, tedy `ghcr.io/kukam` | **povinný:** registr, do kterého `make k8s-image` nahrává |
| `K8S_PULL_REGISTRY` — odkud image tahá cluster | výchozí `K8S_REGISTRY` (jiný jen s proxy cache) | totéž |
| `K8S_IMAGE_TAG` — tag nasazovaného image | výchozí `PWE_IMAGE_TAG`, jinak verze z `PWE/VERSION` | výchozí `latest` (na `PWE_IMAGE_TAG` nezávisí) |
| `PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` | registr a tag nasazovaného image `pwe-example-<profil>` | závislostní image `pwe-<profil>` (web bez databáze `pwe-base`), nad kterým se image webu staví; verzi enginu neurčují — engine se bere z pracovní kopie |

Hodnoty `K8S_REGISTRY`, `K8S_PULL_REGISTRY` a `K8S_IMAGE_TAG` zapsané v `kubernetes/local.env` platí
pro **všechna** nasazení včetně vzorových; vzorovým nasazením stačí `KUBE_CONTEXT`, `K8S_DOMAIN`
a `K8S_ISSUER`. Image vzorového webu s tagem verze musí být v registru dřív, než se nasazuje (publikuje
ho pipeline z výchozí větve nebo z větve v `PUBLISH_BRANCHES`; `make images` ho staví jen do místního
Dockeru); jinak nasazení skončí chybou `digest image … nelze zjistit` — nejnovější publikovaný image
nasadí `K8S_IMAGE_TAG=latest`. Míří-li `K8S_REGISTRY` na registr, kde pod názvem `pwe-example-static`
zůstal image z verze 2.2.0 (tehdy si ho vzorové nasazení stavělo samo), nasadil by se s tagem `latest`
ten starý — vzorová nasazení proto nasazuj z registru image PWE.

**Engine v podu** poslouchá jen na `127.0.0.1:7779` (`FCGI_SOCKET_PATH`), tedy jen pro nginx téhož
podu; kontejner `fcgi` port 7779 nedeklaruje a z jiných podů dostupný není, ani v clusteru, kde se
`NetworkPolicy` neuplatní. Vyžaduje engine 2.2.1 nebo novější — starší skončí při startu chybou
`Couldn't chmod(127.0.0.1:7779)` (pak ve values `":7779"`). Sondy jsou `exec` na `127.0.0.1:7779`;
`startupProbe` kryje připojení k databázi a migrace (engine otevře socket až po nich), `preStop`
dává ingressu čas pod vyřadit, než engine dostane `SIGTERM` a pořádaně skončí
([Běh procesu enginu](#běh-procesu-enginu)).

Požadavky na cluster (ingress controller, cert-manager, DNS, třída úložiště, přístup k registru),
všechny proměnné `K8S_*`, nasazení bez `make`, vlastní web (i sestavení pro jinou platformu), hesla,
škálování a řešení potíží popisuje [`kubernetes/README.md`](../kubernetes/README.md). Pro nasazení
v Kubernetes platí totéž co pro image webu jinde: konfigurace enginu přes `PWE_CONF_*` v `env` (přepíše
se jen klíč, který v konfiguraci webu existuje), časové pásmo přes `fastcgi_param TZ` v nginx podu,
tajné hodnoty a soukromé klíče ze Secretu, ne z image. `PWE_CONF_pwe_home` a `PWE_PROFILE` se
nenastavují — má je zapečené image webu.

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

Unix socket vzniká s právy 0770: webserver se k němu připojí, jen když běží pod stejným uživatelem
nebo ve stejné skupině jako engine (v `systemd` např. `User=pwe`, `Group=www-data`); jinak nastav
`FCGI_SOCKET_PERM` nebo použij `FCGI_SOCKET_PATH=127.0.0.1:7779` ([FastCGI socket](#fastcgi-socket)).
`systemctl stop` posílá `SIGTERM`, na který engine pořádaně skončí s kódem 0
([Ukončení procesu](#ukončení-procesu-sigterm)).

## Produkční checklist

- [ ] `pwe.development => 0` (žádný DataDump, žádná vývojová skupina `admin`)
- [ ] unikátní `http.cookie_name`, správný `http.base_url`, `web.email_admin`, `pwe.smtp_servers`
- [ ] hesla přes `PWE_CONF_*` (DB, admin, SMTP: `PWE_CONF_smtp_primary_authpw`), ne v `conf/*`; e-mail ověřit `make smtp-test`
- [ ] soukromé klíče (platební brána, klientské certifikáty) kontejner dostává mountem nebo secretem
      a cestu přes `PWE_CONF_*` — do image webu se nezapékají
      ([Image vlastního webu](#image-vlastního-webu))
- [ ] `log.loglevel => 1`, `logout => "STDERR"` (sbírá Docker/k8s) nebo soubor s rotací
- [ ] ukázkové stránky enginu (`formExamples`, `ajaxExamples`, `responsive`) mimo `core_pages`;
      `pweCreator` jen pro skupinu `admin` (nebo také odebrat)
- [ ] statiku servíruje webserver (`assets/`, `static/`), zdroje webu nejsou dostupné přes HTTP
- [ ] image webu sestavený z aktuální šablony `Dockerfile` ([Image vlastního webu](#image-vlastního-webu);
      `make check` bez varování o staré šabloně): z kořene repozitáře enginu, z čistého checkoutu verze
      enginu, se kterou byl web ověřen, nad závislostním image připnutým na verzi
      (`--build-arg PWE_IMAGE_TAG=<verze>`, ne výchozí `latest`; tag verze je přepisovatelný — kdo
      potřebuje přesně jeden základ, připne digest, [Registr a tagy](#registr-a-tagy)); image webu má
      vlastní neměnný tag (nebo se nasazuje podle digestu jako u `make k8s-deploy`); web nemá
      vlastní `entrypoint.sh` a popisky `version`/`source`/`licenses` v `Dockerfile` jsou doplněné
- [ ] v provozu neběží image vzorového webu `pwe-example-*` (ukázka: každý návštěvník je ve skupině
      `admin`) — v logu není varování `[entrypoint] VAROVANI: bezi vzorovy web …`
- [ ] `FCGI_SOCKET_PATH`: za webserverem na stejném stroji nebo ve stejném podu jen loopback
      (`127.0.0.1:7779`), u unix socketu práva odpovídají uživateli webserveru
      ([FastCGI socket](#fastcgi-socket)); `fastcgi_keep_conn` vypnuté
- [ ] ukončování: orchestrátor posílá `SIGTERM` a limit na ukončení je delší než nejdelší request
      ([Ukončení procesu](#ukončení-procesu-sigterm))
- [ ] časové pásmo pro požadavky: `fastcgi_param TZ` ve webserveru nebo `/etc/localtime` v kontejneru (samotná proměnná `TZ` platí jen při startu, jinak UTC)
- [ ] `pwe.require_core` odpovídá verzi enginu v image
- [ ] v produkci neběží `pwe-debugger` (ladicí nástroje, překladač, klienti databází) a kontejner
      nemá namountovaný repozitář
- [ ] registr s image webu je z produkce dostupný (soukromý registr: `docker login` /
      `imagePullSecrets`)
- [ ] migrace `dbversion` prošly (log při startu), záloha DB před nasazením nové verze; za poolerem
      v režimu transaction pooling je vypnutý zámek spojení
      ([Migrace schématu při startu](#migrace-schématu-při-startu))
- [ ] HTTPS před nginx (cookie dostane prefix `C1`; po změně schématu se session založí znovu)
- [ ] `make check WEB=<web>` bez `FAIL`, průchod stránek bez `[E]` v logu

## Aktualizace enginu

1. V repozitáři enginu přejdi na novou verzi (`PWE/VERSION`, `PWE/CHANGELOG.md` popisuje
   změny; major = změna kontraktu) a sestav nebo stáhni její závislostní image (`make images`).
2. Ve webu zkontroluj `pwe.require_core`, spusť `make check WEB=<web>` a projdi stránky
   (`make run`).
3. Sestav nový image webu z kořene repozitáře enginu — engine se do něj zkopíruje z pracovní kopie,
   závislostní image vybere `PWE_IMAGE_TAG` (`docker build --build-arg PWE_IMAGE_TAG=<nová verze> …`,
   [Image vlastního webu](#image-vlastního-webu)) — a nasaď. Přibyla-li v enginu položka přímo
   v `PWE/`, `make check` upozorní, že ji `Dockerfile` webu nekopíruje; pak ho vygeneruj znovu.

Web má vlastní git; verzi enginu, se kterou byl ověřen, drží v `pwe.require_core`.

### Přechod na verzi 2.2.1

Verze 2.2.1 nemění kontrakt stránek ani konfiguraci webu (`pwe.require_core => ">=2.2"` vyhovuje dál),
mění ale chování procesu a uspořádání image. Co zkontrolovat v nasazení:

| Oblast | Co se změnilo | Co udělat |
| --- | --- | --- |
| unix socket | práva jsou skutečných 0770 (dřív kvůli chybě 1402 — připojit se směli „ostatní“) | webserver pod jiným uživatelem mimo skupinu enginu: společná skupina, `FCGI_SOCKET_PERM`, nebo TCP na loopbacku ([FastCGI socket](#fastcgi-socket)) |
| `FCGI_SOCKET_PERM` | čte se osmičkově (dřív ji knihovna `CGI::Fast` četla desítkově) | hodnotu zapsanou desítkově přepiš: `432` → `0660`, `438` → `0666`, `511` → `0777` |
| `FCGI_SOCKET_PATH` | nově i `host:port` | engine za webserverem na stejném stroji nebo v podu přepni na `127.0.0.1:7779` (nepovinné) |
| `SIGTERM` | pořádané ukončení s kódem 0, rozpracovaný request doběhne | limity na ukončení lze zkrátit; `preStop` a vyřazení z provozu před ukončením ponech ([Ukončení procesu](#ukončení-procesu-sigterm)) |
| chyba čekání na request | proces končí kódem 1 a `[E]` v logu (dřív tichý kód 0) | nic; restart obstará orchestrátor |
| zámek migrace | vázaný na databázové spojení, po pádu procesu se start zotaví sám | do `conf/<profil>.conf` staršího webu doplň `dbversion_session_lock => 1` a `dbversion_legacy_lock_wait => 300` (jinak je nejde přepsat proměnnou); za PgBouncerem v režimu transaction pooling a v clusteru Galera zámek spojení vypni ([Migrace schématu při startu](#migrace-schématu-při-startu)) |
| výměna verze za běhu | starší procesy zámek spojení neznají | nenasazuj ve chvíli, kdy starší proces právě migruje, nebo měj `dbversion_legacy_lock_wait` delší než nejdelší krok migrace |
| chyby migrace | selhání zápisu verze, nečitelná tabulka `dbversion` a rozbitý soubor migrací ukončí start chybou (dřív tiché pokračování nebo čekání) | chybu oprav podle hlášky v logu |
| tagy image | jen `<verze>` a `latest`, žádné tagy podle větve | `PWE_IMAGE_TAG=master` → `latest`; vlastní compose a manifesty přepiš na `<verze>` nebo `latest` ([Přechod z tagů podle větve](#přechod-z-tagů-podle-větve)) |
| image | devět image: pět závislostních (bez enginu a webu) a čtyři image vzorových webů; image `pwe` a `pwe-static` zrušeny | `pwe-static` → `pwe-base`; přímé `docker compose` s profilem `static` doplň o `PWE_FCGI_IMAGE=pwe-base` ([Přechod z tagů podle větve](#přechod-z-tagů-podle-větve)) |
| `Dockerfile` webu | jediný `FROM` závislostního image (`pwe-<profil>`, bez databáze `pwe-base`) + engine zkopírovaný z repozitáře; `PWE_ENGINE_TAG` a `COPY --from` zanikly | `Dockerfile` vygeneruj znovu (`PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <dočasný adresář>` a převezmi z něj `Dockerfile`; `make check` na starou šablonu upozorní) a image webu sestav z kořene repozitáře ([Dockerfile ze starší šablony](#dockerfile-ze-starší-šablony)) |
| publikace image | jen z výchozí větve a z větví v `PUBLISH_BRANCHES` | má-li publikovat i jiná větev, nastav proměnnou repozitáře ([Pipeline GitHub Actions](#pipeline-github-actions)) |
| Kubernetes | vzorová nasazení berou hotové image `pwe-example-static` a `pwe-example-mariadb`; engine jen na `127.0.0.1:7779`; názvy image PWE jsou jako `pweImage` vlastního webu vyhrazené | image vzorového webu musí být v registru, ze kterého se nasazuje; ve vlastní kopii values přepiš `pweImage: pwe-example-generic` na `pwe-example-mariadb` ([Kubernetes](#kubernetes)) |

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
