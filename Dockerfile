FROM kukam/pwe-base:${PERL_VERSION}-${CPU_ARCH}

ARG CPU_ARCH=
ARG PERL_VERSION=

ADD LXC/entrypoint.sh /entrypoint.sh

WORKDIR /PWE
ADD assets assets
ADD Entities Entities
ADD examples webapps
ADD Libs Libs
ADD Pages Pages
ADD Services Services
ADD Sites Sites
ADD templates templates
ADD LICENSE LICENSE
ADD favicon.ico favicon.ico
ADD pwe.fcgi pwe.fcgi

VOLUME /PWE/webapps
WORKDIR /PWE/webapps

ENV PWE_CONF_pwe_home '/PWE/webapps/static_web'

ENTRYPOINT ["/entrypoint.sh"]

CMD ["perl", "pwe.fcgi"]
