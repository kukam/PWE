FROM kukam/pwe-base:latest

ENV PWE_CONF_pwe_home '/PWE/webapps/generic.example.web'

ADD webapps/generic.example.web/entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /PWE/webapps/

ADD webapps/generic.example.web generic.example.web

WORKDIR /PWE/webapps/generic.example.web

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]

CMD ["perl", "pwe.fcgi"]
