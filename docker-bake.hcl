# Definice vsech image PWE pro docker buildx bake (stage = cil v PWE/docker/Dockerfile).
#
#   PWE/tools/build-images.sh [--push] [cil...]     # bezny zpusob: doplni TAG (vetev) a VERSION (PWE/VERSION)
#   docker buildx bake -f docker-bake.hcl --print   # vypise vysledne cile a tagy, nic nestavi
#   TAG=master VERSION=2.2.0 docker buildx bake -f docker-bake.hcl --push
#
# Spoustet z korene repozitare (kontext buildu "." je relativni k aktualnimu adresari).
#
# Tagy:
#   <registr>/pwe-base:<TAG>, <registr>/pwe-<profil>:<TAG>, <registr>/pwe-debugger:<TAG>  ... jen podle vetve
#   <registr>/pwe:<TAG> a <registr>/pwe:<VERSION>                                         ... vetev i verze enginu
#
# Platformy se tu zamerne nenastavuji: vychozi je platforma stroje, CI je dodava parametrem
#   --set '*.platform=linux/amd64,linux/arm64'

# Registry, do kterych se image oznaci (carkou oddeleny seznam, napr. "ghcr.io/kukam,docker.io/kukam").
variable "REGISTRIES" {
  default = "ghcr.io/kukam"
}

# Tag vsech image = nazev vetve prevedeny na platny tag (viz pwe_image_tag v PWE/tools/lib/images.sh).
variable "TAG" {
  default = "master"
}

# Verze enginu (obsah PWE/VERSION) = druhy tag image pwe a jeho popisek verze. Prazdna = bez tagu verze.
variable "VERSION" {
  default = ""
}

# Adresa repozitare pro popisek org.opencontainers.image.source (GitHub podle nej priradi image k repozitari).
variable "SOURCE" {
  default = "https://github.com/kukam/PWE"
}

# Commit, ze ktereho se stavi (popisek org.opencontainers.image.revision image pwe). Tagy podle vetve
# i verze se prepisuji, takze jen podle nej jde zpetne poznat, jaky kod image pwe obsahuje.
# Prazdny = bez popisku. Ostatni image kod enginu neobsahuji, proto popisek nemaji a jejich digest
# se s kazdym commitem nemeni (zmeni se jen se zmenou zavislosti v Dockerfile).
variable "REVISION" {
  default = ""
}

# Cas buildu ve tvaru RFC 3339, napr. 2026-11-15T12:00:00Z (popisek org.opencontainers.image.created
# image pwe). Prazdny = popisek zustane prazdny. Zamerne se nepocita tady: stejne vstupy maji dat stejny
# image (kdo stavi dvakrat - pro testy a pro publikaci - preda obema buildum tutez hodnotu a dostane
# tentyz image).
variable "CREATED" {
  default = ""
}

# Vrati seznam <registr>/<image>:<tag> pro vsechny registry z REGISTRIES a vsechny zadane tagy.
function "image_tags" {
  params = [image, tags]
  result = flatten([
    for registry in split(",", REGISTRIES) : [
      for tag in tags : "${trimspace(registry)}/${image}:${tag}"
    ] if trimspace(registry) != ""
  ])
}

group "default" {
  targets = ["base", "pwe", "static", "mariadb", "mysql", "postgres", "debugger"]
}

# Spolecne nastaveni vsech cilu (samo se nestavi).
target "_common" {
  context    = "."
  dockerfile = "PWE/docker/Dockerfile"
  args = {
    PWE_SOURCE = SOURCE
  }
}

# Behove knihovny enginu, bez kodu enginu.
target "base" {
  inherits = ["_common"]
  target   = "base"
  tags     = image_tags("pwe-base", [TAG])
}

# Nosic kodu enginu - jediny image, ktery ma krome tagu vetve i tag verze.
target "pwe" {
  inherits = ["_common"]
  target   = "pwe"
  args = {
    PWE_VERSION = VERSION
  }
  # Popisky, ktere nejdou napsat do Dockerfile: cas buildu a commit. Meni jen konfiguraci image,
  # ne vrstvy - cache buildu ani obsah image neovlivni.
  labels = merge(
    CREATED != "" ? { "org.opencontainers.image.created" = CREATED } : {},
    REVISION != "" ? { "org.opencontainers.image.revision" = REVISION } : {}
  )
  tags = image_tags("pwe", VERSION != "" ? [TAG, VERSION] : [TAG])
}

# Profil pro weby bez databaze.
target "static" {
  inherits = ["_common"]
  target   = "static"
  tags     = image_tags("pwe-static", [TAG])
}

# Profil MariaDB (DBD::mysql + DBD::MariaDB).
target "mariadb" {
  inherits = ["_common"]
  target   = "mariadb"
  tags     = image_tags("pwe-mariadb", [TAG])
}

# Profil MySQL (DBD::mysql).
target "mysql" {
  inherits = ["_common"]
  target   = "mysql"
  tags     = image_tags("pwe-mysql", [TAG])
}

# Profil PostgreSQL (DBD::Pg).
target "postgres" {
  inherits = ["_common"]
  target   = "postgres"
  tags     = image_tags("pwe-postgres", [TAG])
}

# Vyvojovy image: vsechny ovladace + ladici nastroje.
target "debugger" {
  inherits = ["_common"]
  target   = "debugger"
  tags     = image_tags("pwe-debugger", [TAG])
}
