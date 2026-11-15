# Image enginu PWE - jeden vicestupnovy Dockerfile, kazdy stage je jeden publikovany image:
#
#   stage      image          obsah
#   --------   ------------   ----------------------------------------------------------------------
#   base       pwe-base       Ubuntu + JEN behove knihovny enginu + entrypoint (bez kodu enginu,
#                             bez DB ovladacu, bez ladicich a build nastroju)
#   pwe        pwe            base + kod enginu v /PWE/PWE ("nosic" enginu; tag = vetev i verze)
#   static     pwe-static     base beze zmeny (profil pro weby bez databaze)
#   mariadb    pwe-mariadb    base + DBD::mysql + DBD::MariaDB
#   mysql      pwe-mysql      base + DBD::mysql
#   postgres   pwe-postgres   base + DBD::Pg
#   debugger   pwe-debugger   base + vsechny tri DB ovladace + ladici a vyvojove nastroje
#
# Profilove image (static, mariadb, mysql, postgres) a debugger NEOBSAHUJI kod enginu:
#   - ve vyvojovem stacku (docker-compose.yml) se koren repozitare mountuje do /PWE,
#   - image webu si engine kopiruje z image pwe:  COPY --from=<registr>/pwe:<tag> /PWE/PWE /PWE/PWE
#     (viz webapps/<web>/Dockerfile).
#
# Build (kontext = koren repozitare); bezne pres docker-bake.hcl, ktery zna jmena a tagy vsech image:
#   PWE/tools/build-images.sh                    # vsech 7 image, tag podle vetve, nacte do lokalniho Dockeru
#   PWE/tools/build-images.sh pwe debugger       # jen vybrane cile
#   docker buildx bake -f docker-bake.hcl --load # totez bez skriptu (REGISTRIES/TAG/VERSION z prostredi)
#   docker build --target base -t pwe-base -f PWE/docker/Dockerfile .     # jeden stage rucne
#
# Poradi vrstev: zavislosti (apt) jsou pred kodem, takze zmena enginu znovu stavi jen COPY vrstvy
# stage pwe a zadny apt-get.

ARG UBUNTU_IMAGE=ubuntu:26.04

# =============================================================================================
# base - behove zavislosti enginu
# =============================================================================================
FROM ${UBUNTU_IMAGE} AS base

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # --- jadro enginu (PWE/pwe.fcgi, PWE/Libs) ---
        # perl             = cely zakladni Perl (Net::SMTP, Storable, Digest::*, HTTP::Tiny, Time::Piece,
        #                    prove a podchecker pro PWE/t a kontrolu POD); v Ubuntu image je jen perl-base
        # CGI, CGI::Fast   = zpracovani requestu a FastCGI smycka (pwe.fcgi)
        # Template         = sablony (Libs::Web)
        # Class::Inspector = loadery stranek, sluzeb, vzhledu a entit (reflexe)
        # Moose            = Class::MOP pro vestavenou stranku Pages/pweCreator
        # JSON, JSON::XS   = Libs::Web (AJAX odpovedi), Services::DBTable; XS = rychly backend modulu JSON
        # DBI              = Libs::MyDBI (nacita se vzdy; ovladace DBD::* jsou az v profilovych image)
        perl \
        libcgi-pm-perl \
        libcgi-fast-perl \
        libtemplate-perl \
        libclass-inspector-perl \
        libmoose-perl \
        libjson-perl \
        libjson-xs-perl \
        libdbi-perl \
        # --- e-maily (Libs::Send, Services::Email, PWE/tools/smtp-test.pl) ---
        # Mail::RFC822::Address = kontrola adres; cstocs = Cz::Cstocs (prevod diakritiky v hlavickach);
        # LWP::MediaTypes = typy priloh; IO::Socket::SSL + Net::SSLeay = SMTP pres SSL/STARTTLS (a HTTPS
        # pro HTTP::Tiny); Authen::SASL = SMTP AUTH (PLAIN/LOGIN; zastarale CRAM-MD5 a DIGEST-MD5 by
        # vyzadovaly libdigest-hmac-perl - zamerne chybi, jinak by je Net::SMTP uprednostnil)
        libmail-rfc822-address-perl \
        cstocs \
        liblwp-mediatypes-perl \
        libio-socket-ssl-perl \
        libnet-ssleay-perl \
        libauthen-sasl-perl \
        ca-certificates \
        # --- externi programy, ktere engine spousti pevnou cestou ---
        # ruby-sass   = /usr/bin/sass (Pages/css: "/usr/bin/sass -C --scss --style=compressed");
        #               "sass" je v Ubuntu jen virtualni balicek, ktery poskytuje prave ruby-sass
        # imagemagick = /usr/bin/identify a /usr/bin/convert (Libs::Pics)
        ruby-sass \
        imagemagick \
        # --- casova pasma ---
        # tzdata = /usr/share/zoneinfo: bez nej nema promenna TZ zadny ucinek. Vychozi pasmo image
        #          zustava UTC, jine se nastavuje za behu promennou TZ (napr. TZ=Europe/Prague).
        tzdata \
        # --- knihovny pro kod webu (jen ty, ktere pouzivaji weby nad enginem; cokoli dalsiho si web
        #     instaluje ve svem webapps/<web>/Dockerfile) ---
        # Image::Magick      = kontrola obsahu nahranych obrazku (ImageMagick uz je v image kvuli Libs::Pics)
        # Crypt::OpenSSL::RSA + CLI openssl = podpisy RSA (platebni brana); HTTPS klient je HTTP::Tiny
        #                      z jadra Perlu nad IO::Socket::SSL (viz e-maily)
        # URI, HTML::Parser  = zavislosti CGI.pm, v image jsou tak jako tak; uvedeny vyslovne, aby
        #                      nezmizely, kdyby je CGI.pm prestal vyzadovat
        libimage-magick-perl \
        libcrypt-openssl-rsa-perl \
        openssl \
        liburi-perl \
        libhtml-parser-perl \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # Kontrola pri buildu: programy, ktere engine vola pevnou cestou, musi existovat (identify a convert
    # jsou v ImageMagick 7 jen alternativy k "magick" - kdyby je dalsi verze Ubuntu prestala dodavat,
    # build spadne tady a ne az Libs::Pics v provozu), databaze casovych pasem musi byt na miste a moduly
    # enginu i knihovny pro kod webu musi jit nacist (LWP::MediaTypes je samostatny balicek - libwww-perl
    # v image neni).
    test -x /usr/bin/sass; \
    test -x /usr/bin/identify; \
    test -x /usr/bin/convert; \
    test -x /usr/bin/openssl; \
    test -f /usr/share/zoneinfo/Europe/Prague; \
    perl -MCGI::Fast -MTemplate -MClass::Inspector -MClass::MOP -MJSON -MJSON::XS -MDBI \
         -MMail::RFC822::Address -MCz::Cstocs -MLWP::MediaTypes -MIO::Socket::SSL -MAuthen::SASL \
         -MImage::Magick -MCrypt::OpenSSL::RSA -MURI -MHTML::Parser -e 1

# Koren enginu v kontejneru. Kod enginu tu NENI: prida ho stage pwe, mount repozitare do /PWE
# (vyvojovy stack) nebo COPY --from=...pwe v Dockerfile webu.
ENV PWE_CONF_pwe_core=/PWE/PWE

# Entrypoint (jediny zdroj pravdy: PWE/docker/entrypoint.sh): v adresari webu pripravi
# conf/database.conf podle PWE_PROFILE a pracovni adresare, pak spusti prikaz.
COPY --chmod=0755 PWE/docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Popisky az za instalaci balicku: zmena PWE_SOURCE (fork) nezneplatni cache vrstvy s apt-get TOHOTO
# stage. Pro odvozene stage to neplati: ARG deklarovany tady (UBUNTU_IMAGE, PWE_SOURCE) se do stage
# mariadb, mysql, postgres a debugger dedi a jeho hodnota vstupuje do klice cache jejich RUN - s jinym
# PWE_SOURCE se tedy jejich apt-get (ovladace, ladici nastroje) stavi znovu. V ramci jednoho repozitare
# je PWE_SOURCE konstantni, takze se to projevi jen pri prvnim buildu forku.
# Image Ubuntu ma vlastni popisky title=ubuntu, version=26.04 a created=<vznik image Ubuntu>, ktere by
# se jinak zdedily a o image PWE by tvrdily nepravdu: title se prepisuje v kazdem stage, version a
# created se tu vyprazdni (verzi enginu nese jen image pwe; cas buildu a commit doplnuje docker-bake.hcl
# z promennych CREATED a REVISION) a puvod zakladu se zapise do base.name.
ARG UBUNTU_IMAGE
ARG PWE_SOURCE=https://github.com/kukam/PWE
LABEL org.opencontainers.image.title="pwe-base" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - zakladni image: behove knihovny enginu bez kodu enginu a bez databazovych ovladacu" \
      org.opencontainers.image.source="${PWE_SOURCE}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="" \
      org.opencontainers.image.created="" \
      org.opencontainers.image.base.name="${UBUNTU_IMAGE}"

WORKDIR /PWE/webapps

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["perl", "/PWE/PWE/pwe.fcgi"]

# =============================================================================================
# pwe - nosic kodu enginu (/PWE/PWE), z nej si image webu engine kopiruji
# =============================================================================================
FROM base AS pwe

# Engine se kopiruje po castech: PWE/t (testy) a PWE/docker (build image) do image nepatri.
# Poradi od nejmene po nejcasteji menene, at se pri zmene kodu znovu stavi co nejmene vrstev.
COPY LICENSE /PWE/LICENSE
COPY PWE/assets /PWE/PWE/assets
COPY PWE/templates /PWE/PWE/templates
COPY PWE/tools /PWE/PWE/tools
COPY PWE/Entities /PWE/PWE/Entities
COPY PWE/Services /PWE/PWE/Services
COPY PWE/Sites /PWE/PWE/Sites
COPY PWE/Pages /PWE/PWE/Pages
COPY PWE/Libs /PWE/PWE/Libs
COPY PWE/pwe.fcgi PWE/debug.cgi PWE/favicon.ico PWE/README.md PWE/CHANGELOG.md PWE/VERSION /PWE/PWE/

# Verze enginu = obsah PWE/VERSION; build ji predava jako PWE_VERSION (popisek a tag pwe:<verze>).
# Kdyz se predana verze lisi od souboru v image, build spadne - tag verze nesmi ukazovat na jiny kod.
ARG PWE_VERSION=""
RUN set -eu; \
    v="$(tr -d '[:space:]' < /PWE/PWE/VERSION)"; \
    if [ -n "${PWE_VERSION}" ] && [ "${PWE_VERSION}" != "$v" ]; then \
        echo "PWE_VERSION=${PWE_VERSION} neodpovida PWE/VERSION=$v" >&2; exit 1; \
    fi

LABEL org.opencontainers.image.title="pwe" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - engine v /PWE/PWE nad zakladnim image pwe-base (zdroj pro COPY --from v image webu)" \
      org.opencontainers.image.version="${PWE_VERSION}"

# =============================================================================================
# static - profil pro weby bez databaze (obsahem shodny s base, lisi se jen popiskem)
# =============================================================================================
FROM base AS static

LABEL org.opencontainers.image.title="pwe-static" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - behove prostredi pro weby bez databaze (bez kodu enginu)"

# =============================================================================================
# mariadb - base + ovladace MariaDB (engine pouziva dbi:mysql; DBD::MariaDB je k dispozici kodu webu)
# =============================================================================================
FROM base AS mariadb

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libdbd-mysql-perl \
        libdbd-mariadb-perl \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    perl -MDBD::mysql -MDBD::MariaDB -e 1

LABEL org.opencontainers.image.title="pwe-mariadb" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - behove prostredi pro weby s MariaDB (bez kodu enginu)"

# =============================================================================================
# mysql - base + ovladac MySQL
# =============================================================================================
FROM base AS mysql

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libdbd-mysql-perl \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    perl -MDBD::mysql -e 1

LABEL org.opencontainers.image.title="pwe-mysql" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - behove prostredi pro weby s MySQL (bez kodu enginu)"

# =============================================================================================
# postgres - base + ovladac PostgreSQL
# =============================================================================================
FROM base AS postgres

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libdbd-pg-perl \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    perl -MDBD::Pg -e 1

LABEL org.opencontainers.image.title="pwe-postgres" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - behove prostredi pro weby s PostgreSQL (bez kodu enginu)"

# =============================================================================================
# debugger - vyvojovy image: vsechny DB ovladace + nastroje pro ladeni (do produkce nepatri)
# =============================================================================================
FROM base AS debugger

# Nejnizsi pripustna verze jazykoveho serveru = verze rozsireni "Perl" (richterger.perl) ve VS Code.
ARG PERL_LANGUAGESERVER_MIN=2.6.2

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # --- vsechny tri DB ovladace: jeden image pro ladeni i pro nastroje (make test, check, cgi) ---
        libdbd-mysql-perl \
        libdbd-mariadb-perl \
        libdbd-pg-perl \
        # --- jazykovy server a debug adapter pro VS Code (rozsireni "Perl", richterger.perl) ---
        # Perl::LanguageServer z balicku Ubuntu, ne pres cpanm: build je pak cely z apt (bez site CPAN)
        # a projde i v emulaci jine platformy, kde cpanm pada na rozbalovani archivu (tar hlasi
        # "Function not implemented"). Zavislosti (Coro, AnyEvent, AnyEvent::AIO, IO::AIO, Compiler::Lexer,
        # Class::Refresh, PadWalker, Data::Dump, Hash::SafeKeys, Encode::Locale) si balicek pritahne sam.
        libperl-languageserver-perl \
        # --- kontrola a formatovani kodu: perlcritic, perltidy; dokumentace: perldoc ---
        libperl-critic-perl \
        perltidy \
        perl-doc \
        # --- instalace dalsich modulu z CPAN pri ladeni (cpanm + prekladac pro XS moduly) ---
        cpanminus \
        build-essential \
        # --- klienti databazi a sitove nastroje (curl: HTTP requesty na nginx stacku a cizi API pri
        #     ladeni; v behovych image neni - engine ani weby ho nevolaji) ---
        mariadb-client \
        postgresql-client \
        curl \
        iputils-ping \
        net-tools \
        telnet \
        # --- procesy (ps, pkill), strankovani, FastCGI klient cgi-fcgi (request primo na socket enginu) ---
        procps \
        less \
        libfcgi-bin \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # Kontrola pri buildu: verze jazykoveho serveru nesmi klesnout pod verzi rozsireni VS Code (az Ubuntu
    # prestane stacit, nainstaluj novejsi: cpanm Perl::LanguageServer) a ovladace i nastroje jdou nacist.
    perl -Mversion -MPerl::LanguageServer -e 'my ($min) = @ARGV; my $v = $Perl::LanguageServer::VERSION; print "Perl::LanguageServer $v\n"; exit(version->parse($v) >= version->parse($min) ? 0 : 1)' "${PERL_LANGUAGESERVER_MIN}"; \
    perl -MPerl::LanguageServer::DebuggerBridge -MDBD::mysql -MDBD::MariaDB -MDBD::Pg -MPerl::Critic -MPerl::Tidy -e 1; \
    test -x /usr/bin/curl

# cpanm z Ubuntu stahuje ve vychozim stavu distribuce nesifrovane (http://www.cpan.org) a bez overeni
# podpisu. --from = jediny zdroj indexu i archivu pres HTTPS (totez co --mirror <url> --mirror-only).
ENV PERL_CPANM_OPT="--from https://www.cpan.org/"

LABEL org.opencontainers.image.title="pwe-debugger" \
      org.opencontainers.image.description="PWE (Perl Web Engine) - vyvojovy image: vsechny databazove ovladace, Perl::LanguageServer, perlcritic, perltidy, cpanm a ladici nastroje (bez kodu enginu)"
