# Perl web engine (PWE)

## How to build & push pwe-base

``` bash
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-base:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --target pwe-base \
    --no-cache .
```

```bash
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-debugger:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --target pwe-debugger \
    --no-cache .
```

## How to build & push pwe-generic image

``` bash
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

## How to build & push pwe-static image

``` bash
docker buildx create --use
docker buildx build --push \
    -t kukam/pwe-static:latest \
    --cache-from kukam/pwe-base:latest \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --platform "linux/amd64,linux/arm64/v8" \
    --no-cache \
    -f webapps/static.example.web/Dockerfile .
```

## how to run docker-compose-debugger

``` bash
docker-compose up -d debugger
```

## how to run docker-compose

``` bash
# How to start on MAC OS (It's no longer necessary)
# export MY_IP="$(for i in {0..10}; do ipconfig getifaddr en${i}; done | head -1)"

# Choose profile type
export COMPOSE_PROFILES="static"
# OR 
export COMPOSE_PROFILES="mysql"
# OR 
export COMPOSE_PROFILES="mariadb"
# OR 
export COMPOSE_PROFILES="postgres"

COMPOSE_PROFILES=${COMPOSE_PROFILES:-mariadb} docker-compose up --build --remove-orphans --attach fcgi
```

## how to run in kubernetes

``` bash
helmfile -f helmfile.yaml sync
```

## perl local lib dependencies

``` bash
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
    IO::Socket::SSL \
    JSON::XS
```

## VS Code & Perl Debugging

- install vsc modul 'Perl - Language Server and Debugger for Perl', published by 'Gerald Richter'
- save settings.json and launch.json to the folder .vscode/
- run docker-compose (how to run title:docker-compose-debugger)
- run docker-compose (how to run title:docker-compos)
- vsc press F5
- open http://127.0.0.1:7778/debug.cgi

``` bash
# .vscode/settings.json
{
    "perl.containerCmd": "docker",
    "perl.containerMode": "exec",
    "perl.containerName": "pwe-debugger-1",
    "perl.containerArgs": [],
    "perl.perlInc": [
        // path in the container (pwe-base)
        "/usr/share/perl5",
        "/PWE"
    ],
    "perl.fileFilter": [
        "pm",
        "pl",
        "cgi",
        "fcgi"
    ],
    "perl.showLocalVars": true
}
```

``` bash
# .vscode/launch.json
{
  // Pro informace o možných atributech použijte technologii IntelliSense.
  // Umístěním ukazatele myši zobrazíte popisy existujících atributů.
  // Další informace najdete tady:
  // https://go.microsoft.com/fwlink/?linkid=830387
  // https://code.visualstudio.com/docs/editor/variables-reference
  "version": "0.2.0",
  "configurations": [
    {
      "type": "perl",
      "request": "launch",
      "name": "PWE Generic",
      "program": "${workspaceFolder}/webapps/generic.example.web/debug.cgi",
      "stopOnEntry": false,
      "reloadModules": true,
      // "args": [ "page=xxx", "func=sdf" ],
      "env": {
        "PERL5LIB": "/PWE/webapps/generic.example.web/lib",
        "FCGI_SOCKET_PATH": ":7779"
      },
      "pathMap": [
        [
        "file:///PWE/webapps/generic.example.web",
        "file:///Users/kukam/Workspace/kukamovo/pwe/webapps/generic.example.web"
        ]
      ],
    },
    {
      "type": "perl",
      "request": "launch",
      "name": "PWE Static",
      "program": "${workspaceFolder}/webapps/static.example.web/debug.cgi",
      "stopOnEntry": false,
      "reloadModules": true,
      // "args": [ "page=xxx", "func=sdf" ],
      "env": {
        "PERL5LIB": "/PWE/webapps/static.example.web/lib",
        "FCGI_SOCKET_PATH": ":7779"
      },
      "pathMap": [
        [
        "file:///PWE/webapps/static.example.web",
        "file:///Users/kukam/Workspace/kukamovo/pwe/webapps/static.example.web"
        ]
      ],
    },
    {
      "type": "perl",
      "request": "launch",
      "name": "debuging some scripts",
      "program": "${workspaceFolder}/${relativeFile}",
      "stopOnEntry": true,
      "reloadModules": true,
      "pathMap": [
        [
        "file:///PWE/",
        "file:///Users/kukam/Workspace/kukamovo/pwe/"
        ]
      ]
    }
  ]
}
```
