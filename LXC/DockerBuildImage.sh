
cd ../

CPU_ARCH=$(uname -m)
PERL_VERSION="5.36.1"

docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from /pwe:latest \
    --build-arg CPU_ARCH=${CPU_ARCH} \
    --build-arg PERL_VERSION=${PERL_VERSION} \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .

cd LXC/
