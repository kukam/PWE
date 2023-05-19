FROM ubuntu:latest

ARG PERL_VERSION=

ENV PERLBREW_ROOT /opt/perl5

ADD entrypoint.sh /usr/local/bin/entrypoint.sh

RUN bash -c "set -x \
    && apt update -y \
    && apt list --upgradable \
    && apt upgrade -y \
    && apt install -y curl build-essential \
    && curl -L https://install.perlbrew.pl | bash \
    && source /opt/perl5/etc/bashrc \
    && perlbrew install --notest --noman -j 6 perl-${PERL_VERSION} \
    && perlbrew use perl-${PERL_VERSION} \
    && perlbrew switch perl-${PERL_VERSION} \
    && perlbrew install-cpanm \
    && apt-get autoremove --yes \
    && apt clean autoclean"

RUN bash -c "set -x \
    && source /opt/perl5/etc/bashrc \
    && cpanm install \
        DBI \
        JSON \
        JSON::XS \
        Template \
        CGI::Fast \
        Class::MOP \
        Class::Inspector Cz::Cstocs \
        Mail::RFC822::Address"

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]

CMD []