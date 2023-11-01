FROM ubuntu:latest

RUN set -x \
    && apt-get update \
    && apt-get install -y \
        sass \
        node-less \
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

WORKDIR /PWE

ADD Libs Libs
ADD Sites Sites
ADD Pages Pages
ADD assets assets
ADD Entities Entities
ADD Services Services
ADD templates templates
ADD favicon.ico favicon.ico
ADD pwe.fcgi pwe.fcgi

ADD LICENSE LICENSE

WORKDIR /PWE/webapps

ENTRYPOINT []

CMD []
