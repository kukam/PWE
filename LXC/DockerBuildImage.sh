
# HOW TO BUILD PWE IMAGE
# ./LXC/DockerBuildImage.sh

docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from kukam/pwe:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .
