# Deploy na AWS — Guia Manual Passo a Passo

Este guia reproduz exatamente o que o script `deploy-aws.sh` faz, mas via console AWS.
Use para aprender como cada recurso funciona antes de depender de automação.

---

## Pré-requisitos

- Conta AWS ativa
- `CLAUDE_API_KEY` em mãos
- JAR compilado: `cd backend && mvn clean package -DskipTests`

---

## Passo 1 — Criar o banco de dados (RDS PostgreSQL)

**Por que existe:** o RDS é o banco de dados gerenciado da AWS. "Gerenciado" significa que a AWS cuida de backups, patches e disponibilidade — você só cuida dos dados.

### 1a. Criar um Security Group para o banco

O Security Group é o firewall do recurso. Precisa liberar a porta 5432 (PostgreSQL) para que as Lambdas consigam conectar.

1. Acesse **EC2 → Security Groups → Create Security Group**
2. Preencha:
   - **Name:** `avalia-proposta-rds-sg`
   - **Description:** `Permite acesso PostgreSQL`
   - **VPC:** selecione a VPC padrão (default)
3. Em **Inbound rules → Add rule:**
   - **Type:** PostgreSQL
   - **Port:** 5432
   - **Source:** `0.0.0.0/0` *(para MVP; em produção restringir)*
4. Clique em **Create security group**

### 1b. Criar a instância RDS

1. Acesse **RDS → Create database**
2. Escolha:
   - **Engine:** PostgreSQL
   - **Version:** 15.x
   - **Template:** Free tier
3. Em **Settings:**
   - **DB instance identifier:** `avalia-proposta-db`
   - **Master username:** `admin`
   - **Master password:** escolha uma senha segura (anote — você vai precisar)
4. Em **Instance configuration:**
   - **DB instance class:** `db.t3.micro` *(free tier)*
5. Em **Storage:**
   - **Allocated storage:** 20 GB
   - **Storage autoscaling:** desabilitar
6. Em **Connectivity:**
   - **Public access:** **Yes** *(necessário para as Lambdas fora de VPC)*
   - **VPC security group:** selecione o `avalia-proposta-rds-sg` criado acima
7. Em **Additional configuration:**
   - **Initial database name:** `avaliapropostas`
   - **Automated backups:** desabilitar *(economia de storage)*
8. Clique em **Create database**

> Aguarde ~5-10 minutos até o status mudar para **Available**.

### 1c. Anotar o endpoint do banco

No painel do RDS → sua instância → aba **Connectivity & Security**:
- Copie o **Endpoint** (algo como `avalia-proposta-db.xxxx.us-east-1.rds.amazonaws.com`)

### 1d. Criar o schema da tabela

Com o `psql` instalado na sua máquina:

```bash
PGPASSWORD=<sua-senha> psql \
  -h <endpoint-do-rds> \
  -U admin \
  -d avaliapropostas \
  -f infrastructure/sql/init.sql
```

---

## Passo 2 — Criar a fila SQS

**Por que existe:** a fila desacopla o recebimento da proposta (rápido, síncrono) da análise com IA (demorado, assíncrono). O frontend não precisa esperar a IA terminar — ele faz polling.

1. Acesse **SQS → Create queue**
2. Preencha:
   - **Type:** Standard
   - **Name:** `avalia-proposta-queue`
3. Em **Configuration:**
   - **Visibility timeout:** 130 segundos *(deve ser maior que o timeout da Lambda analyze, que é 120s)*
   - **Message retention period:** 1 hora
4. Clique em **Create queue**
5. Anote o **ARN** e a **URL** da fila (visíveis na página da fila criada)

---

## Passo 3 — Criar a IAM Role para as Lambdas

**Por que existe:** toda Lambda precisa de uma "Role" (papel) que define o que ela tem permissão de fazer na AWS. Sem permissão explícita, a Lambda não consegue nem escrever logs.

1. Acesse **IAM → Roles → Create role**
2. Em **Trusted entity type:** selecione **AWS service**
3. Em **Use case:** selecione **Lambda** → clique em **Next**
4. Em **Add permissions**, busque e selecione:
   - `AWSLambdaBasicExecutionRole` *(permite escrever logs no CloudWatch)*
   - `AmazonSQSFullAccess` *(permite ler/publicar na fila SQS)*
5. Clique em **Next**
6. **Role name:** `avalia-proposta-lambda-role`
7. Clique em **Create role**
8. Anote o **ARN** da role (visível na página da role criada)

---

## Passo 4 — Criar as funções Lambda

**Por que existem 3 Lambdas:** cada uma tem uma responsabilidade única.
- `submit-proposal`: recebe o POST, salva no banco, publica na fila
- `analyze-proposal`: consumida pela fila, chama a Claude API, salva o resultado
- `get-proposal`: retorna o estado atual de uma proposta pelo ID

Repita os passos abaixo para cada uma das 3 funções:

### Criar cada Lambda

1. Acesse **Lambda → Create function**
2. Selecione **Author from scratch**
3. Preencha:
   - **Function name:** *(veja tabela abaixo)*
   - **Runtime:** Java 17
   - **Architecture:** x86_64
4. Em **Permissions:**
   - Selecione **Use an existing role**
   - Escolha `avalia-proposta-lambda-role`
5. Clique em **Create function**

### Upload do JAR

Na página da função criada:
1. Clique em **Upload from → .zip or .jar file**
2. Selecione o arquivo `backend/target/avalia-proposta.jar`
3. Clique em **Save**

### Configurar o handler

Em **Runtime settings → Edit:**

| Função | Handler |
|---|---|
| `submit-proposal` | `com.avaliapropostas.handler.SubmitHandler::handleRequest` |
| `analyze-proposal` | `com.avaliapropostas.handler.AnalyzeHandler::handleRequest` |
| `get-proposal` | `com.avaliapropostas.handler.GetResultHandler::handleRequest` |

### Configurar timeout e memória

Em **Configuration → General configuration → Edit:**

| Função | Timeout | Memória |
|---|---|---|
| `submit-proposal` | 30 s | 512 MB |
| `analyze-proposal` | 120 s | 512 MB |
| `get-proposal` | 30 s | 512 MB |

### Configurar variáveis de ambiente

Em **Configuration → Environment variables → Edit**, adicione as variáveis abaixo para cada função:

**Variáveis comuns (todas as 3 funções):**
| Chave | Valor |
|---|---|
| `DB_URL` | `jdbc:postgresql://<endpoint-rds>:5432/avaliapropostas` |
| `DB_USER` | `admin` |
| `DB_PASS` | `<sua-senha>` |

**Variáveis específicas:**

`submit-proposal`:
| Chave | Valor |
|---|---|
| `SQS_QUEUE_URL` | URL da fila SQS criada no Passo 2 |

`analyze-proposal`:
| Chave | Valor |
|---|---|
| `CLAUDE_API_KEY` | `sk-ant-...` |

---

## Passo 5 — Configurar o trigger SQS → Lambda analyze

**Por que existe:** o Event Source Mapping é a ligação entre a fila SQS e a Lambda. Quando chega uma mensagem na fila, a AWS automaticamente invoca a `analyze-proposal`.

1. Na página da Lambda `analyze-proposal`
2. Clique em **Add trigger**
3. Selecione **SQS**
4. Em **SQS queue:** selecione `avalia-proposta-queue`
5. **Batch size:** 1 *(processa uma proposta por vez)*
6. Clique em **Add**

---

## Passo 6 — Criar o API Gateway

**Por que existe:** o API Gateway é a porta de entrada HTTP da aplicação. Ele recebe as requisições do frontend e as repassa para as Lambdas corretas.

### 6a. Criar a API

1. Acesse **API Gateway → Create API**
2. Selecione **REST API** → clique em **Build**
3. Selecione **New API**
4. **API name:** `avalia-proposta-api`
5. **API endpoint type:** Regional
6. Clique em **Create API**

### 6b. Criar o recurso /proposals

1. No painel da API, clique em **Create resource**
2. **Resource path:** `/proposals`
3. **CORS:** habilitar *(isso cria automaticamente o método OPTIONS)*
4. Clique em **Create resource**

### 6c. Criar método POST /proposals

Com o recurso `/proposals` selecionado:

1. Clique em **Create method**
2. **Method type:** POST
3. **Integration type:** Lambda function
4. **Lambda proxy integration:** ativar *(AWS_PROXY — a Lambda monta o response completo)*
5. **Lambda function:** `submit-proposal`
6. Clique em **Create method**

### 6d. Criar o recurso /proposals/{id}

1. Com `/proposals` selecionado, clique em **Create resource**
2. **Resource name:** `{id}` *(as chaves indicam que é um path parameter)*
3. Clique em **Create resource**

### 6e. Criar método GET /proposals/{id}

1. Com `/proposals/{id}` selecionado, clique em **Create method**
2. **Method type:** GET
3. **Integration type:** Lambda function
4. **Lambda proxy integration:** ativar
5. **Lambda function:** `get-proposal`
6. Clique em **Create method**

### 6f. Deploy da API

1. Clique em **Deploy API**
2. **Stage:** New stage → name: `prod`
3. Clique em **Deploy**
4. Anote a **Invoke URL** exibida (formato: `https://xxxxx.execute-api.us-east-1.amazonaws.com/prod`)

---

## Passo 7 — Publicar o frontend no S3

**Por que S3:** o `index.html` é um arquivo estático (sem servidor). O S3 consegue servi-lo diretamente via HTTP, sem precisar de EC2 ou qualquer servidor.

### 7a. Criar o bucket

1. Acesse **S3 → Create bucket**
2. **Bucket name:** `avalia-proposta-frontend-<seu-account-id>` *(nome deve ser único globalmente)*
3. **Region:** us-east-1
4. Em **Block Public Access settings:** **desmarque** "Block all public access"
5. Confirme o aviso e clique em **Create bucket**

### 7b. Adicionar política de leitura pública

1. Na página do bucket → aba **Permissions → Bucket policy**
2. Clique em **Edit** e cole:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::avalia-proposta-frontend-<seu-account-id>/*"
  }]
}
```

3. Clique em **Save changes**

### 7c. Habilitar website estático

1. Na aba **Properties → Static website hosting**
2. Clique em **Edit**
3. Ative **Enable**
4. **Index document:** `index.html`
5. **Error document:** `index.html`
6. Clique em **Save changes**

### 7d. Atualizar a URL da API no frontend e fazer upload

No terminal:
```bash
# Substitui o placeholder pela URL real da API
sed "s|__API_URL_PLACEHOLDER__|https://xxxxx.execute-api.us-east-1.amazonaws.com/prod|g" \
    frontend/index.html > /tmp/index-aws.html

# Faz upload para o S3
aws s3 cp /tmp/index-aws.html s3://avalia-proposta-frontend-<seu-account-id>/index.html \
    --content-type "text/html"
```

A URL do frontend será exibida em:
**S3 bucket → Properties → Static website hosting → Bucket website endpoint**

---

## Testando

```bash
API_URL="https://xxxxx.execute-api.us-east-1.amazonaws.com/prod"

# Envia uma proposta
curl -X POST "$API_URL/proposals" \
  -H "Content-Type: application/json" \
  -d '{"text": "Proposta: licença de 50 usuários por R$60.000/ano com suporte 8x5."}' | jq

# Consulta o resultado (repita até status = "done")
curl "$API_URL/proposals/<uuid-retornado>" | jq
```

---

## Destruindo os recursos (evitar cobranças)

Quando não precisar mais, delete os recursos para não ser cobrado:

1. **RDS:** RDS → sua instância → Delete *(desmarque "Create final snapshot")*
2. **Lambda:** Lambda → cada função → Delete
3. **API Gateway:** API Gateway → sua API → Delete
4. **SQS:** SQS → sua fila → Delete
5. **S3:** S3 → esvaziar bucket → deletar bucket
6. **Security Group:** EC2 → Security Groups → Delete
7. **IAM Role:** IAM → Roles → Delete

Ou use o script `infrastructure/destroy-aws.sh` quando ele existir.

---

## Conceitos-chave aprendidos neste deploy

| Conceito | O que é | Onde usamos |
|---|---|---|
| **IAM Role** | Permissões de um recurso AWS | Lambdas precisam de role para acessar SQS e CloudWatch |
| **Security Group** | Firewall de rede | RDS precisa liberar porta 5432 |
| **RDS** | Banco gerenciado | Armazena as propostas e resultados |
| **SQS** | Fila de mensagens | Desacopla submit da análise |
| **Lambda** | Função serverless | Processa cada etapa do fluxo |
| **Event Source Mapping** | Trigger automático SQS→Lambda | Liga a fila à função analyze |
| **API Gateway** | Ponto de entrada HTTP | Roteia requisições para as Lambdas certas |
| **AWS_PROXY** | Modo de integração | Lambda recebe o request completo e monta o response |
| **S3 Website** | Hospedagem estática | Serve o index.html sem servidor |
