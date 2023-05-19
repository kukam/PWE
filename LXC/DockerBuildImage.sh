
cd ../

PERL_VERSION="5.36.1"

docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from kukam/pwe:latest \
    --build-arg PERL_VERSION=${PERL_VERSION} \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .

cd LXC/
