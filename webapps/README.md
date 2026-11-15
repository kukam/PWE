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
| `example.web/` | vzorový web **bez databáze** (nejmenší funkční web) | verzován zde, jen ke čtení |
| `example-db.web/` | vzorový web **s databází** (session, `dbTableExamples`, entita `User`, služba `Accounts`) | verzován zde, jen ke čtení |
| `<tvuj-web>/` | tvůj web | **není** v tomto repozitáři (`.gitignore: webapps/*`) — má vlastní git, naklonovaný sem |

Vlastní web tedy verzuješ a vydáváš nezávisle na enginu. Stejný adresář funguje dvěma způsoby:
tady ho spouští kořenový `docker-compose.yml` s enginem z pracovní kopie (`../PWE/`, v kontejneru
`/PWE/PWE`), a sám o sobě má `Dockerfile`, takže jde nasadit bez pracovní kopie enginu: běhové
prostředí bere z image `ghcr.io/kukam/pwe-<profil>` a engine si zkopíruje z image
`ghcr.io/kukam/pwe` (v image webu je také v `/PWE/PWE`).

```bash
# z kořene repozitáře; PWE_IMAGE_TAG = větev image (výchozí master), PWE_ENGINE_TAG = větev nebo verze enginu
# z image aktuální větve (tak je označuje make images i pipeline)
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    -t muj-web -f webapps/mujweb.web/Dockerfile .
# z image větve master (musí být v registru nebo v místním Dockeru)
docker build -t muj-web -f webapps/mujweb.web/Dockerfile .
# engine připnutý na verzi (obsah PWE/VERSION)
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    --build-arg PWE_ENGINE_TAG="$(cat PWE/VERSION)" -t muj-web:1.0 -f webapps/mujweb.web/Dockerfile .
```

Tytéž příkazy (s názvem image podle webu) jsou v záhlaví `Dockerfile` každého webu.

`docker build` bere image enginu z místního Dockeru, a když tam nejsou, stáhne je z `ghcr.io` (dokud
jsou balíčky soukromé, je potřeba `docker login ghcr.io`). Prostý `docker build` místní image vidí,
i když je v `docker buildx ls` vybraný jiný builder; jen `docker buildx build` s builderem typu
`docker-container` je nevidí — pak přidej `--builder <builder s ovladačem docker> --load` (v Docker
Desktopu `desktop-linux`, na Linuxu zpravidla `default`). Profil (`PWE_PROFILE`) je do image webu
zapečený, kontejner ho předávat nemusí. Web **nemá vlastní `entrypoint.sh`**: image webu dědí vstupní
skript z běhového image `pwe-<profil>` (jediný zdroj `../PWE/docker/entrypoint.sh`), který podle
`PWE_PROFILE` nasměruje `conf/database.conf` a založí dočasné adresáře; ty a symlink vznikají už při
sestavení, takže image běží i s kořenovým souborovým systémem jen pro čtení. Web vytvořený starší
šablonou s vlastním `entrypoint.sh`: soubor smaž a `Dockerfile` nahraď výstupem generátoru
([`../docs/17-nasazeni.md`](../docs/17-nasazeni.md#image-vlastního-webu)). Image webu dostane vlastní
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
