# FCG — Repositório de Orquestração

Este repositório **não contém código de nenhuma funcionalidade do sistema**. Ele existe só para
ligar as peças: subir todos os microsserviços do projeto FIAP Cloud Games (FCG) de uma vez,
tanto na sua máquina (com Docker) quanto em um cluster Kubernetes local.

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
| **UsersAPI** | Cadastro e login de usuários; emite o token JWT usado pelos outros serviços | [`techchallenge_fase2_user`](../techchallenge_fase2_user) |
| **CatalogAPI** | Catálogo de jogos, início da compra e biblioteca; valida o token JWT emitido pelo UsersAPI | [`FCG.Catalog`](../FCG.Catalog) |
| **PaymentsAPI** | Processa (simula) o pagamento de uma compra | [`FCG.Payments`](../FCG.Payments) |
| **NotificationsAPI** | "Envia" (simula, escrevendo no log) e-mails de boas-vindas e confirmação de compra. Desde a Fase 3, roda como **Azure Function** (serverless), não mais como container 24/7 | [`FCG.Notifications`](../FCG.Notifications) |

UsersAPI e CatalogAPI também guardam seus próprios dados em banco (cada um com seu SQL Server
isolado); PaymentsAPI não tem banco — é um *Worker Service* sem estado. NotificationsAPI também
não tem banco, e desde a Fase 3 também não é mais um processo de longa duração — é uma Azure
Function acionada sob demanda (ver seção 9).

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
> ligado, e RabbitMQ hospedado no CloudAMQP em vez de local). Ver seção 9.

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
subir** — RabbitMQ, UsersAPI (+ seu próprio SQL Server), CatalogAPI (+ seu próprio SQL Server),
PaymentsAPI e NotificationsAPI — e **como eles se conectam entre si**.

### 3.2. Kubernetes (para rodar em um "cluster", simulando produção)

**Kubernetes** (abreviado **k8s**) é uma ferramenta para rodar containers em maior escala, com
recursos de recuperação automática, escalabilidade e organização — o tipo de ferramenta usada
em produção por empresas reais. Aqui usamos uma versão "de bolso" dele, rodando localmente no
seu computador (via Kind, Minikube, k3d ou Docker Desktop), só para demonstrar que o projeto
está pronto para esse tipo de ambiente.

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
├── .env.example            # modelo de configuração (copie para .env)
├── .gitignore
├── k8s/
│   ├── rabbitmq/            # manifestos do RabbitMQ (broker compartilhado, não
│   │   ├── deployment.yaml  # pertence a nenhum microsserviço específico, por isso
│   │   ├── service.yaml     # mora aqui e não dentro de FCG.Payments/FCG.Notifications)
│   │   └── secret.yaml
│   └── monitoring/          # Prometheus + Grafana (Item 3 — Observabilidade, ver seção 9)
│       ├── prometheus-configmap.yaml
│       ├── prometheus-deployment.yaml
│       ├── prometheus-service.yaml
│       ├── grafana-datasource-configmap.yaml
│       ├── grafana-dashboard-provider-configmap.yaml
│       ├── grafana-dashboard-json-configmap.yaml
│       ├── grafana-deployment.yaml
│       └── grafana-service.yaml
└── README.md                # este arquivo
```

Os manifestos k8s de **cada microsserviço** (Deployment, Service, ConfigMap, Secret — e, no caso
do UsersAPI e do CatalogAPI, também o Deployment/Service do próprio SQL Server) continuam morando
dentro do repositório de cada um, em uma pasta `/k8s` — isso é exigido pelo enunciado do desafio,
para manter cada microsserviço dono do seu próprio deploy. Este repositório só centraliza o que é
**compartilhado** (o RabbitMQ) e o que **liga tudo** (o docker-compose).

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
no seu arquivo `.env` (veja passo 2 abaixo).

---

## 5. Como rodar na sua máquina (Docker Compose)

### Pré-requisitos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado e aberto.
- Ter clonado este repositório e os outros na mesma pasta pai: `FCG.Payments`, `FCG.Catalog` e
  `techchallenge_fase2_user` (ver seção 4).

> **`FCG.Notifications` não sobe mais pelo `docker-compose`** — desde a Fase 3 ele roda como
> Azure Function, não como container (ver seção 9). Continua existindo como repositório, só
> não faz parte deste `docker-compose.yml`.

### Passo a passo

1. **Copie o arquivo de configuração:**

   ```bash
   cp .env.example .env
   ```

   (Os valores padrão já funcionam para rodar localmente, não precisa editar nada de início. Se
   quiser usar uma chave JWT própria em vez do placeholder de desenvolvimento, defina
   `JWT_SECRET_KEY` no seu `.env` — ver seção 7.)

2. **Suba tudo com um comando**, de dentro desta pasta:

   ```bash
   docker-compose up --build
   ```

   Isso vai:
   - baixar e iniciar o RabbitMQ (o "correio" entre os serviços);
   - subir um SQL Server dedicado para o UsersAPI e outro para o CatalogAPI (cada um com seu
     próprio volume, dados não se misturam);
   - construir a imagem de cada um dos 3 microsserviços (Payments, Users, Catalog) a partir do
     código-fonte deles;
   - iniciar os 3 microsserviços já conectados ao RabbitMQ e (UsersAPI/CatalogAPI) ao seu banco.

   NotificationsAPI não sobe aqui — para testar o fluxo completo ponta a ponta (incluindo o
   e-mail simulado), aponte `RABBITMQ_HOST`/`RABBITMQ_VIRTUALHOST`/`RABBITMQ_PORT`/
   `RABBITMQ_USE_SSL`/`RABBITMQ_USER`/`RABBITMQ_PASSWORD` no seu `.env` para a instância
   CloudAMQP (ver seção 9), onde a Azure Function está de fato escutando.

   A primeira subida demora mais que as seguintes — o SQL Server leva um tempo para ficar pronto,
   e os serviços que dependem dele (`depends_on: ... condition: service_healthy`) esperam esse
   sinal antes de iniciar.

3. **Verifique se está no ar:**
   - Painel do RabbitMQ: [http://localhost:15672](http://localhost:15672) (usuário/senha:
     `guest` / `guest`). Nele dá para ver as filas e mensagens passando em tempo real.
   - Healthcheck do PaymentsAPI: [http://localhost:5010/healthz](http://localhost:5010/healthz)
     (deve responder `Healthy`).
   - Swagger do UsersAPI: [http://localhost:5001/swagger](http://localhost:5001/swagger).
   - Swagger do CatalogAPI: [http://localhost:5002/swagger](http://localhost:5002/swagger).

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
| `context path does not exist` | O caminho no `.env` não bate com onde você clonou o repositório | Ajuste `PAYMENTS_PATH` / `CATALOG_PATH` / `USERS_PATH` no seu `.env` |
| Algum serviço reiniciando em loop | RabbitMQ ou o SQL Server correspondente ainda não terminou de subir | Espere alguns segundos — o `depends_on` já aguarda a dependência ficar saudável, mas a primeira subida pode demorar um pouco (o SQL Server em especial) |
| Porta já em uso (`port is already allocated`) | Outro programa já está usando a porta 5672, 15672, 5001, 5002, 5010, 5011, 1433 ou 1434 | Feche o outro programa ou troque a porta no `docker-compose.yml` |
| `401 Unauthorized` chamando o CatalogAPI com um token do UsersAPI | `JWT_SECRET_KEY`/Issuer/Audience divergentes entre os dois serviços | No `docker-compose.yml` deste repositório os dois já vêm alinhados por padrão — se você sobrescreveu algum valor manualmente, confira se editou os dois lados igual |

---

## 6. Como rodar em um cluster Kubernetes local

### Pré-requisitos

- Um cluster local rodando: [Kind](https://kind.sigs.k8s.io/), [Minikube](https://minikube.sigs.k8s.io/),
  [k3d](https://k3d.io/) ou Kubernetes do Docker Desktop.
- `kubectl` instalado (o "controle remoto" de linha de comando do Kubernetes).
- As imagens Docker de cada microsserviço já construídas e disponíveis para o cluster
  (`docker build -t fcg-payments-api:latest .` dentro de `FCG.Payments`, por exemplo — veja o
  README de cada microsserviço para o comando exato).

### Passo a passo

1. **Suba o RabbitMQ e a stack de observabilidade primeiro** (os microsserviços dependem do
   RabbitMQ para iniciar sem erro; Prometheus/Grafana podem subir em paralelo):

   ```bash
   kubectl apply -f k8s/rabbitmq/
   kubectl apply -f k8s/monitoring/
   ```

2. **Suba cada microsserviço**, a partir da pasta `k8s/` dentro do repositório de cada um. O
   UsersAPI e o CatalogAPI têm SQL Server próprio nos seus manifestos — não precisam de nada
   além do RabbitMQ como pré-requisito:

   ```bash
   kubectl apply -f ../FCG.Payments/k8s/
   kubectl apply -f ../techchallenge_fase2_user/k8s/
   kubectl apply -f ../FCG.Catalog/k8s/
   ```

   > `FCG.Notifications` não tem mais manifestos k8s — desde a Fase 3 ele roda como Azure
   > Function, fora do cluster (ver seção 9).

3. **Confira se todos os Pods estão rodando:**

   ```bash
   kubectl get pods
   ```

   Você deve ver algo como:

   ```
   NAME                                 READY   STATUS    RESTARTS   AGE
   rabbitmq-xxxxxxxxxx-xxxxx           1/1     Running   0          2m
   prometheus-xxxxxxxxxx-xxxxx         1/1     Running   0          2m
   grafana-xxxxxxxxxx-xxxxx            1/1     Running   0          2m
   payments-api-xxxxxxxxxx-xxxxx       1/1     Running   0          90s
   users-api-xxxxxxxxxx-xxxxx          1/1     Running   0          60s
   users-sqlserver-xxxxxxxxxx-xxxxx    1/1     Running   0          60s
   catalog-api-xxxxxxxxxx-xxxxx        1/1     Running   0          60s
   catalog-sqlserver-xxxxxxxxxx-xxxxx  1/1     Running   0          60s
   ```

   > As imagens (`fcg-users-api:latest`, `fcg-catalog-api:latest` etc.) usam
   > `imagePullPolicy: IfNotPresent` — precisam já estar carregadas no cluster (ex:
   > `minikube image load fcg-users-api:latest`) antes do `apply`, senão o Pod fica em
   > `ImagePullBackOff`.

4. **Acesse o Grafana e o Prometheus** (Item 3 — Observabilidade, ver seção 9):
   - Grafana: `http://<ip-do-cluster>:30030` (login anônimo habilitado, dashboard "FCG" já
     provisionado). No Minikube, descubra o IP com `minikube ip`.
   - Prometheus: `http://<ip-do-cluster>:30090`.

5. **Para derrubar tudo:**

   ```bash
   kubectl delete -f k8s/rabbitmq/
   kubectl delete -f k8s/monitoring/
   kubectl delete -f ../FCG.Payments/k8s/
   kubectl delete -f ../techchallenge_fase2_user/k8s/
   kubectl delete -f ../FCG.Catalog/k8s/
   ```

### Como os serviços se acham dentro do cluster

Dentro do Kubernetes, cada microsserviço enxerga o RabbitMQ pelo **nome do Service**, não por
`localhost`. Por isso o `ConfigMap` de cada microsserviço aponta `RABBITMQ__HOST=rabbitmq` — que
é exatamente o `metadata.name` definido em `k8s/rabbitmq/service.yaml`. O Kubernetes resolve
esse nome automaticamente para o endereço certo do container, de forma parecida com como um
site normal resolve `google.com` para um IP.

---

## 7. Variáveis de ambiente deste repositório

| Variável | Usada por | Descrição | Padrão |
|---|---|---|---|
| `RABBITMQ_USER` | RabbitMQ + os 3 microsserviços | Usuário de acesso ao RabbitMQ | `guest` |
| `RABBITMQ_PASSWORD` | RabbitMQ + os 3 microsserviços | Senha de acesso ao RabbitMQ | `guest` |
| `RABBITMQ_HOST` | Payments, Users, Catalog | Endereço do broker RabbitMQ — local (`rabbitmq`) ou CloudAMQP | `rabbitmq` |
| `RABBITMQ_VIRTUALHOST` | Payments, Users, Catalog | Vhost do RabbitMQ a usar | `/` |
| `RABBITMQ_PORT` | Payments, Users, Catalog | Porta do broker — vazio usa a porta padrão do esquema (5672/5671); defina `5671` para o CloudAMQP | (vazio) |
| `RABBITMQ_USE_SSL` | Payments, Users, Catalog | `true` liga TLS (`rabbitmqs://`, necessário para o CloudAMQP); `false` usa `rabbitmq://` sem TLS (broker local) | `false` |
| `MSSQL_SA_PASSWORD` | SQL Server do CatalogAPI + o próprio CatalogAPI | Senha do usuário `sa` do banco do Catálogo | `Catalog@Strong!Pass1` |
| `USERS_MSSQL_SA_PASSWORD` | SQL Server do UsersAPI + o próprio UsersAPI | Senha do usuário `sa` do banco de Usuários | `Users@Strong!Pass1` |
| `JWT_SECRET_KEY` | UsersAPI (emite) + CatalogAPI (valida) | Chave de assinatura do token JWT — precisa ser **igual** nos dois | `tech-challenge-fase-2-fcg-chave-secreta-jwt-256bits-minimo` (placeholder de dev) |
| `PAYMENTS_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Payments` | `../FCG.Payments` |
| `CATALOG_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Catalog` | `../FCG.Catalog` |
| `USERS_PATH` | `docker-compose.yml` | Caminho local do repositório `techchallenge_fase2_user` | `../techchallenge_fase2_user` |

> As credenciais `guest`/`guest` e as senhas de SQL Server acima são padrão de **ambiente de
> desenvolvimento apenas**. Nunca use essas credenciais em um ambiente real. `JWT_SECRET_KEY`
> em particular está versionada em texto claro no `docker-compose.yml` (como valor padrão) e nos
> `appsettings.json`/`k8s/secret.yaml` de cada serviço — ver "Limitações conhecidas" abaixo.

---

## 9. Fase 3 — Serverless e Observabilidade

### 9.1. Item 2 — Migração para arquitetura Serverless

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

### 9.2. Item 3 — Stack de Observabilidade (Prometheus + Grafana)

CatalogAPI e UsersAPI expõem métricas HTTP (`prometheus-net.AspNetCore`) no endpoint `/metrics`
— latência, contagem de requisições e código de status por controller/action. O Prometheus
(`k8s/monitoring/`) faz *scrape* desses endpoints a cada 5 segundos, e o Grafana lê do
Prometheus como fonte de dados, com um dashboard "FCG" já provisionado automaticamente (sem
precisar importar nada na mão) com 4 painéis: latência p95, RPS total, requisições por código de
status e taxa de erro (5xx).

Essa stack roda inteiramente no Kubernetes local (Minikube), sem depender de nenhuma conta em
nuvem — ver seção 6 para subir (`kubectl apply -f k8s/monitoring/`) e os endereços de acesso
(NodePort 30030 para o Grafana, 30090 para o Prometheus).

---

## 10. Limitações conhecidas (transparência)

- O `NotificationsAPI` (Azure Function) não expõe endpoint HTTP de healthcheck — não se aplica a
  uma função serverless; sua saúde é observada via Application Insights, no próprio Azure.
- A stack de observabilidade (Prometheus/Grafana) cobre CatalogAPI e UsersAPI; PaymentsAPI ainda
  não expõe métricas Prometheus (só o healthcheck HTTP em `/healthz`), e o NotificationsAPI
  (Azure Function) não é coberto por essa stack — métricas dele ficam só no Application Insights.
- Não há retry automático nem fila de mensagens mortas (*dead-letter queue*) configurada no
  RabbitMQ ainda — se uma mensagem falhar na validação, ela é apenas descartada com um log de
  aviso.
- **`JWT_SECRET_KEY` está versionada em texto claro** como valor padrão neste `docker-compose.yml`
  e replicada nos `appsettings.json`/`k8s/secret.yaml` do UsersAPI e do CatalogAPI. Aceitável para
  demonstração/FIAP; num deploy real viria de um secret manager e nunca seria commitada.
- **`Issuer`/`Audience` do JWT usam valores diferentes por ambiente**: aqui no `docker-compose`,
  ambos os serviços usam `FCG.Usuario.Api`/`FCG.Usuario.Client`; rodando via Kubernetes ou
  `dotnet run` direto (appsettings locais de cada repo), o valor é `FCG.Catalog.Api`/
  `FCG.Catalog.Client`. Cada ambiente é internamente consistente (o token de um não vale no
  outro, mas isso já era esperado — são execuções separadas), mas é uma pegadinha de manutenção
  se alguém copiar um valor de um ambiente pro outro sem perceber a diferença.
- O SQL Server do UsersAPI e do CatalogAPI, aqui no `docker-compose`, usa volumes nomeados
  (dados sobrevivem a um `docker-compose down` normal); já nos manifestos Kubernetes de cada
  repositório, o volume é `emptyDir` — os dados são perdidos se o Pod do banco reiniciar. Cada
  ambiente decide isso de forma independente, é decisão de cada repositório.
