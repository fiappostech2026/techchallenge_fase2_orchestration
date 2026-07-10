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
| **UsersAPI** | Cadastro e login de usuários | do time parceiro |
| **CatalogAPI** | Catálogo de jogos e início da compra | do time parceiro |
| **PaymentsAPI** | Processa (simula) o pagamento de uma compra | `FCG.Payments` |
| **NotificationsAPI** | "Envia" (simula, escrevendo no console) e-mails de boas-vindas e confirmação de compra | `FCG.Notifications` |

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
subir** (RabbitMQ, PaymentsAPI, NotificationsAPI) e **como eles se conectam entre si**.

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
│   └── rabbitmq/            # manifestos do RabbitMQ (broker compartilhado, não
│       ├── deployment.yaml  # pertence a nenhum microsserviço específico, por isso
│       ├── service.yaml     # mora aqui e não dentro de FCG.Payments/FCG.Notifications)
│       └── secret.yaml
└── README.md                # este arquivo
```

Os manifestos k8s de **cada microsserviço** (Deployment, Service, ConfigMap, Secret do
PaymentsAPI e do NotificationsAPI) continuam morando dentro do próprio repositório de cada um,
em uma pasta `/k8s` — isso é exigido pelo enunciado do desafio, para manter cada microsserviço
dono do seu próprio deploy. Este repositório só centraliza o que é **compartilhado** (o
RabbitMQ) e o que **liga tudo** (o docker-compose).

### Convenção de pastas esperada

Para o `docker-compose.yml` conseguir montar (`build`) a imagem de cada microsserviço, ele
precisa achar o código-fonte deles no seu computador. A convenção adotada é: **clone todos os
repositórios do projeto dentro da mesma pasta pai**, um do lado do outro:

```
minha-pasta-do-projeto/
├── FCG.Orchestration/   ← você está aqui
├── FCG.Payments/
├── FCG.Notifications/
├── users-api/            (repositório do time responsável por Usuários)
└── catalog-api/          (repositório do time responsável por Catálogo)
```

Se você clonou em nomes de pasta diferentes, não precisa renomear nada — só ajuste os caminhos
no seu arquivo `.env` (veja passo 2 abaixo).

> **Nota:** os microsserviços `users-api` e `catalog-api` são de responsabilidade do time
> parceiro. Enquanto o Dockerfile deles não estiver pronto, o `docker-compose.yml` sobe apenas
> RabbitMQ + PaymentsAPI + NotificationsAPI (os blocos dos outros dois já estão escritos no
> arquivo, comentados, prontos para ativar assim que o código deles chegar).

---

## 5. Como rodar na sua máquina (Docker Compose)

### Pré-requisitos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado e aberto.
- Ter clonado este repositório e os repositórios `FCG.Payments` e `FCG.Notifications` na mesma
  pasta pai (ver seção 4).

### Passo a passo

1. **Copie o arquivo de configuração:**

   ```bash
   cp .env.example .env
   ```

   (Os valores padrão já funcionam para rodar localmente, não precisa editar nada de início.)

2. **Suba tudo com um comando**, de dentro desta pasta:

   ```bash
   docker-compose up --build
   ```

   Isso vai:
   - baixar e iniciar o RabbitMQ (o "correio" entre os serviços);
   - construir a imagem do PaymentsAPI e do NotificationsAPI a partir do código-fonte deles;
   - iniciar os dois microsserviços já conectados ao RabbitMQ.

3. **Verifique se está no ar:**
   - Painel do RabbitMQ: [http://localhost:15672](http://localhost:15672) (usuário/senha:
     `guest` / `guest`). Nele dá para ver as filas e mensagens passando em tempo real.
   - Healthcheck do PaymentsAPI: [http://localhost:5010/healthz](http://localhost:5010/healthz)
     (deve responder `Healthy`).

4. **Para derrubar tudo:**

   ```bash
   docker-compose down
   ```

### Erros comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| `context path does not exist` | O caminho no `.env` não bate com onde você clonou o repositório | Ajuste `PAYMENTS_PATH` / `NOTIFICATIONS_PATH` no seu `.env` |
| PaymentsAPI/NotificationsAPI reiniciando em loop | RabbitMQ ainda não terminou de subir | Espere alguns segundos — o `depends_on` já aguarda o RabbitMQ ficar saudável, mas a primeira subida pode demorar um pouco |
| Porta já em uso (`port is already allocated`) | Outro programa já está usando a porta 5672, 15672, 5010 ou 5011 | Feche o outro programa ou troque a porta no `docker-compose.yml` |

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

1. **Suba o RabbitMQ primeiro** (os microsserviços dependem dele para iniciar sem erro):

   ```bash
   kubectl apply -f k8s/rabbitmq/
   ```

2. **Suba cada microsserviço**, a partir da pasta `k8s/` dentro do repositório de cada um:

   ```bash
   kubectl apply -f ../FCG.Payments/k8s/
   kubectl apply -f ../FCG.Notifications/k8s/
   ```

3. **Confira se todos os Pods estão rodando:**

   ```bash
   kubectl get pods
   ```

   Você deve ver algo como:

   ```
   NAME                                 READY   STATUS    RESTARTS   AGE
   rabbitmq-xxxxxxxxxx-xxxxx           1/1     Running   0          1m
   payments-api-xxxxxxxxxx-xxxxx       1/1     Running   0          45s
   notifications-api-xxxxxxxxxx-xxxxx  1/1     Running   0          45s
   ```

4. **Para derrubar tudo:**

   ```bash
   kubectl delete -f k8s/rabbitmq/
   kubectl delete -f ../FCG.Payments/k8s/
   kubectl delete -f ../FCG.Notifications/k8s/
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
| `RABBITMQ_USER` | RabbitMQ + os dois microsserviços | Usuário de acesso ao RabbitMQ | `guest` |
| `RABBITMQ_PASSWORD` | RabbitMQ + os dois microsserviços | Senha de acesso ao RabbitMQ | `guest` |
| `PAYMENTS_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Payments` | `../FCG.Payments` |
| `NOTIFICATIONS_PATH` | `docker-compose.yml` | Caminho local do repositório `FCG.Notifications` | `../FCG.Notifications` |

> As credenciais `guest`/`guest` são padrão de **ambiente de desenvolvimento apenas**. Nunca
> use essas credenciais em um ambiente real.

---

## 8. Limitações conhecidas (transparência)

- Os blocos de `users-api` e `catalog-api` no `docker-compose.yml` estão comentados porque os
  Dockerfiles desses serviços (time parceiro) ainda não foram integrados a este repositório.
- O `NotificationsAPI` ainda não expõe um endpoint de healthcheck HTTP (o `PaymentsAPI` expõe em
  `/healthz`, o `NotificationsAPI` não tem `AddHealthChecks()`/`MapHealthChecks()` configurado
  no código atual) — por isso não há checagem de saúde HTTP para ele no compose.
- Não há retry automático nem fila de mensagens mortas (*dead-letter queue*) configurada no
  RabbitMQ ainda — se uma mensagem falhar na validação, ela é apenas descartada com um log de
  aviso.
