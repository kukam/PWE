
VER="5.36.1"
ARCH=$(uname -m)
docker build --push \
    -t kukam/pwe-base:${VER}-${ARCH} \
    --cache-from kukam/pwe-base:${VER}-${ARCH} \
    --build-arg PERL_VERSION=${VER} \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --no-cache .
