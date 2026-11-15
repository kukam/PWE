#!/bin/bash
# perl -c nad vsemi moduly enginu (PWE/Libs, Entities, Services, Sites, Pages), PWE/pwe.fcgi, PWE/debug.cgi
# a skripty PWE/tools/, spusteno uvnitr kontejneru s Perl zavislostmi (koren repozitare v /PWE,
# engine v /PWE/PWE). Vypisuje OK/WARN/FAIL.
#
#   PWE/tools/perl-compile.sh                   # (make compile)
#   PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:master PWE/tools/perl-compile.sh   # jiny image (cele jmeno vcetne tagu)
#   PWE_IMAGE_TAG=master PWE/tools/perl-compile.sh                           # image nastroju jine vetve
#
# Image: vychozi je image nastroju ghcr.io/kukam/pwe-debugger:<aktualni vetev gitu> (pwe_tool_image
# z PWE/tools/lib/images.sh). Zmena: PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG, nebo PWE_TEST_IMAGE = uplne
# prepsani. Image sestavi make images (PWE/tools/build-images.sh).
set -e
# shellcheck disable=SC1007   # "CDPATH= cd": prazdny CDPATH jen pro tento prikaz (jinak cd vypisuje cil na stdout)
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/PWE/tools/lib/images.sh"
IMAGE="$(pwe_tool_image)"
echo "[perl-compile] image $IMAGE" >&2
pwe_image_missing_hint "$IMAGE" perl-compile
docker run --rm --entrypoint bash -v "$ROOT":/PWE -w /PWE/PWE "$IMAGE" -c '
    export PERL5LIB=/PWE/PWE:/PWE/PWE/tools/lib
    fail=0
    for f in pwe.fcgi debug.cgi tools/*.pl $(find Libs Entities Services Sites Pages tools/lib -name "*.pm" | sort); do
        out=$(perl -c "$f" 2>&1)
        if echo "$out" | grep -q "syntax OK"; then
            warn=$(echo "$out" | grep -v "syntax OK")
            if [ -n "$warn" ]; then echo "WARN $f"; echo "$warn" | sed "s/^/    /"; else echo "OK   $f"; fi
        else
            echo "FAIL $f"; echo "$out" | sed "s/^/    /"; fail=1
        fi
    done
    exit $fail'
