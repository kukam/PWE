# Image webu example.web = zavislostni image PWE + engine + tento web:
#   - zaklad pwe-base: Perl, knihovny enginu a entrypoint (bez DB ovladacu - web bez databaze);
#     kod enginu ani zadny web v nem neni,
#   - engine z kontextu sestaveni (adresar PWE/ repozitare enginu bez PWE/t, PWE/docker a PWE/tools) do /PWE/PWE,
#   - tento web z webapps/example.web do /PWE/webapps/example.web.
#
# Sestaveni VZDY z korene repozitare enginu (kontext "."): engine i web se berou z pracovni kopie, verze enginu
# v image = PWE/VERSION v okamziku sestaveni (v image /PWE/PWE/VERSION). Co se do image nedostane, urcuje tamni
# .dockerignore: docasna data webu (ramdisk, log, sessions, uploadfile, temp), conf/local.env, conf/database.conf
# a soukrome klice a mistni promenne prostredi (*.pem, *.key, *.p12, *.pfx, *.env) - ty v CELEM adresari
# webu, ne jen pod conf/. Kontejner je dostava mountem nebo jako Secret.
#
#   # nad nejnovejsim zavislostnim image (vychozi PWE_IMAGE_TAG=latest; z registru nebo z lokalniho Dockeru po make images)
#   docker build -t example-web -f webapps/example.web/Dockerfile .
#
#   # zavislosti pripnute na verzi enginu: tag image pwe-base = obsah PWE/VERSION
#   docker build --build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)" -t example-web:1.0 -f webapps/example.web/Dockerfile .
#
# Prosty "docker build" stavi vychozim builderem Dockeru (ovladac docker): image z lokalniho Dockeru
# pouzije a do registru jde jen pro ty, ktere tam nejsou. "docker buildx build" (a prosty "docker build"
# s nastavenou promennou BUILDX_BUILDER) stavi vybranym builderem; je-li typu docker-container, lokalni
# image nevidi a hleda je v registru - pak pridej --builder <builder s ovladacem docker> --load
# (Docker Desktop: desktop-linux, Linux: default).
#
# Argumenty buildu:
#   PWE_IMAGE_REGISTRY   registr a jmenny prostor zavislostnich image PWE
#   PWE_IMAGE_TAG        tag image pwe-base: verze enginu (napr. 2.2.1), nebo latest
#   PWE_PROFILE          static = web bez databaze (zaklad pwe-base). Web s databazi ma jiny zaklad: vygeneruj Dockerfile s --db
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=latest
ARG PWE_PROFILE=static

FROM ${PWE_IMAGE_REGISTRY}/pwe-base:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

# Engine z kontextu sestaveni do /PWE/PWE: vsechny polozky adresare PWE/ krome testu (PWE/t), sestaveni
# zavislostnich image (PWE/docker) a nastroju pro vyvojare (PWE/tools). Vycet musi byt uplny - make check (PWE/tools/check-webapp.pl) upozorni,
# kdyz v nem nektera polozka enginu chybi (napr. po aktualizaci enginu: pak Dockerfile vygeneruj znovu).
# Poradi od nejmene po nejcasteji menene. COPY --link: vrstva nezavisi na vrstvach pod sebou - zmena zakladu
# ji nezneplatni a image webu nad stejnym enginem ji sdili.
COPY --link LICENSE /PWE/LICENSE
COPY --link PWE/assets /PWE/PWE/assets
COPY --link PWE/templates /PWE/PWE/templates
COPY --link PWE/Entities /PWE/PWE/Entities
COPY --link PWE/Services /PWE/PWE/Services
COPY --link PWE/Sites /PWE/PWE/Sites
COPY --link PWE/Pages /PWE/PWE/Pages
COPY --link PWE/Libs /PWE/PWE/Libs
COPY --link PWE/pwe.fcgi PWE/debug.cgi PWE/favicon.ico PWE/README.md PWE/CHANGELOG.md PWE/VERSION /PWE/PWE/

# Web (bez toho, co vynechava .dockerignore - viz zahlavi).
COPY --link webapps/example.web /PWE/webapps/example.web

# PWE_CONF_pwe_core=/PWE/PWE nastavuje uz zakladni image. PWE_PROFILE = profil, pro ktery je image sestaveny.
# Za behu ho lze prepsat (-e PWE_PROFILE=...) jen na profil, jehoz ovladac zakladni image obsahuje:
# pwe-mariadb a pwe-mysql umi mariadb i mysql (engine pro oba pouziva DBD::mysql), pwe-postgres jen
# postgres, pwe-base zadnou databazi. Entrypoint pak conf/database.conf presmeruje na novy profil.
ENV PWE_CONF_pwe_home=/PWE/webapps/example.web \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky zakladniho image (nazev, popis, repozitar a licence
# zavislostniho image PWE), ktere o image webu neplati. version, source a licenses jsou proto prazdne - dopln
# verzi, adresu repozitare a licenci webu; base.name = image, ze ktereho je image webu sestaveny (verzi
# enginu v image rika soubor /PWE/PWE/VERSION).
LABEL org.opencontainers.image.title="example.web" \
      org.opencontainers.image.description="Web example.web nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/example.web" \
      org.opencontainers.image.version="" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/pwe-base:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/example.web

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
