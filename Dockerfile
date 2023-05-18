FROM kukam/perlbrew:5.36.1

# ADD https://raw.githubusercontent.com/miyagawa/cpanminus/master/cpanm /usr/local/bin/cpanm
# RUN chmod +x /usr/local/bin/cpanm

#    curl tar gcc build-base gnupg subversion \ 
# RUN set -x \
#     && apk add --no-cache bash wget make perl gcc musl-dev perl-dev \
#     && apk add --no-cache perl-cgi-fast perl-class-inspector perl-json perl-lwp-mediatypes perl-moose \
#     && apk add --no-cache perl-template-toolkit perl-dbi perl-dbd-pg perl-dbd-odbc perl-dbd-mysql \
#     && cpanm Cz::Cstocs \
#     && cpanm Mail::RFC822::Address \
#     && cpanm Devel::OverloadInfo \
#     && rm -fr cpanm /root/.cpanm \
#     && rm -fr /var/cache/apk/*

# EXPOSE 7779

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
        Mail::RFC822::Address \
    && chmod +x /entrypoint.sh"

VOLUME /PWE/webapps
WORKDIR /PWE/webapps

ENV PWE_CONF_pwe_home '/PWE/webapps/static_web'

ENTRYPOINT ["/entrypoint.sh"]

CMD ["perl", "pwe.fcgi"]
