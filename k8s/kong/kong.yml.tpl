# Configuração declarativa do Kong (modo DB-less). Este arquivo é um TEMPLATE:
# ${JWT_SECRET_KEY} é substituído pela chave real na hora do deploy
# (scripts/deploy-platform.sh ou pipeline azure-pipelines.yml), e o resultado
# vira o Secret "kong-config" dentro do cluster. A chave nunca fica no Git.
_format_version: "3.0"

services:
  - name: users-api
    url: http://users-api.default.svc.cluster.local:80
    routes:
      # POST /api/Usuario/criar e /login — públicas hoje no código
      # (nenhum [Authorize] no UsuarioController), sem token ainda
      # nesse ponto do fluxo (é aqui que o token é emitido).
      - name: users-register-login
        paths:
          - /api/Usuario
        methods:
          - POST
        strip_path: false
      # GET /api/health — público (sem [Authorize]).
      - name: users-health
        paths:
          - /api/health
        methods:
          - GET
        strip_path: false
      # GET /api/health/secure — tem [Authorize] no código.
      # Precisa vir depois da rota acima: Kong escolhe o path mais
      # específico primeiro, então esta rota "vence" para essa URL.
      - name: users-health-secure
        paths:
          - /api/health/secure
        methods:
          - GET
        strip_path: false

  - name: catalog-api
    url: http://catalog-api.default.svc.cluster.local:80
    routes:
      # GET /api/v1/games e /api/v1/games/{id} — sem [Authorize] no código.
      - name: catalog-games-read
        paths:
          - /api/v1/games
        methods:
          - GET
        strip_path: false
      # POST/PUT/DELETE /api/v1/games — têm [Authorize] no código.
      - name: catalog-games-write
        paths:
          - /api/v1/games
        methods:
          - POST
          - PUT
          - DELETE
        strip_path: false
      # /api/v1/purchases — controller inteiro tem [Authorize] na classe.
      - name: catalog-purchases
        paths:
          - /api/v1/purchases
        strip_path: false
      # /api/v1/users/{userId}/library — controller inteiro tem [Authorize].
      - name: catalog-library
        paths:
          - /api/v1/users
        strip_path: false
      # GET /healthz — sem [Authorize] (probe de infraestrutura).
      - name: catalog-health
        paths:
          - /healthz
        methods:
          - GET
        strip_path: false

# Consumer representa "quem" apresenta o token — aqui não é uma pessoa,
# é o conjunto UsersAPI/CatalogAPI que compartilha a mesma chave JWT.
# O plugin jwt usa a claim "iss" do token para achar este consumer pela
# chave abaixo (key), depois valida a assinatura com "secret".
consumers:
  - username: fcg-services
    jwt_secrets:
      - key: FCG.Catalog.Api
        algorithm: HS256
        secret: ${JWT_SECRET_KEY}

# Plugin jwt só nas rotas que hoje exigem [Authorize] no código.
# Login/registro e as leituras públicas ficam de fora de propósito.
plugins:
  - name: jwt
    route: users-health-secure
  - name: jwt
    route: catalog-games-write
  - name: jwt
    route: catalog-purchases
  - name: jwt
    route: catalog-library
