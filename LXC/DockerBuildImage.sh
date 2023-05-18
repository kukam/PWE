
cd ../

docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from kukam/pwe:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .

# docker build --load \
#     -t pwe:latest \
#     --cache-from pwe:latest \
#     --build-arg BUILDKIT_INLINE_CACHE=1 \
#     --no-cache .

cd LXC/

exit

docker buildx build --push \
    -t kukam/perlbrew:5.36.1 \
    --cache-from kukam/perlbrew:5.36.1 \
    --build-arg PERL_VERSION='5.36.1' \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .


docker build --load \
    -t perlbrew:5.36.1 \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --no-cache .


docker buildx build --load \
    -t perlbrew:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .