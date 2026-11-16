# PWE - jednotny vstup pro vyvoj. Engine, testy i stack bezi v kontejneru (image ghcr.io/kukam/pwe-*:<verze>, viz make images); hostitelskym Perlem (staci jadro) se jen spousteji skripty PWE/tools/*.pl, ktere si zbytek odbavi v kontejneru.
# Spoustej z korene repozitare. Engine je v adresari PWE/ (v kontejneru /PWE/PWE), weby ve webapps/<web>/.
#
#   make help
#   make test                      testy enginu (PWE/t/)         make compile   perl -c celeho enginu (PWE/)
#   make new WEB=mujweb.web ARGS='--db mariadb --title "Muj web"'   kostra noveho webu ve webapps/
#   make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
#   make check WEB=mujweb.web      kontrola webu (konvence, perl -c, smoke)
#   make cgi WEB=mujweb.web Q='page=kontakt&func=default'           jeden request v CGI rezimu
#   make smtp-test WEB=mujweb.web ARGS='--to vas@email.cz'          testovaci e-mail pres SMTP z conf (+ conf/local.env)
#   make run WEB=mujweb.web [PROFILE=static|mariadb|mysql|postgres] [ARGS='-d']   docker compose up
#   make restart / logs / down WEB=...
#   make images [ARGS='base debugger']   sestavi image do lokalniho Dockeru s tagy <verze> a latest: vsech 9, nebo jen vybrane cile (zavislostni image
#                                  base mariadb mysql postgres debugger, vzorove weby example-static example-mariadb example-mysql example-postgres); ARGS='--help' vypise volby
#   make images-check [ARGS='pwe-base pwe-example-static']   kourove kontroly image v lokalnim Dockeru (PWE/tools/smoke-images.sh; bez ARGS vsech 9 image aktualniho registru a tagu)
#   make k8s-image|k8s-template|k8s-deploy|k8s-status|k8s-test|k8s-logs|k8s-delete K8S=example-static|generic [ARGS=...]
#                                  nasazeni do Kubernetes (PWE/tools/k8s.sh, navod kubernetes/README.md); cluster
#                                  jen pres KUBE_CONTEXT v kubernetes/local.env - aktualni kontext kubectl se nepouziva
#
# WEB: cile new a module vyzaduji WEB zadany vyslovne (make new WEB=mujweb.web, nebo promenna prostredi); ostatni cile maji vychozi example-db.web.
# Znak dolaru se v ARGS a Q pise zdvojene (make ho jinak rozvine); v ARGS uvnitr dvojitych uvozovek navic s lomitkem: ARGS='--title "Cena \$$5"', Q='page=x&cena=$$5'.
#
# Image: zavislostni image nesou jen knihovny (zadny kod enginu, zadny web) - engine i weby bezi z pracovni kopie. Nastroje (test, compile, check, cgi, module, smtp-test)
# bezi v ghcr.io/kukam/pwe-debugger:<verze>, stack (run) v pwe-<profil>:<verze>, profil static v pwe-base:<verze>; image webu (engine + web) stavi webapps/<web>/Dockerfile.
# <verze> = obsah PWE/VERSION (na gitu ani vetvi nezavisi), kazdy image ma navic tag latest. Zmena: PWE_IMAGE_TAG=<tag> (napr. latest), PWE_IMAGE_REGISTRY=ghcr.io/<fork>, PWE_TEST_IMAGE=<cele jmeno image nastroju>.
#
WEB     ?= example-db.web
PROFILE ?=
Q       ?= page=default&func=default
TYPE    ?= page
K8S     ?=
TOOLS    = PWE/tools

# Cile, ktere zapisuji do webu (new, module), nesmi potichu pouzit vychozi WEB - to je vzorovy web jen ke cteni.
# WEB musi prijit z prikazove radky nebo z prostredi; jinak make skonci chybou jeste pred spustenim nastroje.
require-web = $(if $(filter command line environment,$(origin WEB)),,$(error Zadej web vyslovne: make $@ WEB=<nazev>.web (vychozi $(WEB) je vzorovy web jen ke cteni)))

.PHONY: help test compile new module check cgi smtp-test run restart logs down images images-check \
        k8s-image k8s-template k8s-deploy k8s-status k8s-test k8s-logs k8s-delete

help:
	@sed -n '2,25p' Makefile | sed 's/^# \{0,1\}//'

test:
	$(TOOLS)/run-tests.sh $(ARGS)

compile:
	$(TOOLS)/perl-compile.sh

new:
	$(require-web)
	$(TOOLS)/new-webapp.pl $(WEB) $(ARGS)

module:
	$(require-web)
	$(TOOLS)/new-module.pl $(TYPE) $(WEB) $(NAME) $(ARGS)

check:
	$(TOOLS)/check-webapp.pl $(WEB) $(ARGS)

cgi:
	$(TOOLS)/pwe-cgi.sh $(WEB) '$(Q)' $(ARGS)

smtp-test:
	$(TOOLS)/smtp-test.pl $(WEB) $(ARGS)

run:
	$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) up --remove-orphans $(ARGS)

restart:
	$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) restart fcgi

logs:
	$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) logs -f fcgi

down:
	$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) down $(ARGS)

images:
	$(TOOLS)/build-images.sh $(ARGS)

images-check:
	$(TOOLS)/smoke-images.sh $(ARGS)

# Nasazeni do Kubernetes: K8S = nazev nasazeni (kubernetes/values-<nazev>.yml), ARGS = dalsi argumenty
# (helm u template/deploy/delete, docker buildx build u image, kubectl logs u logs).
k8s-image k8s-template k8s-deploy k8s-status k8s-test k8s-logs k8s-delete:
	$(TOOLS)/k8s.sh $(patsubst k8s-%,%,$@) '$(K8S)' $(ARGS)
