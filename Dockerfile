FROM ubuntu:latest

RUN set -x \
    && apt-get update \
    && apt-get install -y \
        libcgi-fast-perl \
        libclass-inspector-perl \
        libmail-rfc822-address-perl \
        libjson-perl \
        libtemplate-perl \
        libdbi-perl \
        libdbd-mysql-perl \
        libdbd-pg-perl \
        libnet-ssh2-perl \
        libimage-magick-perl \
        libdata-guid-perl \
        libdata-uuid-perl \
        libmoose-perl \
        cstocs
        # iputils-ping \
        # net-tools \
        # telnet \
        # cpanminus \
        # build-essential \
    # && cpanm install \
    #     Cz::Cstocs \
    #     Class::MOP

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

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]

CMD ["perl", "pwe.fcgi"]
