# Perl web engine (PWE)

## How to build and push pwe-base to docker hub
```
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-base:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache .
```

## How to build generic image to docker hub
```
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-mysql:latest \
    -t kukam/pwe-mariadb:latest \
    -t kukam/pwe-postgres:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache \
    -f webapps/generic.example.web/Dockerfile .
```

## How to build static image to docker hub
```
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-static:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache \
    -f webapps/static.example.web/Dockerfile .
```

## how to run in docker-compose
```
# How to start on MAC OS
export MY_IP="$(for i in {0..10}; do ipconfig getifaddr en${i}; done | head -1)"

# Other system & MAC OS
export COMPOSE_PROFILES="static"
# OR 
export COMPOSE_PROFILES="mysql"
# OR 
export COMPOSE_PROFILES="mariadb"
# OR 
export COMPOSE_PROFILES="postgres"

docker-compose up --build --remove-orphans --attach fcgi
```

## how to run in kubernetes


## perl local dependencies
cpanm \
    CGI::Fast \
    Class::Inspector \
    Cz::Cstocs \
    Mail::RFC822::Address \
    JSON \
    Template \
    List::Util \
    Perl::Critic \
    DynaLoader::bootstrap \
    XSLoader::load \
    DBI \
    DBD::mysql \
    JSON::XS
