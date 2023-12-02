FROM kukam/pwe-base:latest

ENV PWE_CONF_pwe_home '/PWE/webapps/static.example.web'

WORKDIR /PWE/webapps/

ADD webapps/static.example.web static.example.web

WORKDIR /PWE/webapps/static.example.web

ENTRYPOINT []

CMD ["perl", "pwe.fcgi"]
