ARG PERL_VERSION=

FROM kukam/pwe-base:${PERL_VERSION}

ADD LXC/entrypoint.sh /usr/local/bin/entrypoint.sh

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

ENV PWE_CONF_pwe_home '/PWE/webapps/static_web'

VOLUME /PWE/webapps
WORKDIR /PWE/webapps

CMD ["perl", "pwe.fcgi"]
