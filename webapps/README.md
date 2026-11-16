# webapps/ — písek pro vlastní weby

Sem patří **konkrétní weby** postavené nad enginem PWE, který leží v adresáři
[`../PWE/`](../PWE/README.md) (adresář `PWE/` v kořeni repozitáře, vedle `webapps/`).
Každý web je samostatný adresář `webapps/<nazev>/` **bez kódu enginu a bez symlinků na něj**:
obsahuje jen vlastní stránky, vzhled, služby, entity, konfiguraci a statiku. Engine ho najde
přes `PWE_CONF_pwe_home` a to, co si web z enginu bere, je vyjmenováno v jeho `conf/web.conf`
(`pwe.core_pages`, `core_sites`, `core_services`, `core_entities`); `pwe.require_core` hlídá
verzi enginu ([`../PWE/VERSION`](../PWE/VERSION)). Slovo `core` v těchto klíčích znamená
„kořen enginu“, tedy adresář `PWE/`.

```bash
make new WEB=mujweb.web ARGS='--title "Můj web" --lang CZE,EN'       # bez databáze
make new WEB=eshop.web  ARGS='--db mariadb --title "E-shop"'         # s databází
make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
make check WEB=mujweb.web
make run   WEB=mujweb.web PROFILE=static                              # http://127.0.0.1:7778/
```

## Co je tady

| Adresář | Co to je | Git |
|---------|----------|-----|
| `example.web/` | vzorový web **bez databáze** (nejmenší funkční web); vzniká z něj image `pwe-example-static` | verzován zde, jen ke čtení |
| `example-db.web/` | vzorový web **s databází** (session, `dbTableExamples`, entita `User`, služba `Accounts`); vznikají z něj image `pwe-example-mariadb`, `pwe-example-mysql` a `pwe-example-postgres` | verzován zde, jen ke čtení |
| `<tvuj-web>/` | tvůj web | **není** v tomto repozitáři (`.gitignore: webapps/*`) — má vlastní git, naklonovaný sem |

Vlastní web tedy verzuješ a vydáváš nezávisle na enginu. Stejný adresář funguje dvěma způsoby:
tady ho spouští kořenový `docker-compose.yml` s enginem z pracovní kopie (`../PWE/`, v kontejneru
`/PWE/PWE`), a sám o sobě má `Dockerfile`, ze kterého vznikne image webu se vším potřebným:
jediným `FROM` vychází ze **závislostního image** `ghcr.io/kukam/pwe-<profil>` (web bez databáze
z `pwe-base`) — běhové knihovny, DB ovladač a vstupní skript, bez kódu enginu a bez webu —, zkopíruje
do něj **engine** z adresáře `../PWE/` (v image webu `/PWE/PWE`) a přidá **sebe**. Sestavuje se proto
vždy z kořene repozitáře enginu a verzi enginu v image určuje pracovní kopie.

```bash
# VŽDY z kořene repozitáře; PWE_IMAGE_TAG = tag závislostního image pwe-<profil>: latest (výchozí), nebo verze enginu
# nad nejnovějším závislostním image (z registru nebo z místního Dockeru po make images)
docker build -t muj-web -f webapps/mujweb.web/Dockerfile .
# závislosti připnuté na verzi enginu (obsah PWE/VERSION)
docker build --build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)" -t muj-web:1.0 -f webapps/mujweb.web/Dockerfile .
```

Tytéž příkazy (s názvem image podle webu) jsou v záhlaví `Dockerfile` každého webu. Image PWE mají
jen tagy `<verze>` a `latest` (tagy podle větve neexistují); pro produkci připínej verzi — `latest` se
přepisuje s každou publikací.

Stejnou šablonou vznikají i image vzorových webů `pwe-example-static` (z `example.web`)
a `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres` (z `example-db.web`), které staví
`make images` a publikuje pipeline. Jsou to **ukázky, ne image pro veřejný provoz**: každý návštěvník
vzorového webu je ve skupině `admin` včetně generátoru kódu `pweCreator`.

`docker build` bere závislostní image z místního Dockeru, a když tam není, stáhne ho z `ghcr.io` (dokud
jsou balíčky soukromé, je potřeba `docker login ghcr.io`). Prostý `docker build` místní image vidí,
i když je v `docker buildx ls` vybraný jiný builder; jen `docker buildx build` s builderem typu
`docker-container` je nevidí — pak přidej `--builder <builder s ovladačem docker> --load` (v Docker
Desktopu `desktop-linux`, na Linuxu zpravidla `default`). Profil (`PWE_PROFILE`) je do image webu
zapečený, kontejner ho předávat nemusí. Web **nemá vlastní `entrypoint.sh`**: image webu dědí vstupní
skript ze závislostního image (jediný zdroj `../PWE/docker/entrypoint.sh`), který podle
`PWE_PROFILE` nasměruje `conf/database.conf` a založí dočasné adresáře; ty a symlink vznikají už při
sestavení, takže image jde spustit i s kořenovým souborovým systémem jen pro čtení (`ramdisk`,
`sessions`, `uploadfile` a `log` pak musí být zapisovatelné — `tmpfs` nebo svazek). Web vytvořený
starší šablonou (vlastní `entrypoint.sh`, nebo `Dockerfile` se dvěma `FROM` a argumentem
`PWE_ENGINE_TAG`) se nad dnešními image nesestaví nebo by v image chyběl engine — `make check` na to
upozorní (`WARN Dockerfile je ze stare sablony …`). Případný `entrypoint.sh` smaž a `Dockerfile` nahraď
výstupem generátoru: `PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <dočasný adresář>` a převezmi
z výsledku `Dockerfile`
([`../docs/17-nasazeni.md`](../docs/17-nasazeni.md#dockerfile-ze-starší-šablony)). Image webu dostane vlastní
popisky (`LABEL`) — `source` a `licenses` doplň podle repozitáře webu. Knihovny, které v `pwe-base`
nejsou (např. `LWP::UserAgent` = `libwww-perl`, `curl`), si web instaluje ve svém `Dockerfile`; image
běží v UTC, časové pásmo pro požadavky nastav ve webserveru (`fastcgi_param TZ Europe/Prague;`) nebo
přes `/etc/localtime` kontejneru — samotná proměnná `TZ` platí jen při startu enginu. Do image se nedostanou tajné údaje z `conf/` webu —
`conf/local.env` ani soukromé klíče (`*.pem`, `*.key`, `*.p12`, `*.pfx`); kontejner je dostává až za
běhu (proměnné prostředí, mount).
Šablona `Dockerfile`, argumenty sestavení, sestavení nad lokálními image a přidání vlastní knihovny:
[`../docs/17-nasazeni.md`](../docs/17-nasazeni.md#image-vlastního-webu).

## Pravidla

- Do adresáře enginu `../PWE/` nesahej (chyby enginu se opravují zvlášť, s testem v `../PWE/t/`).
- Stejný název modulu ve webu i v enginu = platí modul webu (lze tak přebít třeba `Pages/errorPage`).
- Konvence a kontrakt stránky: [`../docs/`](../docs/README.md), postup od zadání k webu:
  [`../docs/21-novy-web-podle-zadani.md`](../docs/21-novy-web-podle-zadani.md), kompletní příklad: [`../docs/12-tutorial-ukolnicek.md`](../docs/12-tutorial-ukolnicek.md).
- Historické weby dříve provozované nad PWE jsou v `../webapps-example/` (mimo git) — jen jako ukázky použití API.
