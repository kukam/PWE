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
        libimage-magick-perl \
        libdata-guid-perl \
        libdata-uuid-perl \
        libio-aio-perl \
        cstocs
        # libnet-ssh2-perl \

# Perl Debugger & Tools, (Perl::LanguageServer)
RUN set -x \
    && apt-get install -y \
        libmoose-perl \
        libdata-dump-perl \
        libpadwalker-perl \
        libcoro-perl \
        libanyevent-perl \
        libcompiler-lexer-perl \
        libclass-refresh-perl \
        libscalar-list-utils-perl \
        cpanminus \
        iputils-ping \
        net-tools \
        telnet \
        build-essential \
    && cpanm \
        Class::MOP \
        Cz::Cstocs \
        Perl::Critic \
        Perl::LanguageServer

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
