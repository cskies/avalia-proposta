# Avalia Proposta

Analisador de propostas comerciais com IA. Cole uma proposta → receba resumo,
pontos positivos/negativos, avaliação de preço, riscos, argumentos de negociação
e um veredito final (aceitar / negociar / recusar).

## Arquitetura

```
Frontend (S3/local) ──POST──▶ API Gateway ──▶ Lambda submit-proposal
                                                    │
                                                 SQS fila
                                                    │
                                              Lambda analyze-proposal
                                                    │
                                          Claude API ──▶ PostgreSQL
                                                    │
Frontend ──polling GET──▶ API Gateway ──▶ Lambda get-proposal ──▶ PostgreSQL
```

## Estrutura de pastas

```
avalia-proposta/
├── infrastructure/
│   ├── docker-compose.yml   # LocalStack + PostgreSQL
│   ├── init.sh              # Cria todos os recursos AWS locais
│   ├── update-lambda.sh     # Recompila e redeploya as Lambdas
│   ├── Makefile             # Atalhos de desenvolvimento
│   ├── .env.example         # Variáveis de ambiente necessárias
│   └── sql/
│       └── init.sql         # Schema da tabela proposals
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
    └── index.html           # SPA completa sem dependências externas
```

## Pré-requisitos

| Ferramenta       | Versão mínima | Para quê                              |
|------------------|---------------|---------------------------------------|
| Docker           | 24+           | Rodar LocalStack e PostgreSQL          |
| Docker Compose   | v2            | Orquestrar os containers              |
| Java JDK         | 17            | Compilar e rodar o backend             |
| Maven            | 3.9+          | Build do projeto Java                 |
| AWS CLI          | v2            | Criar recursos no LocalStack          |
| Claude API key   | —             | Motor de análise (console.anthropic.com) |

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
cd infrastructure

# Sobe LocalStack + PostgreSQL, compila Java e inicializa todos os recursos AWS
export CLAUDE_API_KEY=sk-ant-...
make init
```

Ao final, o script exibe:

```
╔══════════════════════════════════════════════════════════════╗
║            Avalia Proposta — Inicialização OK!               ║
╚══════════════════════════════════════════════════════════════╝

  API Gateway URL : http://localhost:4566/abc123def456
  POST proposta   : http://localhost:4566/abc123def456/proposals
  GET resultado   : http://localhost:4566/abc123def456/proposals/{id}
```

### Atualizar a URL no frontend

Edite `frontend/index.html` e altere a linha:

```javascript
const API_BASE_URL = 'http://localhost:4566/abc123def456';
```

Em seguida abra o arquivo `frontend/index.html` direto no navegador.

## Como testar via curl

```bash
# Submete uma proposta
curl -X POST http://localhost:4566/<API_ID>/proposals \
  -H "Content-Type: application/json" \
  -d '{"text": "Proposta: licença anual de 50 usuários por R$ 60.000/ano com suporte 8x5."}' | jq

# Resposta: {"id": "uuid-gerado", "status": "pending", ...}

# Consulta o resultado (repita até status == "done")
curl http://localhost:4566/<API_ID>/proposals/<uuid> | jq
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

### 2. Crie os recursos manualmente ou via CloudFormation

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

### 3. Configure o API Gateway HTTP no console AWS

- Crie uma HTTP API
- Adicione rotas: `POST /proposals` → Lambda submit e `GET /proposals/{id}` → Lambda get
- Habilite CORS

### 4. Deploy do frontend

```bash
# Atualize API_BASE_URL no index.html com a URL do API Gateway
aws s3 cp frontend/index.html s3://avalia-proposta-frontend/ \
  --content-type text/html

# Habilite site estático no bucket e configure CloudFront (opcional)
```

### Dica: Armazene segredos no AWS Secrets Manager

Para produção, evite variáveis de ambiente com senhas e use o AWS Secrets Manager
para `CLAUDE_API_KEY`, `DB_USER` e `DB_PASS`.

## Variáveis de ambiente das Lambdas

| Variável          | Obrigatória | Descrição                                            |
|-------------------|-------------|------------------------------------------------------|
| `CLAUDE_API_KEY`  | ✅ (analyze) | Chave da API Claude (Anthropic)                     |
| `DB_URL`          | ✅           | JDBC URL do PostgreSQL                               |
| `DB_USER`         | ✅           | Usuário do banco                                     |
| `DB_PASS`         | ✅           | Senha do banco                                       |
| `SQS_QUEUE_URL`   | ✅ (submit)  | URL completa da fila SQS                             |
| `SQS_ENDPOINT`    | LocalStack  | Override do endpoint SQS (ex: `http://localstack:4566`) |
| `AWS_DEFAULT_REGION` | —        | Região AWS (padrão: `us-east-1`)                    |

## Troubleshooting

**Lambda não conecta ao PostgreSQL no LocalStack**
- Verifique se `LAMBDA_DOCKER_NETWORK=avalia-net` está definido no docker-compose
- O container Lambda precisa estar na mesma rede do container `postgres`

**`CLAUDE_API_KEY` indefinida**
- Exporte antes de rodar: `export CLAUDE_API_KEY=sk-ant-...`
- Ou edite o `init.sh` passando o valor diretamente

**API Gateway retorna 404**
- O API ID muda a cada `init.sh`. Copie a URL exibida no final do script
- Verifique: `make status` e `make list-lambdas`

**Analisando lento no primeiro request**
- Java Lambda tem cold start de 3-8s. Invocações subsequentes são rápidas
