# Image webu example.web. Sklada se ze tri casti:
#   - behove prostredi z image pwe-<profil> (Perl, knihovny enginu, DB ovladac podle PWE_PROFILE, entrypoint),
#   - engine zkopirovany z image pwe (nosic kodu enginu) do /PWE/PWE,
#   - tento web v /PWE/webapps/example.web.
#
# Sestaveni z korene repozitare enginu (kontext "."; co se z webu do image nedostane, urcuje tamni
# .dockerignore: conf/local.env, conf/database.conf, soukrome klice conf/**/*.pem a *.key, docasna data):
#
#   # z image aktualni vetve - tak je oznacuje lokalni sestaveni (make images) i pipeline
#   docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
#       -t example-web -f webapps/example.web/Dockerfile .
#
#   # z image vetve master (vychozi PWE_IMAGE_TAG; musi byt v registru nebo v lokalnim Dockeru)
#   docker build -t example-web -f webapps/example.web/Dockerfile .
#
#   # engine pripnuty na verzi: tag image pwe = obsah PWE/VERSION; behovy image dal urcuje PWE_IMAGE_TAG
#   docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
#       --build-arg PWE_ENGINE_TAG="$(cat PWE/VERSION)" -t example-web:1.0 -f webapps/example.web/Dockerfile .
#
# Prosty "docker build" stavi vychozim builderem Dockeru (ovladac docker): image z lokalniho Dockeru
# pouzije a do registru jde jen pro ty, ktere tam nejsou. "docker buildx build" (a prosty "docker build"
# s nastavenou promennou BUILDX_BUILDER) stavi vybranym builderem; je-li typu docker-container, lokalni
# image nevidi a hleda je v registru - pak pridej --builder <builder s ovladacem docker> --load
# (Docker Desktop: desktop-linux, Linux: default).
#
# Argumenty buildu:
#   PWE_IMAGE_REGISTRY   registr a jmenny prostor image enginu
#   PWE_IMAGE_TAG        tag (vetev) behoveho image pwe-<profil>
#   PWE_ENGINE_TAG       tag image pwe, ze ktereho se kopiruje engine: vetev, nebo verze enginu (PWE/VERSION)
#   PWE_PROFILE          behovy profil: mariadb | mysql | postgres | static (web bez databaze)
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=master
ARG PWE_ENGINE_TAG=${PWE_IMAGE_TAG}
ARG PWE_PROFILE=static

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
ENV PWE_CONF_pwe_home=/PWE/webapps/example.web \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky behoveho image (nazev pwe-<profil>, popis "bez kodu
# enginu", repozitar a licence enginu), ktere o image webu neplati. source a licenses jsou proto prazdne -
# dopln adresu repozitare a licenci webu; base.name = behovy image, ze ktereho je image sestaveny.
LABEL org.opencontainers.image.title="example.web" \
      org.opencontainers.image.description="Web example.web nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/example.web" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/

COPY webapps/example.web example.web

WORKDIR /PWE/webapps/example.web

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
