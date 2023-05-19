
VER="5.36.1"
ARCH=$(uname -m)
docker build --push \
    -t kukam/pwe-base:${VER}-${ARCH} \
    --cache-from kukam/pwe-base:${VER}-${ARCH} \
    --build-arg PERL_VERSION=${VER} \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --no-cache .

# Merge two image to one
docker buildx imagetools create -t docker.io/kukam/pwe-base:5.36.1 \
    docker.io/kukam/pwe-base:5.36.1-x86_64 \
    docker.io/kukam/pwe-base:5.36.1-arm64
