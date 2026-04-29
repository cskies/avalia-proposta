#!/bin/bash
# =============================================================================
# init.sh — Inicializa todos os recursos AWS locais no LocalStack
# Executar a partir do diretório infrastructure/ após `docker-compose up -d`
# =============================================================================

set -euo pipefail

# ──────────────────────── Configurações ───────────────────────────────────────
ENDPOINT="http://localhost:4566"
REGION="us-east-1"
ACCOUNT_ID="000000000000"
QUEUE_NAME="proposals-queue"
JAR_PATH="../backend/target/avalia-proposta.jar"

# Carrega variáveis do .env se existir
if [ -f "$(dirname "$0")/.env" ]; then
    set -o allexport
    # shellcheck source=/dev/null
    source "$(dirname "$0")/.env"
    set +o allexport
fi

# Credenciais dummy para LocalStack (qualquer valor funciona)
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=$REGION

# Atalho para aws cli apontado ao LocalStack
aws_local() { aws --endpoint-url="$ENDPOINT" "$@"; }

# Cores para output
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC} $*"; exit 1; }

# ──────────────────────── 1. Aguardar LocalStack ──────────────────────────────
info "Aguardando LocalStack ficar disponível..."
MAX_WAIT=120
WAITED=0
until curl -sf "$ENDPOINT/_localstack/health" | grep -q '"sqs"'; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        error "LocalStack não ficou pronto em ${MAX_WAIT}s. Verifique: docker-compose logs localstack"
    fi
    sleep 3
    WAITED=$((WAITED + 3))
done
info "LocalStack pronto."

# ──────────────────────── 2. Aguardar PostgreSQL ──────────────────────────────
info "Aguardando PostgreSQL ficar disponível..."
WAITED=0
until docker exec postgres pg_isready -U admin -d avaliapropostas -q 2>/dev/null; do
    if [ $WAITED -ge 60 ]; then
        error "PostgreSQL não ficou pronto em 60s."
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
info "PostgreSQL pronto."

# ──────────────────────── 3. Compilar backend ─────────────────────────────────
if [ ! -f "$JAR_PATH" ]; then
    info "JAR não encontrado. Compilando backend..."
    (cd ../backend && mvn clean package -DskipTests -q) \
        || error "Falha na compilação. Verifique os logs do Maven."
    info "Build concluído."
else
    info "JAR já existe: $JAR_PATH"
fi

# ──────────────────────── 4. IAM Role (dummy para LocalStack) ─────────────────
info "Criando IAM role para as Lambdas..."
aws_local iam create-role \
    --role-name lambda-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --output text --query 'Role.RoleName' > /dev/null 2>&1 || warn "Role já existe, continuando."

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/lambda-role"

# ──────────────────────── 5. Fila SQS ────────────────────────────────────────
info "Criando fila SQS: $QUEUE_NAME..."
QUEUE_URL=$(aws_local sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes '{"VisibilityTimeout":"120","MessageRetentionPeriod":"3600"}' \
    --query 'QueueUrl' --output text)

QUEUE_ARN=$(aws_local sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)

# URL interna usada pelos containers Lambda (usa nome do serviço, não localhost)
QUEUE_URL_INTERNAL="${QUEUE_URL/localhost/localstack}"

info "SQS criada: $QUEUE_URL"
info "ARN:        $QUEUE_ARN"

# ──────────────────────── 6. Bucket S3 para frontend ─────────────────────────
info "Criando bucket S3 para o frontend..."
aws_local s3 mb s3://avalia-proposta-frontend --region "$REGION" 2>/dev/null || warn "Bucket já existe."
aws_local s3 website s3://avalia-proposta-frontend \
    --index-document index.html \
    --error-document index.html 2>/dev/null || true

# ──────────────────────── 7. Variáveis de ambiente comuns das Lambdas ─────────
DB_VARS="DB_URL=jdbc:postgresql://postgres:5432/avaliapropostas,DB_USER=admin,DB_PASS=admin123"
AWS_VARS="AWS_ACCESS_KEY_ID=test,AWS_SECRET_ACCESS_KEY=test,AWS_DEFAULT_REGION=${REGION}"

create_or_update_lambda() {
    local name="$1"
    local handler="$2"
    local timeout="$3"
    local extra_env="$4"

    local env_vars="${DB_VARS},${AWS_VARS}"
    [ -n "$extra_env" ] && env_vars="${env_vars},${extra_env}"

    if aws_local lambda get-function --function-name "$name" > /dev/null 2>&1; then
        info "Atualizando Lambda: $name..."
        aws_local lambda update-function-code \
            --function-name "$name" \
            --zip-file "fileb://$JAR_PATH" --output text --query 'FunctionName' > /dev/null
        aws_local lambda wait function-updated --function-name "$name" 2>/dev/null || true
        aws_local lambda update-function-configuration \
            --function-name "$name" \
            --environment "Variables={${env_vars}}" \
            --timeout "$timeout" \
            --output text --query 'FunctionName' > /dev/null
        aws_local lambda wait function-updated --function-name "$name" 2>/dev/null || true
    else
        info "Criando Lambda: $name..."
        aws_local lambda create-function \
            --function-name "$name" \
            --runtime java17 \
            --role "$ROLE_ARN" \
            --handler "$handler" \
            --zip-file "fileb://$JAR_PATH" \
            --timeout "$timeout" \
            --memory-size 512 \
            --environment "Variables={${env_vars}}" \
            --output text --query 'FunctionName' > /dev/null
    fi
}

# ──────────────────────── 8. Criar funções Lambda ────────────────────────────

# 8a. submit-proposal: recebe POST do API Gateway e publica na SQS
create_or_update_lambda \
    "submit-proposal" \
    "com.avaliapropostas.handler.SubmitHandler::handleRequest" \
    "30" \
    "SQS_ENDPOINT=http://localstack:4566,SQS_QUEUE_URL=${QUEUE_URL_INTERNAL}"

# 8b. analyze-proposal: consumidor SQS → Claude API → PostgreSQL
CLAUDE_KEY="${CLAUDE_API_KEY:-CHANGE_ME}"
create_or_update_lambda \
    "analyze-proposal" \
    "com.avaliapropostas.handler.AnalyzeHandler::handleRequest" \
    "120" \
    "CLAUDE_API_KEY=${CLAUDE_KEY}"

# 8c. get-proposal: retorna resultado pelo ID (GET /proposals/{id})
create_or_update_lambda \
    "get-proposal" \
    "com.avaliapropostas.handler.GetResultHandler::handleRequest" \
    "30" \
    ""

# ──────────────────────── 9. Event Source Mapping: SQS → Lambda ───────────────
info "Configurando event source mapping SQS → analyze-proposal..."
if ! aws_local lambda list-event-source-mappings \
        --function-name analyze-proposal \
        --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null | grep -qv "None"; then
    aws_local lambda create-event-source-mapping \
        --function-name analyze-proposal \
        --event-source-arn "$QUEUE_ARN" \
        --batch-size 1 \
        --enabled \
        --output text --query 'UUID' > /dev/null
    info "Event source mapping criado."
else
    warn "Event source mapping já existe."
fi

# ──────────────────────── 10. API Gateway REST (v1) ──────────────────────────
info "Criando API Gateway REST..."

# Verifica se já existe
EXISTING_API=$(aws_local apigateway get-rest-apis \
    --query "items[?name=='avalia-proposta-api'].id" --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_API" ] && [ "$EXISTING_API" != "None" ]; then
    API_ID="$EXISTING_API"
    warn "API Gateway já existe: $API_ID"
else
    API_ID=$(aws_local apigateway create-rest-api \
        --name "avalia-proposta-api" \
        --query 'id' --output text)
    info "API Gateway criada: $API_ID"

    # Recurso raiz
    ROOT_ID=$(aws_local apigateway get-resources \
        --rest-api-id "$API_ID" \
        --query 'items[?path==`/`].id' --output text)

    # /proposals
    PROPOSALS_RES=$(aws_local apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$ROOT_ID" \
        --path-part "proposals" \
        --query 'id' --output text)

    # /proposals/{id}
    PROPOSAL_ID_RES=$(aws_local apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$PROPOSALS_RES" \
        --path-part "{id}" \
        --query 'id' --output text)

    # POST /proposals → submit-proposal
    aws_local apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method POST --authorization-type NONE > /dev/null

    aws_local apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method POST --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:submit-proposal/invocations" > /dev/null

    # OPTIONS /proposals (CORS preflight)
    aws_local apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --authorization-type NONE > /dev/null

    aws_local apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --type MOCK \
        --request-templates '{"application/json":"{\"statusCode\":200}"}' > /dev/null

    aws_local apigateway put-method-response \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Origin":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Headers":false}' > /dev/null

    aws_local apigateway put-integration-response \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Origin":"'"'"'*'"'"'","method.response.header.Access-Control-Allow-Methods":"'"'"'GET,POST,OPTIONS'"'"'","method.response.header.Access-Control-Allow-Headers":"'"'"'Content-Type,Authorization'"'"'"}' > /dev/null

    # GET /proposals/{id} → get-proposal
    aws_local apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSAL_ID_RES" \
        --http-method GET --authorization-type NONE > /dev/null

    aws_local apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSAL_ID_RES" \
        --http-method GET --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:get-proposal/invocations" > /dev/null

    # Deploy → stage "local"
    aws_local apigateway create-deployment \
        --rest-api-id "$API_ID" \
        --stage-name "local" > /dev/null

    info "API Gateway deployada (stage: local)"
fi

# Permissão para API Gateway invocar as Lambdas
aws_local lambda add-permission \
    --function-name submit-proposal \
    --statement-id apigw-submit \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/proposals" \
    --output text --query 'Statement' > /dev/null 2>&1 || true

aws_local lambda add-permission \
    --function-name get-proposal \
    --statement-id apigw-get \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/GET/proposals/*" \
    --output text --query 'Statement' > /dev/null 2>&1 || true

# ──────────────────────── 11. Deploy do frontend no S3 ───────────────────────
API_URL="http://localhost:4566/restapis/${API_ID}/local/_user_request_"

info "Atualizando API_URL no frontend..."
sed "s|__API_URL_PLACEHOLDER__|${API_URL}|g" ../frontend/index.html \
    > /tmp/index-local.html

# Salva também como arquivo local para abrir direto no navegador
cp /tmp/index-local.html ../frontend/index-local.html
info "Frontend salvo em: frontend/index-local.html"

# Upload S3 (opcional, pode falhar no LocalStack Community)
aws_local s3api put-object \
    --bucket avalia-proposta-frontend \
    --key index.html \
    --body /tmp/index-local.html \
    --content-type "text/html" > /dev/null 2>&1 && info "Frontend publicado no S3." || warn "Upload S3 ignorado (use frontend/index-local.html)."

# ──────────────────────── 12. Resumo final ───────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Avalia Proposta — Inicialização OK!               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  API Gateway URL : $API_URL"
echo "  POST proposta   : $API_URL/proposals"
echo "  GET resultado   : $API_URL/proposals/{id}"
echo ""
echo "  Frontend S3     : http://localhost:4566/avalia-proposta-frontend/index.html"
echo "  Frontend local  : Abra frontend/index.html no navegador"
echo ""
echo "  Configure API_URL no frontend:"
echo "    const API_BASE_URL = '${API_URL}';"
echo ""
if [ "$CLAUDE_KEY" = "CHANGE_ME" ]; then
    echo -e "  ${RED}⚠ ATENÇÃO: CLAUDE_API_KEY não está definida!${NC}"
    echo "  Defina: export CLAUDE_API_KEY=sk-ant-... e rode ./init.sh novamente"
fi
echo ""
