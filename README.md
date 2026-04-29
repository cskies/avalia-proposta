# Avalia Proposta

Analisador de propostas comerciais com IA. Cole uma proposta → receba resumo,
pontos positivos/negativos, avaliação de preço, riscos, argumentos de negociação
e um veredito final (aceitar / negociar / recusar).

## Arquitetura

```
Frontend (local) ──POST──▶ API Gateway REST ──▶ Lambda submit-proposal
                                                       │
                                                    SQS fila
                                                       │
                                                 Lambda analyze-proposal
                                                       │
                                             Claude API ──▶ PostgreSQL
                                                       │
Frontend ──polling GET──▶ API Gateway REST ──▶ Lambda get-proposal ──▶ PostgreSQL
```

## Estrutura de pastas

```
avalia-proposta/
├── infrastructure/
│   ├── docker-compose.yml     # LocalStack + PostgreSQL
│   ├── init.sh                # Cria todos os recursos AWS locais
│   ├── update-lambda.sh       # Recompila e redeploya as Lambdas
│   ├── Makefile               # Atalhos de desenvolvimento
│   ├── .env.example           # Variáveis de ambiente necessárias
│   └── sql/
│       └── init.sql           # Schema da tabela proposals
├── backend/
│   ├── pom.xml
│   └── src/main/java/com/avaliapropostas/
│       ├── handler/
│       │   ├── SubmitHandler.java      # POST /proposals
│       │   ├── AnalyzeHandler.java     # Consumidor SQS
│       │   └── GetResultHandler.java   # GET /proposals/{id}
│       ├── service/
│       │   ├── ClaudeService.java      # Chamada à Claude API
│       │   └── ProposalService.java    # Acesso ao PostgreSQL
│       └── model/
│           └── Proposal.java
└── frontend/
    ├── index.html             # Fonte (contém __API_URL_PLACEHOLDER__)
    └── index-local.html       # Gerado pelo init.sh com a URL real injetada
```

## Pré-requisitos

| Ferramenta       | Versão mínima | Para quê                              |
|------------------|---------------|---------------------------------------|
| Docker           | 24+           | Rodar LocalStack e PostgreSQL          |
| Docker Compose   | v2            | Orquestrar os containers              |
| Java JDK         | 17            | Compilar o backend                    |
| Maven            | 3.9+          | Build do projeto Java                 |
| AWS CLI          | v2            | Criar recursos no LocalStack          |
| Claude API key   | —             | Motor de análise (console.anthropic.com) |

### Instalando o AWS CLI (se necessário)

```bash
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip
./aws/install --install-dir ~/.local/aws-cli --bin-dir ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"   # adicione ao seu ~/.bashrc ou ~/.zshrc
```

## Configuração inicial

```bash
# 1. Clone / acesse o projeto
cd avalia-proposta/infrastructure

# 2. Copie o arquivo de variáveis de ambiente
cp .env.example .env

# 3. Edite .env e defina sua chave Claude
#    CLAUDE_API_KEY=sk-ant-...
```

## Como rodar localmente

```bash
export PATH="$HOME/.local/bin:$PATH"   # garante que o AWS CLI está no PATH
cd infrastructure
make init
```

O `init.sh` lê automaticamente o `.env` do mesmo diretório — não é necessário exportar a chave manualmente.

Ao final, o script exibe:

```
╔══════════════════════════════════════════════════════════════╗
║            Avalia Proposta — Inicialização OK!               ║
╚══════════════════════════════════════════════════════════════╝

  API Gateway URL : http://localhost:4566/restapis/<API_ID>/local/_user_request_
  POST proposta   : http://localhost:4566/restapis/<API_ID>/local/_user_request_/proposals
  GET resultado   : http://localhost:4566/restapis/<API_ID>/local/_user_request_/proposals/{id}
```

### Abrir o frontend

O `init.sh` gera automaticamente `frontend/index-local.html` com a URL da API já injetada.
Abra esse arquivo diretamente no navegador — **não abra `index.html`**, que ainda contém o placeholder.

```bash
# Linux
xdg-open ../frontend/index-local.html

# macOS
open ../frontend/index-local.html
```

## Como testar via curl

```bash
API_URL="http://localhost:4566/restapis/<API_ID>/local/_user_request_"

# Submete uma proposta
curl -s -X POST "$API_URL/proposals" \
  -H "Content-Type: application/json" \
  -d '{"text": "Proposta: licença anual de 50 usuários por R$ 60.000/ano com suporte 8x5."}' | jq

# Resposta: {"id": "uuid-gerado", "status": "pending", ...}

# Consulta o resultado (repita até status == "done")
curl -s "$API_URL/proposals/<uuid>" | jq
```

## Ciclo de desenvolvimento

```bash
# Após alterar código Java, redeploya sem recriar infra:
make update

# Acompanhar logs em tempo real:
make logs

# Ver status dos serviços LocalStack:
make status

# Parar tudo:
make down
```

## Schema do banco

```sql
CREATE TABLE proposals (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_text   TEXT        NOT NULL,
    result     JSONB,
    status     VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP   NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

Status possíveis: `pending` → `processing` → `done` | `error`

## Exemplo de resposta da análise

```json
{
  "resumo": "Proposta de custo elevado para o segmento, mas com diferenciais em suporte.",
  "pontos_positivos": ["Suporte técnico incluído", "Onboarding com treinamento"],
  "pontos_atencao": ["Preço acima da média de mercado", "Contrato anual sem cláusula de saída"],
  "avaliacao_preco": {
    "avaliacao": "caro",
    "justificativa": "Concorrentes similares operam 30% abaixo."
  },
  "riscos": ["Lock-in de fornecedor", "SLA sem penalidade definida"],
  "como_negociar": [
    "Solicitar desconto de 20% para contrato bienal",
    "Exigir cláusula de SLA com penalidade financeira",
    "Pedir período de avaliação gratuita de 30 dias"
  ],
  "veredito": "negociar"
}
```

## Deploy na AWS real

### 1. Pré-requisitos AWS

```bash
# Configure suas credenciais AWS
aws configure

# Crie um banco RDS PostgreSQL (ou use Aurora Serverless v2)
# Anote o endpoint, por exemplo: mydb.abc123.us-east-1.rds.amazonaws.com
```

### 2. Crie os recursos

```bash
# Crie a fila SQS
aws sqs create-queue --queue-name proposals-queue --region us-east-1

# Crie o bucket S3 para o frontend
aws s3 mb s3://avalia-proposta-frontend --region us-east-1

# Compile o JAR
cd backend && mvn clean package -DskipTests

# Crie as funções Lambda (ajuste o ARN da role)
aws lambda create-function \
  --function-name submit-proposal \
  --runtime java17 \
  --role arn:aws:iam::<ACCOUNT>:role/lambda-execution-role \
  --handler com.avaliapropostas.handler.SubmitHandler::handleRequest \
  --zip-file fileb://target/avalia-proposta.jar \
  --timeout 30 --memory-size 512 \
  --environment "Variables={
    DB_URL=jdbc:postgresql://<RDS_ENDPOINT>:5432/avaliapropostas,
    DB_USER=admin,DB_PASS=<senha>,
    SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/<ACCOUNT>/proposals-queue
  }"

# Repita para analyze-proposal (adicione CLAUDE_API_KEY) e get-proposal
```

### 3. Configure o API Gateway no console AWS

Na AWS real você pode usar **HTTP API (v2)** que é mais simples e barato:

- Crie uma HTTP API
- Adicione rotas: `POST /proposals` → Lambda submit e `GET /proposals/{id}` → Lambda get
- Habilite CORS

> **Nota:** localmente usamos REST API (v1) por compatibilidade com o LocalStack Community Edition.
> Na AWS real, HTTP API (v2) é recomendado.

### 4. Deploy do frontend

```bash
# Atualize API_BASE_URL em index.html com a URL do API Gateway
aws s3 cp frontend/index.html s3://avalia-proposta-frontend/ \
  --content-type text/html

# Habilite site estático no bucket e configure CloudFront (opcional)
```

### Dica: Armazene segredos no AWS Secrets Manager

Para produção, evite variáveis de ambiente com senhas e use o AWS Secrets Manager
para `CLAUDE_API_KEY`, `DB_USER` e `DB_PASS`.

## Variáveis de ambiente das Lambdas

| Variável             | Obrigatória   | Descrição                                               |
|----------------------|---------------|---------------------------------------------------------|
| `CLAUDE_API_KEY`     | ✅ (analyze)  | Chave da API Claude (Anthropic)                         |
| `DB_URL`             | ✅            | JDBC URL do PostgreSQL                                  |
| `DB_USER`            | ✅            | Usuário do banco                                        |
| `DB_PASS`            | ✅            | Senha do banco                                          |
| `SQS_QUEUE_URL`      | ✅ (submit)   | URL completa da fila SQS                                |
| `SQS_ENDPOINT`       | LocalStack    | Override do endpoint SQS (ex: `http://localstack:4566`) |
| `AWS_DEFAULT_REGION` | —             | Região AWS (padrão: `us-east-1`)                        |

## Troubleshooting

**Frontend mostra "API não configurada"**
- Você está abrindo `index.html` (que tem o placeholder). Abra `frontend/index-local.html`

**`aws: command not found` ao rodar `make init`**
- Instale o AWS CLI (veja seção Pré-requisitos) e garanta que está no PATH:
  `export PATH="$HOME/.local/bin:$PATH"`

**Lambda não conecta ao PostgreSQL no LocalStack**
- Verifique se `LAMBDA_DOCKER_NETWORK=avalia-net` está definido no docker-compose
- O container Lambda precisa estar na mesma rede do container `postgres`

**`CLAUDE_API_KEY` indefinida**
- Defina no arquivo `infrastructure/.env`: `CLAUDE_API_KEY=sk-ant-...`
- O `init.sh` carrega o `.env` automaticamente

**API Gateway retorna 404**
- O API ID muda se você recriar a infra. Copie a URL exibida no final do `init.sh`
- Verifique com: `make status` e `make list-lambdas`

**Análise lenta no primeiro request**
- Java Lambda tem cold start de 3–8s. Invocações subsequentes são rápidas
