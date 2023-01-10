
cd ../

docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from kukam/pwe:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .

cd LXC/
