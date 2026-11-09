# FCG — Repositório de Orquestração

Este repositório **não contém código de nenhuma funcionalidade do sistema**. Ele existe só para
ligar as peças: subir todos os microsserviços do projeto FIAP Cloud Games (FCG) de uma vez,
tanto na sua máquina (com Docker) quanto em um cluster Kubernetes — local ou na nuvem, no
**Azure Kubernetes Service (AKS)**, desde a Fase 4.

Este README foi escrito para qualquer pessoa conseguir entender e rodar o projeto, mesmo sem
conhecimento técnico prévio. Sempre que um termo técnico aparecer pela primeira vez, ele vem
com uma explicação simples ao lado.

---

## 1. O que é este projeto, em uma frase

O FIAP Cloud Games é uma plataforma de jogos. Em vez de ser **um programa só e gigante**
(chamado de "monólito"), o sistema foi dividido em **4 programas menores e independentes**,
chamados de **microsserviços**, que conversam entre si trocando mensagens.

| Microsserviço | O que faz | Repositório |
|---|---|---|
| **API Gateway (Kong)** | Porta única de entrada: recebe as requisições externas, valida o token JWT e roteia para UsersAPI/CatalogAPI | [`k8s/kong`](./k8s/kong) (deste repositório) |
| **UsersAPI** | Cadastro e login de usuários; emite o token JWT usado pelos outros serviços | [`techchallenge_fase2_user`](../techchallenge_fase2_user) |
| **CatalogAPI** | Catálogo de jogos, busca de jogos (Elasticsearch, desde a Fase 4), início da compra e biblioteca; valida o token JWT emitido pelo UsersAPI | [`FCG.Catalog`](../FCG.Catalog) |
| **PaymentsAPI** | Processa (simula) o pagamento de uma compra | [`FCG.Payments`](../FCG.Payments) |
| **NotificationsAPI** | "Envia" (simula, escrevendo no log) e-mails de boas-vindas e confirmação de compra. Desde a Fase 3, roda como **Azure Function** (serverless), não mais como container 24/7 | [`FCG.Notifications`](../FCG.Notifications) |

UsersAPI e CatalogAPI também guardam seus próprios dados em banco (cada um com seu SQL Server
isolado; o CatalogAPI usa ainda MongoDB, Redis e Elasticsearch); PaymentsAPI não tem banco — é
um *Worker Service* sem estado. NotificationsAPI também não tem banco, e desde a Fase 3 também
não é mais um processo de longa duração — é uma Azure Function acionada sob demanda (ver
seção 8).

Pense em cada microsserviço como um **funcionário especialista**: um só cuida de cadastro de
gente, outro só cuida da lista de jogos, outro só processa pagamento, outro só manda e-mail.
Nenhum sabe fazer o trabalho do outro — eles avisam uns aos outros quando terminam uma tarefa.

---

## 2. Como eles conversam: RabbitMQ e "eventos"

Os 4 microsserviços **não se telefonam diretamente**. Em vez disso, eles usam um
"**correio central**" chamado **RabbitMQ** (também chamado de *message broker*, ou "corretor de
mensagens"). Um serviço deixa uma carta (chamada de **evento**) na caixa de correio, e qualquer
outro serviço interessado naquele tipo de carta a recebe automaticamente.

Essa forma de comunicação é chamada de **assíncrona**: quem envia a mensagem não fica esperando
resposta na hora, só continua seu trabalho. Isso deixa o sistema mais resistente — se um
serviço estiver temporariamente fora do ar, a mensagem fica esperando na fila até ele voltar.

### Fluxo 1 — Cadastro de usuário

```
UsersAPI  --publica-->  [UserCreatedEvent]  --RabbitMQ-->  NotificationsAPI
                                                             (envia e-mail de boas-vindas)
```

> **Fase 3:** o NotificationsAPI (Azure Function) e os fluxos acima continuam os mesmos — o que mudou é
> só *como* o NotificationsAPI é executado (função sob demanda em vez de container sempre
> ligado, e RabbitMQ hospedado no CloudAMQP em vez de local). Ver seção 8.

### Fluxo 2 — Compra de jogo

```
CatalogAPI --publica--> [OrderPlacedEvent] --RabbitMQ--> PaymentsAPI
                                                             |
                                                    processa pagamento
                                                             |
                                                             v
                                          publica [PaymentProcessedEvent]
                                                             |
                                    +------------------------+------------------------+
                                    v                                                 v
                              CatalogAPI                                    NotificationsAPI
                       (libera o jogo se Approved)                (envia e-mail de confirmação
                                                                         se Approved)
```

---

## 3. As duas ferramentas que este repositório usa

### 3.1. Docker e Docker Compose (para rodar na sua máquina)

**Docker** empacota cada microsserviço junto com tudo que ele precisa para funcionar (como o
.NET, bibliotecas, etc.) dentro de uma caixa isolada chamada **container**. Isso garante que o
programa roda igual em qualquer computador, sem o problema clássico de "na minha máquina
funciona".

**Docker Compose** é a ferramenta que liga vários containers de uma vez só, com um único
comando. É como um "controle remoto" que liga a TV, o som e o videogame juntos, na ordem certa.

Este repositório tem um arquivo chamado `docker-compose.yml` que descreve **quais containers
subir** — RabbitMQ, UsersAPI (+ seu próprio SQL Server), CatalogAPI (+ seu próprio SQL Server,
MongoDB, Redis e Elasticsearch) e PaymentsAPI — e **como eles se conectam entre si**.

### 3.2. Kubernetes (para rodar em um "cluster", como em produção)

**Kubernetes** (abreviado **k8s**) é uma ferramenta para rodar containers em maior escala, com
recursos de recuperação automática, escalabilidade e organização — o tipo de ferramenta usada
em produção por empresas reais. Ele pode rodar em dois lugares:

- **Na sua máquina** (versão "de bolso", via Docker Desktop, Kind, Minikube ou k3d) — foi assim
  na Fase 3, e continua sendo o jeito de testar localmente (seção 6);
- **Na nuvem**, no **AKS** (*Azure Kubernetes Service*, o Kubernetes gerenciado da Microsoft) —
  o ambiente de produção da Fase 4 (seção 9).

Os mesmos manifestos servem para os dois casos.

No Kubernetes, cada microsserviço é descrito por 4 tipos de arquivo (chamados de
**manifestos**):

| Manifesto | O que é, em termos simples |
|---|---|
| **Deployment** | Diz "quero rodar este container, e se ele cair, suba de novo sozinho" |
| **Service** | Dá um "nome de rede" fixo para o container, para outros acharem ele (ex: `rabbitmq`) |
| **ConfigMap** | Guarda configurações **não sensíveis** (ex: nome de fila, endereço de outro serviço) |
| **Secret** | Guarda dados **sensíveis** (ex: senha), de forma separada e um pouco mais protegida |

---

## 4. Estrutura deste repositório

```
FCG.Orchestration/
├── docker-compose.yml     # sobe tudo na sua máquina com um comando
├── .env.example            # modelo de configuração (copie para .env e preencha)
├── .gitignore
├── azure-pipelines.yml     # pipeline da "plataforma" no Azure DevOps (Fase 4, ver seção 9)
├── scripts/
│   └── deploy-platform.sh  # sobe Kong + Prometheus/Grafana no cluster atual (local ou AKS)
├── k8s/
│   ├── rabbitmq/            # manifestos do RabbitMQ — usado SÓ no cluster local; em
│   │   ├── deployment.yaml  # produção os serviços usam o CloudAMQP (ver seção 8)
│   │   ├── service.yaml
│   │   └── secret.yaml.example  # modelo; copie para secret.yaml (ignorado pelo Git)
│   ├── monitoring/          # Prometheus + Grafana (Item 3 — Observabilidade, ver seção 8)
│   │   ├── prometheus-configmap.yaml
│   │   ├── prometheus-deployment.yaml
│   │   ├── prometheus-service.yaml
│   │   ├── grafana-datasource-configmap.yaml
│   │   ├── grafana-dashboard-provider-configmap.yaml
│   │   ├── grafana-dashboard-json-configmap.yaml
│   │   ├── grafana-deployment.yaml
│   │   └── grafana-service.yaml
│   └── kong/                # API Gateway (porta única de entrada do sistema — também
│       ├── kong.yml.tpl     # não pertence a nenhum microsserviço, é a peça que fica na
│       ├── deployment.yaml  # frente de todos eles). kong.yml.tpl é um MODELO: a chave
│       ├── service.yaml     # JWT é colocada nele só na hora do deploy, pelo script
│       └── admin-service.yaml
└── README.md                # este arquivo
```

Os manifestos k8s de **cada microsserviço** (Deployment, Service, ConfigMap, modelo de Secret —
e, no caso do UsersAPI e do CatalogAPI, também os bancos de dados de cada um) continuam morando
dentro do repositório de cada um, em uma pasta `/k8s` — isso é exigido pelo enunciado do desafio,
para manter cada microsserviço dono do seu próprio deploy. Cada repositório também tem a **sua
própria pipeline** (`azure-pipelines.yml`). Este repositório só centraliza o que é
**compartilhado** (Kong, monitoramento e o RabbitMQ local) e o que **liga tudo** (o
docker-compose).

> **Nenhuma senha ou chave fica no Git.** Onde antes havia arquivos `secret.yaml` com valores
> reais, agora há apenas modelos `secret.yaml.example` com espaços para preencher. Os valores
> reais ficam no seu `.env` (local, ignorado pelo Git) ou nos *Variable Groups* do Azure DevOps
> (produção — ver seção 9).

### Convenção de pastas esperada

Para o `docker-compose.yml` conseguir montar (`build`) a imagem de cada microsserviço, ele
precisa achar o código-fonte deles no seu computador. A convenção adotada é: **clone todos os
repositórios do projeto dentro da mesma pasta pai**, um do lado do outro:

```
minha-pasta-do-projeto/
├── FCG.Orchestration/          ← você está aqui
├── FCG.Payments/
├── FCG.Notifications/
├── FCG.Catalog/
└── techchallenge_fase2_user/   (repositório do UsersAPI)
```

Se você clonou em nomes de pasta diferentes, não precisa renomear nada — só ajuste os caminhos
no seu arquivo `.env` (veja passo 1 abaixo).

---

## 5. Como rodar na sua máquina (Docker Compose)

### Pré-requisitos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado e aberto.
- Ter clonado este repositório e os outros na mesma pasta pai: `FCG.Payments`, `FCG.Catalog` e
  `techchallenge_fase2_user` (ver seção 4).

> **`FCG.Notifications` não sobe mais pelo `docker-compose`** — desde a Fase 3 ele roda como
> Azure Function, não como container (ver seção 8). Continua existindo como repositório, só
> não faz parte deste `docker-compose.yml`.

### Passo a passo

1. **Copie o arquivo de configuração e preencha as senhas:**

   ```bash
   cp .env.example .env
   ```

   Depois abra o `.env` num editor de texto e **preencha obrigatoriamente**:
   `MSSQL_SA_PASSWORD`, `USERS_MSSQL_SA_PASSWORD` (senhas fortes, à sua escolha — o SQL Server
   exige no mínimo 8 caracteres com maiúscula, minúscula, número e símbolo), `JWT_SECRET_KEY`
   (uma frase longa qualquer, com pelo menos 32 caracteres) e `RABBITMQ_USER`/`RABBITMQ_PASSWORD`
   (o modelo já vem com `guest`/`guest`, que serve para uso local).

   Desde a Fase 4 o `docker-compose.yml` **não tem mais senhas "de fábrica"**: se alguma dessas
   variáveis estiver faltando ou vazia, ele nem começa e mostra uma mensagem como
   `Defina JWT_SECRET_KEY no .env`. Isso é proposital — garante que nenhuma senha fique escrita
   no código. Detalhes de cada variável na seção 7.

2. **Suba tudo com um comando**, de dentro desta pasta:

   ```bash
   docker-compose up --build
   ```

   Isso vai:
   - baixar e iniciar o RabbitMQ (o "correio" entre os serviços);
   - subir um SQL Server dedicado para o UsersAPI e outro para o CatalogAPI (cada um com seu
     próprio volume, dados não se misturam);
   - subir um MongoDB (avaliações de jogos) e um Redis (cache da listagem de jogos), ambos
     dedicados ao CatalogAPI — ver seção 8 do README do `techchallenge_fase2_catalog_service`;
   - subir um **Elasticsearch** (o "motor de busca" do CatalogAPI, usado pela rota
     `GET /api/v1/games/search?q=...`, que encontra jogos mesmo com erro de digitação e ordena
     pelos mais relevantes). Aqui ele roda localmente, sem senha; em produção o CatalogAPI usa
     o **Elastic Cloud** (ver seção 9);
   - construir a imagem de cada um dos 3 microsserviços (Payments, Users, Catalog) a partir do
     código-fonte deles;
   - iniciar os 3 microsserviços já conectados ao RabbitMQ e (UsersAPI/CatalogAPI) aos seus
     bancos.

   NotificationsAPI não sobe aqui — para testar o fluxo completo ponta a ponta (incluindo o
   e-mail simulado), aponte `RABBITMQ_HOST`/`RABBITMQ_VIRTUALHOST`/`RABBITMQ_PORT`/
   `RABBITMQ_USE_SSL`/`RABBITMQ_USER`/`RABBITMQ_PASSWORD` no seu `.env` para a instância
   CloudAMQP (ver seção 8), onde a Azure Function está de fato escutando.

   A primeira subida demora mais que as seguintes — o SQL Server e o Elasticsearch levam um
   tempo para ficar prontos, e os serviços que dependem deles (`depends_on: ... condition:
   service_healthy`) esperam esse sinal antes de iniciar.

3. **Verifique se está no ar:**
   - Painel do RabbitMQ: [http://localhost:15672](http://localhost:15672) (usuário/senha: os
     valores de `RABBITMQ_USER`/`RABBITMQ_PASSWORD` do seu `.env`). Nele dá para ver as filas e
     mensagens passando em tempo real.
   - Healthcheck do PaymentsAPI: [http://localhost:5010/healthz](http://localhost:5010/healthz)
     (deve responder `Healthy`).
   - Swagger do UsersAPI: [http://localhost:5001/swagger](http://localhost:5001/swagger).
   - Swagger do CatalogAPI: [http://localhost:5002/swagger](http://localhost:5002/swagger).
   - Busca de jogos: [http://localhost:5002/api/v1/games/search?q=zelda](http://localhost:5002/api/v1/games/search?q=zelda).
   - Elasticsearch: [http://localhost:9200](http://localhost:9200) (responde um JSON com a versão).

4. **Para derrubar tudo:**

   ```bash
   docker-compose down
   ```

   Os dados dos SQL Server ficam guardados nos volumes nomeados (`catalog-sqlserver-data`,
   `users-sqlserver-data`) e sobrevivem a um `down` normal. Para apagar os dados também, use
   `docker-compose down -v`.

### Erros comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| `required variable ... is missing a value: Defina ... no .env` | Falta preencher alguma variável obrigatória no `.env` (ou o arquivo `.env` não existe) | Faça o passo 1 e preencha a variável citada na mensagem |
| `context path does not exist` | O caminho no `.env` não bate com onde você clonou o repositório | Ajuste `PAYMENTS_PATH` / `CATALOG_PATH` / `USERS_PATH` no seu `.env` |
| Algum serviço reiniciando em loop | RabbitMQ, Elasticsearch ou o SQL Server correspondente ainda não terminou de subir | Espere alguns segundos — o `depends_on` já aguarda a dependência ficar saudável, mas a primeira subida pode demorar um pouco (o SQL Server em especial) |
| SQL Server não sobe (`sqlserver` reinicia sem parar) | A senha escolhida não atende às regras de complexidade do SQL Server | Use uma senha com 8+ caracteres, misturando maiúscula, minúscula, número e símbolo |
| Porta já em uso (`port is already allocated`) | Outro programa já está usando a porta 5672, 15672, 5001, 5002, 5010, 5011, 1433, 1434 ou 9200 | Feche o outro programa ou troque a porta no `docker-compose.yml` |
| `401 Unauthorized` chamando o CatalogAPI com um token do UsersAPI | `JWT_SECRET_KEY`/Issuer/Audience divergentes entre os dois serviços | No `docker-compose.yml` deste repositório os dois leem a mesma `JWT_SECRET_KEY` do `.env` — se você sobrescreveu algum valor manualmente, confira se editou os dois lados igual |

---

## 6. Como rodar em um cluster Kubernetes local

> Esta seção é o roteiro **local** (na sua máquina). Para o ambiente de produção no Azure (AKS),
> quem faz o deploy são as pipelines — ver seção 9.

### Pré-requisitos

- Um cluster local rodando: Kubernetes do [Docker Desktop](https://docs.docker.com/desktop/kubernetes/)
  (recomendado), [Kind](https://kind.sigs.k8s.io/), [Minikube](https://minikube.sigs.k8s.io/)
  ou [k3d](https://k3d.io/).
- `kubectl` instalado (o "controle remoto" de linha de comando do Kubernetes).
- Um terminal **bash** para rodar o script da plataforma (no Windows, o Git Bash serve).
- As imagens Docker de cada microsserviço já construídas e disponíveis para o cluster
  (`docker build -t fcg-payments-api:latest .` dentro de `FCG.Payments`, por exemplo — veja o
  README de cada microsserviço para o comando exato).

### Passo a passo

1. **Crie os Secrets a partir dos modelos.** Como nenhuma senha fica mais no Git, cada pasta
   `k8s/` traz só um `secret.yaml.example`. Em cada uma delas, copie o modelo para
   `secret.yaml` (esse nome já é ignorado pelo Git) e troque os textos entre `< >` pelos
   valores reais:

   ```bash
   cp k8s/rabbitmq/secret.yaml.example                 k8s/rabbitmq/secret.yaml
   cp ../FCG.Payments/k8s/secret.yaml.example          ../FCG.Payments/k8s/secret.yaml
   cp ../techchallenge_fase2_user/k8s/secret.yaml.example ../techchallenge_fase2_user/k8s/secret.yaml
   cp ../FCG.Catalog/k8s/secret.yaml.example           ../FCG.Catalog/k8s/secret.yaml
   ```

   Cuidados ao preencher:
   - a **chave JWT** precisa ser a mesma no UsersAPI e no CatalogAPI (e também a usada no
     passo 4, pelo Kong);
   - para usar o RabbitMQ do próprio cluster, use `rabbitmq` como host e o mesmo
     usuário/senha que você colocou em `k8s/rabbitmq/secret.yaml`;
   - no CatalogAPI, para usar um Elasticsearch local em vez do Elastic Cloud, coloque
     `Elasticsearch__Url: "http://catalog-elasticsearch:9200"`, deixe `Elasticsearch__ApiKey`
     vazio e suba o Elasticsearch com `kubectl apply -f ../FCG.Catalog/k8s/local/elasticsearch.yaml`.


2. **Suba o RabbitMQ** (os microsserviços dependem dele para iniciar sem erro):

   ```bash
   kubectl apply -f k8s/rabbitmq/
   ```

3. **Suba cada microsserviço**, a partir da pasta `k8s/` dentro do repositório de cada um. O
   UsersAPI e o CatalogAPI têm seus bancos de dados nos próprios manifestos — não precisam de
   nada além do RabbitMQ como pré-requisito:

   ```bash
   kubectl apply -f ../FCG.Payments/k8s/
   kubectl apply -f ../techchallenge_fase2_user/k8s/
   kubectl apply -f ../FCG.Catalog/k8s/
   ```

   > `FCG.Notifications` não tem mais manifestos k8s — desde a Fase 3 ele roda como Azure
   > Function, fora do cluster (ver seção 8).

4. **Suba a "plataforma" (Kong + Prometheus/Grafana) por último**, com o script deste
   repositório. O Kong precisa que `users-api` e `catalog-api` já existam como Service no
   cluster, porque a configuração dele referencia os dois pelo nome interno. Passe a mesma chave
   JWT usada nos Secrets do passo 1:

   ```bash
   JWT_SECRET_KEY='a-mesma-chave-jwt-do-passo-1' ./scripts/deploy-platform.sh
   ```

   O script faz, em ordem: gera a configuração do Kong a partir do modelo `k8s/kong/kong.yml.tpl`
   colocando a chave no lugar de `${JWT_SECRET_KEY}`; grava o resultado como o Secret
   `kong-config` dentro do cluster (a chave nunca é salva em arquivo no Git); aplica
   `k8s/kong/`; reinicia o Kong e espera ele ficar pronto; aplica `k8s/monitoring/`; e, no fim,
   mostra o endereço do `kong-proxy`. É **o mesmo script** que a pipeline usa no AKS.

5. **Confira se todos os Pods estão rodando:**

   ```bash
   kubectl get pods
   ```

   Você deve ver algo como (UsersAPI e CatalogAPI rodam com **2 cópias** cada, por isso
   aparecem duas vezes):

   ```
   NAME                                 READY   STATUS    RESTARTS   AGE
   rabbitmq-xxxxxxxxxx-xxxxx           1/1     Running   0          3m
   payments-api-xxxxxxxxxx-xxxxx       1/1     Running   0          2m
   users-api-xxxxxxxxxx-xxxxx          1/1     Running   0          2m
   users-api-xxxxxxxxxx-yyyyy          1/1     Running   0          2m
   users-sqlserver-xxxxxxxxxx-xxxxx    1/1     Running   0          2m
   catalog-api-xxxxxxxxxx-xxxxx        1/1     Running   0          2m
   catalog-api-xxxxxxxxxx-yyyyy        1/1     Running   0          2m
   catalog-sqlserver-xxxxxxxxxx-xxxxx  1/1     Running   0          2m
   catalog-mongo-xxxxxxxxxx-xxxxx      1/1     Running   0          2m
   catalog-redis-xxxxxxxxxx-xxxxx      1/1     Running   0          2m
   kong-xxxxxxxxxx-xxxxx               1/1     Running   0          30s
   prometheus-xxxxxxxxxx-xxxxx         1/1     Running   0          30s
   grafana-xxxxxxxxxx-xxxxx            1/1     Running   0          30s
   ```

   (Se você subiu o Elasticsearch local no passo 1, também aparece um `catalog-elasticsearch`.)

   > As imagens (`fcg-users-api:latest`, `fcg-catalog-api:latest` etc.) usam
   > `imagePullPolicy: IfNotPresent` — precisam já estar carregadas no cluster (ex:
   > `minikube image load fcg-users-api:latest`) antes do `apply`, senão o Pod fica em
   > `ImagePullBackOff`. No Docker Desktop, basta ter feito o `docker build` na mesma máquina.

6. **Acesse o Grafana e o Prometheus** (Item 3 — Observabilidade, ver seção 8). Eles **não**
   ficam abertos para fora do cluster de propósito (no AKS isso significaria um painel com login
   padrão exposto na internet). Para abrir, crie um "túnel" temporário da sua máquina até eles,
   cada um em um terminal (deixe o comando rodando enquanto usa):

   ```bash
   kubectl port-forward svc/grafana 3000:3000        # depois abra http://localhost:3000
   kubectl port-forward svc/prometheus 9090:9090     # depois abra http://localhost:9090
   ```

   O Grafana tem login anônimo habilitado e o dashboard "FCG" já provisionado. Os mesmos
   comandos funcionam com o cluster do AKS.

7. **Para derrubar tudo:**

   ```bash
   kubectl delete -f k8s/kong/
   kubectl delete secret kong-config
   kubectl delete -f k8s/rabbitmq/
   kubectl delete -f k8s/monitoring/
   kubectl delete -f ../FCG.Payments/k8s/
   kubectl delete -f ../techchallenge_fase2_user/k8s/
   kubectl delete -f ../FCG.Catalog/k8s/
   ```

   > Os bancos (SQL Server e MongoDB) agora guardam os dados em **volumes persistentes**
   > (*PersistentVolumeClaim*, um "HD" que sobrevive ao Pod). Apagar a pasta `k8s/` do serviço
   > com `kubectl delete -f` também apaga esses volumes — e os dados junto.

### Como os serviços se acham dentro do cluster

Dentro do Kubernetes, cada microsserviço enxerga os outros pelo **nome do Service**, não por
`localhost`. Por isso, no cluster local, o Secret de cada microsserviço aponta
`RABBITMQ__HOST=rabbitmq` — que é exatamente o `metadata.name` definido em
`k8s/rabbitmq/service.yaml`. O Kubernetes resolve esse nome automaticamente para o endereço
certo do container, de forma parecida com como um site normal resolve `google.com` para um IP.
(No AKS, esse mesmo campo aponta para o endereço do CloudAMQP.)

### Testando o API Gateway (Kong)

O Kong é a única porta de entrada — depois dele no ar, pare de chamar `users-api`/`catalog-api`
diretamente e use sempre o endereço do `kong-proxy`.

1. **Descubra o endereço do gateway.** O `kong-proxy` é um Service do tipo **LoadBalancer**, na
   porta 80 (a porta padrão da web, então nem precisa escrever a porta no endereço):

   ```bash
   kubectl get service kong-proxy
   # ex.: kong-proxy   LoadBalancer   10.x.x.x   localhost   80:3xxxx/TCP
   ```

   - **Docker Desktop:** a coluna `EXTERNAL-IP` mostra `localhost` — use `http://localhost`.
   - **AKS:** a coluna `EXTERNAL-IP` mostra um **IP público** (pode levar ~1 minuto para
     aparecer; antes disso fica `<pending>`) — use `http://<EXTERNAL-IP>`.
   - **Minikube:** rode `minikube tunnel` em outro terminal para o IP aparecer.
   - **Kind/k3d ou se ficar `<pending>` localmente:** use um túnel,
     `kubectl port-forward svc/kong-proxy 8080:80`, e troque `http://localhost` por
     `http://localhost:8080` nos comandos abaixo.

   Os exemplos abaixo usam `http://localhost` (Docker Desktop); no AKS, troque pelo IP público.

2. **Faça login via Gateway** (rota pública, sem token):

   ```bash
   curl -X POST http://localhost/api/Usuario/login \
     -H "Content-Type: application/json" \
     -d '{"email":"seu@email.com","senha":"suaSenha"}'
   ```

   A resposta traz o token JWT.

3. **Chame uma rota protegida sem token** (deve dar `401`, o plugin `jwt` do Kong bloqueia antes
   de a requisição sequer chegar no CatalogAPI):

   ```bash
   curl -i -X POST http://localhost/api/v1/games \
     -H "Content-Type: application/json" \
     -d '{"nome":"Jogo Teste"}'
   ```

4. **Repita com o token do passo 2** (deve passar e chegar no CatalogAPI):

   ```bash
   curl -X POST http://localhost/api/v1/games \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer <token do passo 2>" \
     -d '{"nome":"Jogo Teste"}'
   ```

5. **Listagem e busca de jogos continuam públicas, sem token** (rota `catalog-games-read`, que
   cobre todo `GET /api/v1/games...`):

   ```bash
   curl http://localhost/api/v1/games
   curl "http://localhost/api/v1/games/search?q=zelda"
   ```

> A Admin API do Kong (porta 8001) não é exposta fora do cluster de propósito — pra inspecionar
> o estado do Kong (`/status`, `/routes`, `/services`), use `kubectl port-forward svc/kong-admin
> 8001:8001` e acesse `http://localhost:8001` só localmente.

---

## 7. Variáveis de ambiente deste repositório

Estas variáveis ficam no seu arquivo `.env` e são lidas pelo `docker-compose.yml`. As marcadas
como **obrigatória** não têm valor padrão: sem elas o `docker-compose` se recusa a subir.

| Variável | Usada por | Descrição | Padrão |
|---|---|---|---|
| `RABBITMQ_USER` | RabbitMQ + os 3 microsserviços | Usuário de acesso ao RabbitMQ | **obrigatória** (o `.env.example` sugere `guest` para uso local) |
| `RABBITMQ_PASSWORD` | RabbitMQ + os 3 microsserviços | Senha de acesso ao RabbitMQ | **obrigatória** (o `.env.example` sugere `guest` para uso local) |
| `RABBITMQ_HOST` | Payments, Users, Catalog | Endereço do broker RabbitMQ — local (`rabbitmq`) ou CloudAMQP | `rabbitmq` |
| `RABBITMQ_VIRTUALHOST` | Payments, Users, Catalog | Vhost do RabbitMQ a usar | `/` |
| `RABBITMQ_PORT` | Payments, Users, Catalog | Porta do broker — vazio usa a porta padrão do esquema (5672/5671); defina `5671` para o CloudAMQP | (vazio) |
| `RABBITMQ_USE_SSL` | Payments, Users, Catalog | `true` liga TLS (`rabbitmqs://`, necessário para o CloudAMQP); `false` usa `rabbitmq://` sem TLS (broker local) | `false` |
| `MSSQL_SA_PASSWORD` | SQL Server do CatalogAPI + o próprio CatalogAPI | Senha do usuário `sa` do banco do Catálogo | **obrigatória** |
| `USERS_MSSQL_SA_PASSWORD` | SQL Server do UsersAPI + o próprio UsersAPI | Senha do usuário `sa` do banco de Usuários | **obrigatória** |
| `JWT_SECRET_KEY` | UsersAPI (emite) + CatalogAPI (valida) | Chave de assinatura do token JWT — precisa ser **igual** nos dois | **obrigatória** |
| `ELASTICSEARCH_URL` | CatalogAPI | Endereço do Elasticsearch usado pela busca de jogos. Vazio = container local `catalog-elasticsearch`; preencha com a URL do Elastic Cloud para testar contra a nuvem | `http://catalog-elasticsearch:9200` |
| `ELASTICSEARCH_API_KEY` | CatalogAPI | Chave de acesso (*API Key*) do Elastic Cloud. Vazio = sem autenticação (container local) | (vazio) |
| `PAYMENTS_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Payments` | `../FCG.Payments` |
| `CATALOG_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Catalog` | `../FCG.Catalog` |
| `USERS_PATH` | `docker-compose.yml` | Caminho local do repositório `techchallenge_fase2_user` | `../techchallenge_fase2_user` |

> O arquivo `.env` **nunca vai para o Git** (está no `.gitignore`). As credenciais `guest`/`guest`
> sugeridas no `.env.example` servem **apenas para desenvolvimento local** — nunca use em um
> ambiente real. Em produção (AKS), os valores equivalentes vêm dos *Variable Groups* do Azure
> DevOps (ver seção 9).

---

## 8. Fase 3 — Serverless e Observabilidade

### 8.1. Item 2 — Migração para arquitetura Serverless

O `NotificationsAPI` deixou de rodar como container 24/7 e virou uma **Azure Function**
(repositório [`FCG.Notifications`](../FCG.Notifications), pasta `FCG.Notifications.Function`),
acionada automaticamente por novas mensagens no RabbitMQ via **`RabbitMQTrigger`** nativo do
Azure Functions para brokers RabbitMQ *self-managed*/externos.

Como esse recurso do Azure precisa alcançar o broker pela internet, o RabbitMQ compartilhado foi
migrado do container local para o **CloudAMQP** (plano gratuito "Little Lemur"). Payments, Users
e Catalog continuam publicando/consumindo do mesmo jeito — só o endereço do broker muda, via as
variáveis `RABBITMQ_HOST`/`RABBITMQ_VIRTUALHOST`/`RABBITMQ_PORT`/`RABBITMQ_USE_SSL` (seção 7).

Para rodar o sistema todo apontando para o CloudAMQP (necessário para o fluxo de notificações
funcionar de ponta a ponta), defina no seu `.env`:

```bash
RABBITMQ_HOST=algo.rmq.cloudamqp.com
RABBITMQ_VIRTUALHOST=seu-vhost
RABBITMQ_PORT=5671
RABBITMQ_USE_SSL=true
RABBITMQ_USER=seu-usuario-cloudamqp
RABBITMQ_PASSWORD=sua-senha-cloudamqp
```

Deploy e detalhes da Azure Function (Azure Bicep, `infra/main.bicep`, criação da topologia de
filas): ver README do [`FCG.Notifications`](../FCG.Notifications).

### 8.2. Item 3 — Stack de Observabilidade (Prometheus + Grafana)

CatalogAPI e UsersAPI expõem métricas HTTP (`prometheus-net.AspNetCore`) no endpoint `/metrics`
— latência, contagem de requisições e código de status por controller/action. O Prometheus
(`k8s/monitoring/`) faz *scrape* desses endpoints a cada 5 segundos, e o Grafana lê do
Prometheus como fonte de dados, com um dashboard "FCG" já provisionado automaticamente (sem
precisar importar nada na mão) com 4 painéis: latência p95, RPS total, requisições por código de
status e taxa de erro (5xx).

Na Fase 3 essa stack rodava só no Kubernetes local; desde a Fase 4 ela é aplicada pelo
`scripts/deploy-platform.sh` tanto no cluster local quanto no AKS. Em ambos, Grafana e
Prometheus ficam só dentro do cluster e são acessados com `kubectl port-forward` (seção 6,
passo 6).

---

## 9. Fase 4 — Cloud, CI/CD e Alta Performance

Na Fase 4 o sistema saiu da máquina local e passou a rodar **na nuvem da Microsoft (Azure)**,
com **entrega automática** a cada mudança de código e **nenhuma senha escrita no código**.

### 9.1. Como fica a arquitetura no Azure

```
                       Internet (usuário / Postman / navegador)
                                        |
                                        v
                        Azure Load Balancer — IP público
                     (criado automaticamente pelo Service kong-proxy)
                                        |
  ======================== Cluster AKS (Azure Kubernetes Service) ========================
                                        |
                                        v
                              Kong (API Gateway, valida JWT)
                               |                         |
                               v                         v
                   UsersAPI (2 cópias)            CatalogAPI (2 cópias)          PaymentsAPI
                         |                       |      |      |                 (worker)
                    SQL Server               SQL Server  MongoDB  Redis
                                                                         Prometheus + Grafana
  ========================================================================================
                               |                    |                         |
                               v                    v                         v
                    CloudAMQP (RabbitMQ         Elastic Cloud           Azure Function
                    gerenciado, usado por       (busca de jogos         (NotificationsAPI,
                    todos os serviços)          do CatalogAPI)          ver seção 8)

  Imagens Docker: Azure Container Registry (ACR)  |  Senhas: Azure DevOps Variable Groups
```

As peças, uma a uma:

| Peça | O que é, em termos simples | Papel no FCG |
|---|---|---|
| **AKS** (*Azure Kubernetes Service*) | Kubernetes "alugado" e administrado pela Microsoft | Onde rodam Kong, UsersAPI, CatalogAPI, PaymentsAPI, os bancos e o monitoramento |
| **ACR** (*Azure Container Registry*) | Um "depósito" privado de imagens Docker | As pipelines guardam ali cada versão nova das APIs; o AKS busca as imagens de lá |
| **Azure Load Balancer** | O "porteiro" com endereço público na internet | Criado sozinho pelo AKS porque o `kong-proxy` é do tipo `LoadBalancer`; tudo que vem de fora entra por ele e cai no Kong |
| **Elastic Cloud** | Elasticsearch gerenciado (o motor de busca, sem precisar cuidar de servidor) | Atende a busca do CatalogAPI (`GET /api/v1/games/search?q=`), que tolera erros de digitação e ordena por relevância |
| **CloudAMQP** | RabbitMQ gerenciado (o "correio" entre serviços) | Usado em produção por todos os serviços e pela Azure Function — o RabbitMQ de `k8s/rabbitmq/` fica só para uso local |
| **MongoDB e Redis** | Banco NoSQL e cache em memória | Já existiam no CatalogAPI (avaliações e cache da listagem); no AKS rodam como Pods |
| **Variable Groups** (Azure DevOps) | Um "cofre" de senhas da ferramenta de pipelines, que podem ser ligados ao **Azure Key Vault** (o cofre oficial do Azure) | Guardam todas as senhas e chaves; as pipelines as entregam ao cluster na hora do deploy |

Alguns cuidados de **disponibilidade** foram adicionados nos manifestos de cada serviço:
UsersAPI e CatalogAPI rodam com **2 cópias** (réplicas) cada, então uma pode cair ou ser
atualizada enquanto a outra atende; os bancos (SQL Server e MongoDB) guardam os dados em
**volumes persistentes**, que não se perdem quando o Pod reinicia; e as APIs recebem todas as
configurações do ConfigMap/Secret de uma vez (`envFrom`).

### 9.2. Senhas fora do código

Nenhuma credencial fica mais no Git:

- a chave JWT do Kong saiu de `k8s/kong/kong-config-secret.yaml` (apagado) e virou o modelo
  `k8s/kong/kong.yml.tpl`, preenchido só na hora do deploy pelo `scripts/deploy-platform.sh`;
- os `secret.yaml` de cada repositório viraram modelos `secret.yaml.example`; em produção, os
  Secrets são **criados pelas pipelines** a cada deploy, com valores lidos destes Variable Groups
  do Azure DevOps:

  | Variable Group | O que guarda | Usado por |
  |---|---|---|
  | `fcg-shared-secrets` | `jwt-secret-key` e os dados de acesso ao CloudAMQP (`rabbitmq-host`, `rabbitmq-vhost`, `rabbitmq-port`, `rabbitmq-use-ssl`, `rabbitmq-user`, `rabbitmq-password`) | Todas as pipelines |
  | `fcg-users-secrets` | `users-sql-password` | Pipeline do UsersAPI |
  | `fcg-catalog-secrets` | `catalog-sql-password`, `elasticsearch-url`, `elasticsearch-api-key` | Pipeline do CatalogAPI |

- o `docker-compose.yml` não tem mais senhas padrão — tudo vem do `.env` (seção 5).

### 9.3. As pipelines (CI/CD no Azure DevOps)

**CI/CD** (*Integração e Entrega Contínuas*) quer dizer: a cada mudança enviada para a branch
`main`, um robô compila, testa e publica a nova versão sozinho, sem ninguém precisar rodar
comandos na mão. Cada repositório tem a **sua própria pipeline**, no arquivo
`azure-pipelines.yml`:

| Pipeline | Repositório | O que faz |
|---|---|---|
| **Plataforma** | este (`FCG.Orchestration`) | Roda quando mudam `k8s/kong/`, `k8s/monitoring/`, `scripts/` ou a própria pipeline. Conecta no AKS (`az aks get-credentials`) e executa o `scripts/deploy-platform.sh` com a chave JWT do Variable Group `fcg-shared-secrets` |
| **UsersAPI** | `techchallenge_fase2_user` | Build & Test → Imagem → Deploy (abaixo) |
| **CatalogAPI** | `FCG.Catalog` | Build & Test → Imagem → Deploy (abaixo) |
| **PaymentsAPI** | `FCG.Payments` | Build & Test → Imagem → Deploy (abaixo) |

As pipelines das três APIs seguem as mesmas 3 etapas:

1. **Build & Test** — compila o código e roda os testes automáticos (o UsersAPI ganhou um projeto
   de testes unitários nesta fase). Se algum teste falhar, para aqui.
2. **Imagem** — gera a imagem Docker com uma etiqueta única por execução (o número do build,
   `BuildId`, para saber exatamente qual versão está no ar), faz uma **varredura de
   vulnerabilidades** com o **Trivy** (por enquanto só reporta, não bloqueia) e envia a imagem
   para o **ACR**.
3. **Deploy** — cria/atualiza o Secret do serviço com os valores dos Variable Groups, aplica os
   manifestos e troca a imagem por uma **atualização gradual** (*rolling update*) com
   `maxUnavailable: 0`: as cópias novas sobem antes de as antigas saírem, então o serviço não
   fica fora do ar. Se a nova versão não ficar saudável, a pipeline faz **rollback
   automático** (`kubectl rollout undo`), voltando para a versão anterior.

As pipelines usam uma *service connection* chamada `fcg-azure` e apontam para o grupo de
recursos `rg-fcg`, o cluster `aks-fcg` e o registro `fcgacr` — nomes que podem ser ajustados nas
variáveis do topo de cada `azure-pipelines.yml`.

### 9.4. Ordem do primeiro deploy

Na primeira vez, com o AKS, o ACR (ligado ao AKS para ele poder baixar as imagens), o Elastic
Cloud, o CloudAMQP, a *service connection* `fcg-azure` e os três Variable Groups já criados:

1. **Rode a pipeline da Plataforma** (este repositório) — cria o Secret `kong-config`, sobe o
   Kong (que já ganha o IP público do Azure Load Balancer) e o monitoramento.
2. **Rode as pipelines dos serviços** — UsersAPI, CatalogAPI e PaymentsAPI (em qualquer ordem
   entre si). Cada uma cria o seu Secret e sobe o seu serviço e os bancos dele. Enquanto
   `users-api` e `catalog-api` não existirem, o Kong não tem para onde encaminhar as chamadas;
   assim que os serviços sobem, as rotas passam a funcionar. (Se algo parecer travado, rodar a
   pipeline da Plataforma de novo reinicia o Kong.)
3. **Pegue o IP público** com `kubectl get service kong-proxy` (coluna `EXTERNAL-IP`) e teste
   como na seção 6 ("Testando o API Gateway"), trocando `localhost` por esse IP — por exemplo,
   `http://<EXTERNAL-IP>/api/v1/games/search?q=zelda`.

Depois disso, cada `git push` na `main` de um repositório atualiza só aquele serviço.

---

## 10. Limitações conhecidas (transparência)

- **Senhas antigas continuam no histórico do Git.** Os arquivos com a chave JWT e senhas foram
  removidos e substituídos por modelos, mas versões antigas deles ainda podem ser vistas no
  histórico de commits. Por isso, todas essas credenciais devem ser consideradas vazadas e
  **trocadas** (novas chaves/senhas nos Variable Groups e no `.env`).
- **Os bancos de dados rodam como Pods dentro do AKS**, não como serviços gerenciados do Azure
  (Azure SQL, Cosmos DB, Azure Cache for Redis). Os dados ficam em volumes persistentes, mas
  backup, alta disponibilidade e atualização dos bancos não são automáticos — cada banco tem uma
  única cópia. O Elasticsearch e o RabbitMQ, por outro lado, já são serviços gerenciados (Elastic
  Cloud e CloudAMQP).
- **A varredura de vulnerabilidades (Trivy) só reporta**, não bloqueia a pipeline (está com
  `--exit-code 0`; dá para trocar para `1` quando a equipe quiser barrar imagens com falhas
  graves).
- **A ligação com o Azure Key Vault não está no código**: as pipelines leem dos Variable Groups;
  ligar esses grupos ao Key Vault é uma configuração opcional, feita na tela do Azure DevOps.
- O `NotificationsAPI` (Azure Function) não expõe endpoint HTTP de healthcheck — não se aplica a
  uma função serverless; sua saúde é observada via Application Insights, no próprio Azure.
- A stack de observabilidade (Prometheus/Grafana) cobre CatalogAPI e UsersAPI; PaymentsAPI ainda
  não expõe métricas Prometheus (só o healthcheck HTTP em `/healthz`), e o NotificationsAPI
  (Azure Function) não é coberto por essa stack — métricas dele ficam só no Application Insights.
- Não há retry automático nem fila de mensagens mortas (*dead-letter queue*) configurada no
  RabbitMQ ainda — se uma mensagem falhar na validação, ela é apenas descartada com um log de
  aviso.
- **`Issuer`/`Audience` do JWT usam valores diferentes por ambiente**: aqui no `docker-compose`,
  ambos os serviços usam `FCG.Usuario.Api`/`FCG.Usuario.Client`; rodando via Kubernetes ou
  `dotnet run` direto (appsettings locais de cada repo), o valor é `FCG.Catalog.Api`/
  `FCG.Catalog.Client`. Cada ambiente é internamente consistente (o token de um não vale no
  outro, mas isso já era esperado — são execuções separadas), mas é uma pegadinha de manutenção
  se alguém copiar um valor de um ambiente pro outro sem perceber a diferença.
