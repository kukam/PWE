FROM ubuntu:latest as pwe-base

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
        libmoose-perl \
        cstocs

WORKDIR /PWE

ADD lib lib
ADD templates templates
ADD webappsCommons webappsCommons
ADD favicon.ico favicon.ico
ADD pwe.fcgi pwe.fcgi

ADD LICENSE LICENSE

WORKDIR /PWE/webapps

ENTRYPOINT []

CMD []

# Perl Debugger & Tools, (Perl::LanguageServer)
FROM kukam/pwe-base:latest as pwe-debugger

RUN set -x \
    && apt-get install -y \
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
        Perl::Critic \
        Perl::LanguageServer
        # Class::MOP \
        # Cz::Cstocs
        # libnet-ssh2-perl \
