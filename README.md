# Perl web engine (PWE)

## How to build and push to docker hub
```
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe:latest \
    --cache-from kukam/pwe:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .
```

## how to run in docker (docker-compose)
```
# How to start on MAC OS
export MY_IP="$(for i in {0..10}; do ipconfig getifaddr en${i}; done | head -1)"
export COMPOSE_PROFILES="static"
export COMPOSE_PROFILES="mysql"
export COMPOSE_PROFILES="mariadb"
export COMPOSE_PROFILES="postgres"

docker-compose up --build --remove-orphans
```

## how to run in kubernetes
