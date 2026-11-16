# Definice vsech image PWE pro docker buildx bake.
#
#   PWE/tools/build-images.sh [--push] [cil...]     # bezny zpusob: doplni VERSION (obsah PWE/VERSION), REVISION a CREATED
#   VERSION="$(cat PWE/VERSION)" docker buildx bake -f docker-bake.hcl --print   # vypise vysledne cile a tagy, nic nestavi
#   VERSION="$(cat PWE/VERSION)" docker buildx bake -f docker-bake.hcl --load    # sestavi a nacte do lokalniho Dockeru
#
# Spoustet z korene repozitare (kontext buildu "." je relativni k aktualnimu adresari).
#
# Cile a image (9):
#   zavislostni image = stage v PWE/docker/Dockerfile; jen knihovny, zadny kod enginu a zadny web
#     base      -> pwe-base        behove knihovny enginu
#     mariadb   -> pwe-mariadb     base + DBD::mysql + DBD::MariaDB
#     mysql     -> pwe-mysql       base + DBD::mysql
#     postgres  -> pwe-postgres    base + DBD::Pg
#     debugger  -> pwe-debugger    base + vsechny ovladace + ladici nastroje
#   image vzorovych webu = zavislostni image + engine + vzorovy web; stavi je primo Dockerfile vzoroveho webu
#   (stejna sablona jako Dockerfile kazdeho jineho webu, PWE/tools/new-webapp.pl) z korene repozitare
#     example-static    -> pwe-example-static     pwe-base     + engine + webapps/example.web
#     example-mariadb   -> pwe-example-mariadb    pwe-mariadb  + engine + webapps/example-db.web (PWE_PROFILE=mariadb)
#     example-mysql     -> pwe-example-mysql      pwe-mysql    + engine + webapps/example-db.web (PWE_PROFILE=mysql)
#     example-postgres  -> pwe-example-postgres   pwe-postgres + engine + webapps/example-db.web (PWE_PROFILE=postgres)
#
# Tagy: kazdy z 9 image ma prave dva - verzi enginu a latest:
#   <registr>/<image>:<VERSION>      <registr>/<image>:latest
# Tagy podle vetve gitu neexistuji: ktera vetev smi publikovat, rozhoduje pipeline
# (.github/workflows/images.yml), ne jmeno tagu.
#
# Platformy se tu zamerne nenastavuji: vychozi je platforma stroje, CI je dodava parametrem
#   --set '*.platform=linux/amd64,linux/arm64'

# Registry, do kterych se image oznaci (carkou oddeleny seznam, napr. "ghcr.io/kukam,docker.io/kukam").
variable "REGISTRIES" {
  default = "ghcr.io/kukam"
}

# Verze enginu = obsah souboru PWE/VERSION (napr. 2.2.1). POVINNA: je to tag vsech image a popisek
# org.opencontainers.image.version image vzorovych webu (ty jedine obsahuji engine). Ze verze odpovida
# souboru /PWE/PWE/VERSION v image, overuji kourove kontroly PWE/tools/smoke-images.sh (pipeline je pousti
# pred publikaci): tag verze nesmi ukazovat na jiny kod.
variable "VERSION" {
  default = ""
  validation {
    condition     = VERSION != ""
    error_message = "Promenna VERSION je povinna (obsah PWE/VERSION): VERSION=\"$(cat PWE/VERSION)\" docker buildx bake ..., nebo PWE/tools/build-images.sh."
  }
  validation {
    condition     = VERSION == "" || can(regex("^[0-9]+[.][0-9]+[.][0-9]+$", VERSION))
    error_message = "Promenna VERSION nema tvar verze X.Y.Z (obsah PWE/VERSION)."
  }
}

# Adresa repozitare pro popisek org.opencontainers.image.source (GitHub podle nej priradi image k repozitari).
variable "SOURCE" {
  default = "https://github.com/kukam/PWE"
}

# Commit, ze ktereho se stavi (popisek org.opencontainers.image.revision image vzorovych webu). Tagy <verze>
# i latest se prepisuji, takze jen podle nej jde zpetne poznat, jaky kod image obsahuje. Prazdny = bez popisku.
# Zavislostni image popisek nemaji: kod enginu neobsahuji a jejich digest se tak meni jen se zavislostmi,
# ne s kazdym commitem.
variable "REVISION" {
  default = ""
}

# Cas buildu ve tvaru RFC 3339, napr. 2026-11-15T12:00:00Z (popisek org.opencontainers.image.created image
# vzorovych webu). Prazdny = bez popisku. Zamerne se nepocita tady: stejne vstupy maji dat stejny image
# (kdo stavi dvakrat - pro testy a pro publikaci - preda obema buildum tutez hodnotu a dostane tentyz image).
variable "CREATED" {
  default = ""
}

# Vrati seznam <registr>/<image>:<tag> pro vsechny registry z REGISTRIES a oba tagy image (verze, latest).
function "image_tags" {
  params = [image]
  result = flatten([
    for registry in split(",", REGISTRIES) : [
      for tag in [VERSION, "latest"] : "${trimspace(registry)}/${image}:${tag}"
    ] if trimspace(registry) != ""
  ])
}

# Vrati prvni registr ze seznamu REGISTRIES: z nej berou image vzorovych webu svuj zaklad (argument
# PWE_IMAGE_REGISTRY Dockerfile webu).
function "base_registry" {
  params = []
  result = [for registry in split(",", REGISTRIES) : trimspace(registry) if trimspace(registry) != ""][0]
}

# Vrati jmeno zakladniho image vzoroveho webu <prvni registr>/<image>:<VERSION> - presne to, co po dosazeni
# argumentu PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG a PWE_PROFILE stoji v radku FROM Dockerfile webu.
function "base_ref" {
  params = [image]
  result = "${base_registry()}/${image}:${VERSION}"
}

group "default" {
  targets = [
    "base", "mariadb", "mysql", "postgres", "debugger",
    "example-static", "example-mariadb", "example-mysql", "example-postgres",
  ]
}

# ---------------------------------------------------------------------------------------------
# Zavislostni image (PWE/docker/Dockerfile)
# ---------------------------------------------------------------------------------------------

# Spolecne nastaveni zavislostnich image (samo se nestavi).
target "_common" {
  context    = "."
  dockerfile = "PWE/docker/Dockerfile"
  args = {
    PWE_SOURCE = SOURCE
  }
}

# Behove knihovny enginu; zaklad image webu bez databaze.
target "base" {
  inherits = ["_common"]
  target   = "base"
  tags     = image_tags("pwe-base")
}

# base + ovladace MariaDB (DBD::mysql + DBD::MariaDB); zaklad image webu s MariaDB.
target "mariadb" {
  inherits = ["_common"]
  target   = "mariadb"
  tags     = image_tags("pwe-mariadb")
}

# base + ovladac MySQL (DBD::mysql); zaklad image webu s MySQL.
target "mysql" {
  inherits = ["_common"]
  target   = "mysql"
  tags     = image_tags("pwe-mysql")
}

# base + ovladac PostgreSQL (DBD::Pg); zaklad image webu s PostgreSQL.
target "postgres" {
  inherits = ["_common"]
  target   = "postgres"
  tags     = image_tags("pwe-postgres")
}

# Vyvojovy image: base + vsechny ovladace + ladici nastroje.
target "debugger" {
  inherits = ["_common"]
  target   = "debugger"
  tags     = image_tags("pwe-debugger")
}

# ---------------------------------------------------------------------------------------------
# Image vzorovych webu (webapps/example.web/Dockerfile, webapps/example-db.web/Dockerfile)
# ---------------------------------------------------------------------------------------------
# Kazdy cil stavi Dockerfile vzoroveho webu z korene repozitare - tak, jak se stavi image kazdeho webu:
#   docker build -f webapps/<web>/Dockerfile --build-arg PWE_IMAGE_TAG=<verze> [--build-arg PWE_PROFILE=<profil>] .
# "contexts" nahradi image z radku FROM (<registr>/pwe-base:<verze>, <registr>/pwe-<profil>:<verze>) prave
# sestavenym cilem (target:base, target:mariadb, ...): vzorovy image tak vzdy vychazi z cerstveho zakladu
# z tehoz volani bake - i bez registru, i s builderem, ktery lokalni image nevidi (docker-container), a pro
# vice platforem. Zavislostni cil se pritom sestavi sam; do lokalniho Dockeru (nebo registru) se ale nacte
# jen tehdy, kdyz je take mezi stavenymi cili (skupina default obsahuje vsechny).
# Popisky doplnuje bake (prepisuji popisky z Dockerfile webu, ktery ma title = nazev webu a version, source
# a licenses prazdne): title = nazev image, version = verze enginu, source, licenses a - kdyz jsou zadane -
# cas buildu a commit. Meni jen konfiguraci image, ne vrstvy: cache buildu neovlivni.

# Spolecne nastaveni image vzorovych webu (samo se nestavi).
target "_example" {
  context = "."
  args = {
    PWE_IMAGE_REGISTRY = base_registry()
    PWE_IMAGE_TAG      = VERSION
  }
  labels = merge(
    {
      "org.opencontainers.image.version"  = VERSION
      "org.opencontainers.image.source"   = SOURCE
      "org.opencontainers.image.licenses" = "Apache-2.0"
    },
    CREATED != "" ? { "org.opencontainers.image.created" = CREATED } : {},
    REVISION != "" ? { "org.opencontainers.image.revision" = REVISION } : {}
  )
}

# Vzorovy web bez databaze (example.web) nad pwe-base.
target "example-static" {
  inherits   = ["_example"]
  dockerfile = "webapps/example.web/Dockerfile"
  args = {
    PWE_PROFILE = "static"
  }
  contexts = {
    "${base_ref("pwe-base")}" = "target:base"
  }
  labels = {
    "org.opencontainers.image.title"       = "pwe-example-static"
    "org.opencontainers.image.description" = "PWE (Perl Web Engine) - vzorovy web bez databaze (example.web): zavislostni image pwe-base + engine + web. Ukazka, neni urcena pro verejny provoz"
  }
  tags = image_tags("pwe-example-static")
}

# Vzorovy web s databazi (example-db.web) nad pwe-mariadb.
target "example-mariadb" {
  inherits   = ["_example"]
  dockerfile = "webapps/example-db.web/Dockerfile"
  args = {
    PWE_PROFILE = "mariadb"
  }
  contexts = {
    "${base_ref("pwe-mariadb")}" = "target:mariadb"
  }
  labels = {
    "org.opencontainers.image.title"       = "pwe-example-mariadb"
    "org.opencontainers.image.description" = "PWE (Perl Web Engine) - vzorovy web s databazi MariaDB (example-db.web): zavislostni image pwe-mariadb + engine + web. Ukazka, neni urcena pro verejny provoz"
  }
  tags = image_tags("pwe-example-mariadb")
}

# Vzorovy web s databazi (example-db.web) nad pwe-mysql.
target "example-mysql" {
  inherits   = ["_example"]
  dockerfile = "webapps/example-db.web/Dockerfile"
  args = {
    PWE_PROFILE = "mysql"
  }
  contexts = {
    "${base_ref("pwe-mysql")}" = "target:mysql"
  }
  labels = {
    "org.opencontainers.image.title"       = "pwe-example-mysql"
    "org.opencontainers.image.description" = "PWE (Perl Web Engine) - vzorovy web s databazi MySQL (example-db.web): zavislostni image pwe-mysql + engine + web. Ukazka, neni urcena pro verejny provoz"
  }
  tags = image_tags("pwe-example-mysql")
}

# Vzorovy web s databazi (example-db.web) nad pwe-postgres.
target "example-postgres" {
  inherits   = ["_example"]
  dockerfile = "webapps/example-db.web/Dockerfile"
  args = {
    PWE_PROFILE = "postgres"
  }
  contexts = {
    "${base_ref("pwe-postgres")}" = "target:postgres"
  }
  labels = {
    "org.opencontainers.image.title"       = "pwe-example-postgres"
    "org.opencontainers.image.description" = "PWE (Perl Web Engine) - vzorovy web s databazi PostgreSQL (example-db.web): zavislostni image pwe-postgres + engine + web. Ukazka, neni urcena pro verejny provoz"
  }
  tags = image_tags("pwe-example-postgres")
}
