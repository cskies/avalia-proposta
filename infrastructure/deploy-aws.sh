#!/bin/bash
# =============================================================================
# deploy-aws.sh — Deploy da aplicação Avalia Proposta na AWS real
#
# OBJETIVO EDUCACIONAL:
#   Este script replica manualmente o que a maioria dos frameworks de IaC
#   (Terraform, CDK, SAM) fazem por baixo dos panos. Entender cada chamada
#   aqui te dá base para depois usar essas ferramentas com propriedade.
#
# O QUE ESTE SCRIPT FAZ (visão geral):
#   1.  Valida pré-requisitos
#   2.  Compila o backend Java
#   3.  Cria Security Group para o banco
#   4.  Cria banco RDS PostgreSQL
#   5.  Aguarda o banco ficar disponível (pode demorar ~5-10min)
#   6.  Inicializa o schema do banco
#   7.  Cria a fila SQS
#   8.  Cria a IAM Role para as Lambdas
#   9.  Cria as 3 funções Lambda
#   10. Configura o trigger SQS → Lambda analyze
#   11. Cria o API Gateway REST + rotas
#   12. Cria o bucket S3 e publica o frontend
#   13. Exibe um resumo com todas as URLs
#
# PRÉ-REQUISITOS:
#   - AWS CLI instalado e configurado (aws configure)
#   - Java 17 + Maven instalados
#   - psql (PostgreSQL client) instalado
#   - Arquivo .env com pelo menos: CLAUDE_API_KEY e DB_PASS
#
# COMO USAR:
#   cd infrastructure/
#   cp .env.example .env        # edite com CLAUDE_API_KEY e DB_PASS
#   chmod +x deploy-aws.sh
#   ./deploy-aws.sh
# =============================================================================

# "set -euo pipefail" configura o shell para ser rigoroso:
#   -e  → para o script se qualquer comando falhar
#   -u  → trata variáveis não definidas como erro
#   -o pipefail → falha em pipes (ex: cmd1 | cmd2 falha se cmd1 falhar)
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÕES GLOBAIS
# Centralizar configurações no topo facilita ajustes sem precisar ler o script
# inteiro. Em projetos reais, parte disso viria de um arquivo de config ou
# de variáveis de ambiente do CI/CD.
# ──────────────────────────────────────────────────────────────────────────────
REGION="us-east-1"           # Região AWS onde tudo será criado
APP_NAME="avalia-proposta"   # Prefixo usado em todos os nomes de recursos
DB_NAME="avaliapropostas"    # Nome do banco de dados PostgreSQL
DB_USER="admin"              # Usuário do banco
STAGE="prod"                 # Nome do stage do API Gateway
JAR_PATH="../backend/target/avalia-proposta.jar"

# Cores para facilitar a leitura do output no terminal
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC} $*"; exit 1; }
step()    { echo -e "\n${CYAN}══════ $* ══════${NC}"; }

# ──────────────────────────────────────────────────────────────────────────────
# CARREGA .env
# O arquivo .env contém segredos (API key, senha do banco) que não devem
# nunca ser commitados no git. O .gitignore deve incluir ".env".
# "set -o allexport" faz com que todas as variáveis definidas sejam
# automaticamente exportadas para o ambiente, sem precisar de "export" explícito.
# ──────────────────────────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
if [ ! -f "$ENV_FILE" ]; then
    error "Arquivo .env não encontrado. Copie .env.example e preencha os valores."
fi
set -o allexport
# shellcheck source=/dev/null
source "$ENV_FILE"
set +o allexport

# ──────────────────────────────────────────────────────────────────────────────
# VALIDAÇÃO DE PRÉ-REQUISITOS
# Antes de criar qualquer recurso AWS (que custa dinheiro), verificamos se
# todas as ferramentas necessárias estão disponíveis. Falhar cedo é melhor
# do que criar recursos pela metade.
# ──────────────────────────────────────────────────────────────────────────────
step "1. Validando pré-requisitos"

command -v aws   > /dev/null 2>&1 || error "AWS CLI não encontrado. Instale em: https://aws.amazon.com/cli/"
command -v java  > /dev/null 2>&1 || error "Java não encontrado. Instale o JDK 17."
command -v mvn   > /dev/null 2>&1 || error "Maven não encontrado. Instale o Maven 3.9+."
command -v psql  > /dev/null 2>&1 || error "psql não encontrado. Instale o PostgreSQL client."

# Verifica se as variáveis obrigatórias do .env foram definidas
[ -z "${CLAUDE_API_KEY:-}" ] && error "CLAUDE_API_KEY não definida no .env"
[ -z "${DB_PASS:-}"        ] && error "DB_PASS não definida no .env"

# Verifica se o AWS CLI tem credenciais configuradas
# "aws sts get-caller-identity" retorna informações sobre o usuário atual.
# Se falhar, as credenciais não estão configuradas.
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) \
    || error "AWS CLI sem credenciais. Execute: aws configure"

info "Conta AWS: $ACCOUNT_ID | Região: $REGION"
info "Pré-requisitos OK."

# ──────────────────────────────────────────────────────────────────────────────
# COMPILAÇÃO DO BACKEND
# O Maven compila o código Java e empacota tudo num único JAR "fat" (também
# chamado de "uber-jar" ou "shaded jar") que inclui todas as dependências.
# Isso é necessário porque o Lambda precisa de um arquivo único e autocontido.
# A flag -DskipTests pula os testes para agilizar o deploy (em CI/CD você
# rodaria os testes em etapa anterior).
# ──────────────────────────────────────────────────────────────────────────────
step "2. Compilando backend Java"

if [ ! -f "$JAR_PATH" ]; then
    info "Compilando... (pode demorar 1-2 min na primeira vez)"
    (cd ../backend && mvn clean package -DskipTests -q) \
        || error "Falha na compilação. Verifique os logs acima."
    info "Build concluído: $JAR_PATH"
else
    info "JAR já existe. Pulando build. (Rode 'mvn clean package -DskipTests' para recompilar)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# SECURITY GROUP PARA O RDS
#
# CONCEITO: Security Group é o "firewall" da AWS. Ele controla qual tráfego
# de rede entra (inbound rules) e sai (outbound rules) de um recurso.
#
# O RDS precisa de um Security Group que permita conexões na porta 5432
# (porta padrão do PostgreSQL). Para este MVP, vamos permitir de qualquer
# IP (0.0.0.0/0). Em produção real, você restringiria ao range de IPs das
# Lambdas ou usaria VPC privada.
#
# Nota: O RDS ficará "publicly accessible" para que as Lambdas (que rodam
# fora de VPC por padrão) consigam conectar. Para produção, o correto seria
# colocar tudo numa VPC privada.
# ──────────────────────────────────────────────────────────────────────────────
step "3. Criando Security Group para o RDS"

# Busca o ID da VPC padrão. Toda conta AWS tem uma VPC padrão em cada região.
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION")
info "VPC padrão: $VPC_ID"

# Verifica se o Security Group já existe (para o script ser idempotente —
# ou seja, seguro de rodar mais de uma vez)
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${APP_NAME}-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${APP_NAME}-rds-sg" \
        --description "Permite acesso ao PostgreSQL do Avalia Proposta" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$REGION")

    # Adiciona regra de entrada: protocolo TCP, porta 5432, de qualquer IP
    # Em produção: substituir "0.0.0.0/0" pelo range de IPs das Lambdas
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 5432 \
        --cidr 0.0.0.0/0 \
        --region "$REGION" > /dev/null
    info "Security Group criado: $SG_ID"
else
    warn "Security Group já existe: $SG_ID"
fi

# ──────────────────────────────────────────────────────────────────────────────
# RDS POSTGRESQL
#
# CONCEITO: RDS (Relational Database Service) é o serviço de banco de dados
# gerenciado da AWS. "Gerenciado" significa que a AWS cuida de backups,
# patches, alta disponibilidade — você só se preocupa com os dados.
#
# Parâmetros importantes:
#   --db-instance-class db.t3.micro  → Menor instância disponível (free tier)
#   --engine postgres                → PostgreSQL
#   --engine-version 15              → Versão do Postgres
#   --allocated-storage 20           → 20 GB de disco (mínimo, e gratuito)
#   --no-multi-az                    → Uma única zona (multi-AZ tem alta
#                                      disponibilidade mas custa o dobro)
#   --publicly-accessible            → Permite conexão de fora da VPC
#   --backup-retention-period 0      → Desativa backups automáticos (economiza
#                                      storage; em produção use 7-30 dias)
# ──────────────────────────────────────────────────────────────────────────────
step "4. Criando RDS PostgreSQL (free tier: db.t3.micro)"

# Verifica se o banco já existe
DB_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "${APP_NAME}-db" \
    --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$DB_STATUS" ] || [ "$DB_STATUS" = "None" ]; then
    info "Criando instância RDS... (isso leva 5-10 minutos, aguarde)"
    aws rds create-db-instance \
        --db-instance-identifier "${APP_NAME}-db" \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --engine-version "15" \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASS" \
        --db-name "$DB_NAME" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --no-multi-az \
        --publicly-accessible \
        --backup-retention-period 0 \
        --vpc-security-group-ids "$SG_ID" \
        --region "$REGION" > /dev/null
    info "RDS criado. Aguardando ficar disponível..."
else
    warn "RDS já existe (status: $DB_STATUS). Aguardando ficar disponível..."
fi

# ──────────────────────────────────────────────────────────────────────────────
# AGUARDA O RDS FICAR DISPONÍVEL
#
# O RDS leva tempo para provisionar (criar o servidor, instalar o Postgres,
# configurar rede, etc.). O comando "aws rds wait" faz polling automático
# até o recurso atingir o estado desejado. O timeout padrão é 30 minutos.
# ──────────────────────────────────────────────────────────────────────────────
step "5. Aguardando RDS ficar disponível"
info "Aguardando... (pode demorar até 10 minutos)"
aws rds wait db-instance-available \
    --db-instance-identifier "${APP_NAME}-db" \
    --region "$REGION"

# Obtém o endpoint do banco (endereço de conexão)
DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "${APP_NAME}-db" \
    --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")

info "RDS disponível! Endpoint: $DB_ENDPOINT"
DB_URL="jdbc:postgresql://${DB_ENDPOINT}:5432/${DB_NAME}"

# ──────────────────────────────────────────────────────────────────────────────
# INICIALIZA O SCHEMA DO BANCO
#
# O psql é o cliente de linha de comando do PostgreSQL. Aqui usamos ele
# para executar o arquivo SQL que cria a tabela "proposals".
#
# A variável PGPASSWORD evita que o psql peça a senha interativamente.
# Em scripts de automação, isso é necessário para não travar a execução.
# ──────────────────────────────────────────────────────────────────────────────
step "6. Inicializando schema do banco"

PGPASSWORD="$DB_PASS" psql \
    -h "$DB_ENDPOINT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -f sql/init.sql \
    -v ON_ERROR_STOP=1 \
    --quiet \
    && info "Schema criado com sucesso." \
    || warn "Schema pode já existir, continuando."

# ──────────────────────────────────────────────────────────────────────────────
# FILA SQS
#
# CONCEITO: SQS (Simple Queue Service) é o serviço de filas da AWS.
# Usamos para desacoplar o recebimento da proposta (síncrono, rápido) da
# análise com IA (assíncrono, demorado). O fluxo é:
#   1. Lambda submit recebe o POST e publica uma mensagem na fila
#   2. Lambda analyze é triggerada pela fila e processa em background
#   3. Frontend faz polling no GET até status = "done"
#
# VisibilityTimeout: por quanto tempo a mensagem fica invisível para outros
# consumidores enquanto está sendo processada. Deve ser maior que o timeout
# da Lambda analyze (120s), então usamos 130s.
# ──────────────────────────────────────────────────────────────────────────────
step "7. Criando fila SQS"

QUEUE_URL=$(aws sqs create-queue \
    --queue-name "${APP_NAME}-queue" \
    --attributes "VisibilityTimeout=130,MessageRetentionPeriod=3600" \
    --query 'QueueUrl' --output text --region "$REGION")

QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text --region "$REGION")

info "SQS criada: $QUEUE_URL"

# ──────────────────────────────────────────────────────────────────────────────
# IAM ROLE PARA AS LAMBDAS
#
# CONCEITO: IAM (Identity and Access Management) controla permissões na AWS.
# Para uma Lambda executar, ela precisa de uma "Role" (papel) com permissões.
#
# Trust Policy: define QUEM pode assumir esse papel. Aqui, apenas o serviço
# "lambda.amazonaws.com" pode assumir essa role.
#
# Policies anexadas:
#   - AWSLambdaBasicExecutionRole: permite escrever logs no CloudWatch
#   - AmazonSQSFullAccess: permite ler/escrever na fila SQS
#   - AmazonRDSFullAccess: não usamos (conexão é via JDBC direto)
#
# Em produção, você criaria uma policy customizada com o mínimo de permissões
# necessário (princípio do menor privilégio).
# ──────────────────────────────────────────────────────────────────────────────
step "8. Criando IAM Role para as Lambdas"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

ROLE_ARN=$(aws iam get-role \
    --role-name "${APP_NAME}-lambda-role" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "")

if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ]; then
    ROLE_ARN=$(aws iam create-role \
        --role-name "${APP_NAME}-lambda-role" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --query 'Role.Arn' --output text)

    # Anexa policies gerenciadas pela AWS (forma mais simples para MVP)
    aws iam attach-role-policy \
        --role-name "${APP_NAME}-lambda-role" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    aws iam attach-role-policy \
        --role-name "${APP_NAME}-lambda-role" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSQSFullAccess"

    # Aguarda a role propagar (IAM tem latência eventual de alguns segundos)
    info "Aguardando propagação da IAM Role..."
    sleep 10
    info "IAM Role criada: $ROLE_ARN"
else
    warn "IAM Role já existe: $ROLE_ARN"
fi

# ──────────────────────────────────────────────────────────────────────────────
# FUNÇÕES LAMBDA
#
# CONCEITO: Lambda é computação "serverless" — você sobe o código e a AWS
# gerencia os servidores. Você paga apenas pelo tempo de execução.
#
# Parâmetros importantes:
#   --runtime java17       → Runtime da linguagem
#   --handler              → Classe Java + método que recebe o evento
#   --zip-file fileb://    → O JAR compilado (fileb:// = arquivo binário)
#   --timeout              → Máximo de segundos que a função pode rodar
#   --memory-size          → RAM em MB (mais RAM = mais CPU também na Lambda)
#   --environment          → Variáveis de ambiente injetadas na função
#
# As variáveis de ambiente substituem o que seria um arquivo .properties ou
# application.yml. São a forma padrão de configurar Lambdas sem hardcodar
# valores no código.
# ──────────────────────────────────────────────────────────────────────────────
step "9. Criando funções Lambda"

# Variáveis de ambiente comuns a todas as Lambdas que acessam o banco
DB_VARS="DB_URL=${DB_URL},DB_USER=${DB_USER},DB_PASS=${DB_PASS}"

# Função auxiliar: cria a Lambda se não existir, ou atualiza se já existir.
# Isso torna o script idempotente (pode rodar várias vezes com segurança).
create_or_update_lambda() {
    local name="$1"      # Nome da função
    local handler="$2"   # Classe::método Java
    local timeout="$3"   # Timeout em segundos
    local extra_env="$4" # Variáveis de ambiente extras

    local env_vars="$DB_VARS"
    [ -n "$extra_env" ] && env_vars="${env_vars},${extra_env}"

    if aws lambda get-function --function-name "$name" --region "$REGION" > /dev/null 2>&1; then
        info "Atualizando Lambda: $name"

        # Atualiza o código (o JAR)
        aws lambda update-function-code \
            --function-name "$name" \
            --zip-file "fileb://$JAR_PATH" \
            --region "$REGION" > /dev/null

        # Aguarda a atualização do código terminar antes de atualizar config
        # (não é possível atualizar as duas coisas simultaneamente)
        aws lambda wait function-updated \
            --function-name "$name" --region "$REGION" 2>/dev/null || true

        # Atualiza as variáveis de ambiente e timeout
        aws lambda update-function-configuration \
            --function-name "$name" \
            --environment "Variables={${env_vars}}" \
            --timeout "$timeout" \
            --region "$REGION" > /dev/null

        aws lambda wait function-updated \
            --function-name "$name" --region "$REGION" 2>/dev/null || true
    else
        info "Criando Lambda: $name"
        aws lambda create-function \
            --function-name "$name" \
            --runtime java17 \
            --role "$ROLE_ARN" \
            --handler "$handler" \
            --zip-file "fileb://$JAR_PATH" \
            --timeout "$timeout" \
            --memory-size 512 \
            --environment "Variables={${env_vars}}" \
            --region "$REGION" > /dev/null

        aws lambda wait function-active \
            --function-name "$name" --region "$REGION" 2>/dev/null || true
    fi
}

# Lambda 1: recebe o POST do API Gateway e coloca na fila
create_or_update_lambda \
    "submit-proposal" \
    "com.avaliapropostas.handler.SubmitHandler::handleRequest" \
    "30" \
    "SQS_QUEUE_URL=${QUEUE_URL}"

# Lambda 2: consumida pela fila SQS, chama a Claude API e salva o resultado
create_or_update_lambda \
    "analyze-proposal" \
    "com.avaliapropostas.handler.AnalyzeHandler::handleRequest" \
    "120" \
    "CLAUDE_API_KEY=${CLAUDE_API_KEY}"

# Lambda 3: consultada pelo frontend no polling (GET /proposals/{id})
create_or_update_lambda \
    "get-proposal" \
    "com.avaliapropostas.handler.GetResultHandler::handleRequest" \
    "30" \
    ""

# ──────────────────────────────────────────────────────────────────────────────
# EVENT SOURCE MAPPING: SQS → Lambda analyze
#
# CONCEITO: O Event Source Mapping é a "cola" entre o SQS e a Lambda.
# Quando chega uma mensagem na fila, a AWS automaticamente invoca a Lambda
# analyze-proposal passando a mensagem como evento.
#
# batch-size 1: processa uma mensagem por vez. Com batch-size maior, a Lambda
# receberia várias mensagens num único evento — útil para processar em bulk.
# Para análise de propostas (que chama a Claude API por mensagem), 1 é o certo.
# ──────────────────────────────────────────────────────────────────────────────
step "10. Configurando trigger SQS → Lambda analyze"

EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
    --function-name analyze-proposal \
    --event-source-arn "$QUEUE_ARN" \
    --query 'EventSourceMappings[0].UUID' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EXISTING_MAPPING" ] || [ "$EXISTING_MAPPING" = "None" ]; then
    aws lambda create-event-source-mapping \
        --function-name analyze-proposal \
        --event-source-arn "$QUEUE_ARN" \
        --batch-size 1 \
        --enabled \
        --region "$REGION" > /dev/null
    info "Trigger SQS → Lambda criado."
else
    warn "Trigger já existe, pulando."
fi

# ──────────────────────────────────────────────────────────────────────────────
# API GATEWAY REST
#
# CONCEITO: API Gateway é o ponto de entrada HTTP da aplicação. Ele recebe
# requisições HTTP do frontend e repassa para as Lambdas certas.
#
# REST API vs HTTP API:
#   - HTTP API (v2): mais novo, mais barato, mais simples — mas Pro no LocalStack
#   - REST API (v1): mais antigo, mais recursos — suportado no LocalStack Community
#   Usamos REST API para compatibilidade com o ambiente de desenvolvimento local.
#
# Fluxo de uma requisição:
#   Browser → API Gateway → integração Lambda → Lambda executa → resposta
#
# Estrutura de recursos criada:
#   /
#   └── proposals          (POST → submit-proposal, OPTIONS → CORS)
#       └── {id}           (GET  → get-proposal)
# ──────────────────────────────────────────────────────────────────────────────
step "11. Criando API Gateway REST"

EXISTING_API=$(aws apigateway get-rest-apis \
    --query "items[?name=='${APP_NAME}-api'].id" \
    --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EXISTING_API" ] || [ "$EXISTING_API" = "None" ]; then

    API_ID=$(aws apigateway create-rest-api \
        --name "${APP_NAME}-api" \
        --description "API do Avalia Proposta" \
        --query 'id' --output text --region "$REGION")
    info "API Gateway criada: $API_ID"

    # Toda REST API começa com um recurso raiz "/" que já existe.
    # Precisamos do ID dele para criar recursos filhos.
    ROOT_ID=$(aws apigateway get-resources \
        --rest-api-id "$API_ID" \
        --query 'items[?path==`/`].id' --output text --region "$REGION")

    # ── Cria o recurso /proposals ─────────────────────────────────────────────
    PROPOSALS_RES=$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$ROOT_ID" \
        --path-part "proposals" \
        --query 'id' --output text --region "$REGION")

    # ── Cria o recurso /proposals/{id} ───────────────────────────────────────
    # "{id}" é um path parameter — o valor real virá no pathParameters do evento
    PROPOSAL_ID_RES=$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$PROPOSALS_RES" \
        --path-part "{id}" \
        --query 'id' --output text --region "$REGION")

    # ── POST /proposals → submit-proposal ────────────────────────────────────
    # put-method: define que o recurso aceita POST sem autenticação
    aws apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method POST --authorization-type NONE \
        --region "$REGION" > /dev/null

    # put-integration: define como o API Gateway se conecta com a Lambda.
    # AWS_PROXY = o API Gateway passa o request inteiro para a Lambda,
    # que é responsável por montar o response completo (incluindo status e headers).
    # integration-http-method sempre é POST para Lambdas, independente do método da rota.
    aws apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method POST --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:submit-proposal/invocations" \
        --region "$REGION" > /dev/null

    # ── OPTIONS /proposals (CORS preflight) ───────────────────────────────────
    # Browsers modernos enviam uma requisição OPTIONS antes de POST/PUT para
    # verificar se o servidor permite a chamada cross-origin (CORS).
    # Respondemos com MOCK (resposta estática, sem invocar Lambda).
    aws apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --authorization-type NONE \
        --region "$REGION" > /dev/null

    aws apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --type MOCK \
        --request-templates '{"application/json":"{\"statusCode\":200}"}' \
        --region "$REGION" > /dev/null

    aws apigateway put-method-response \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --status-code 200 \
        --response-parameters '{
            "method.response.header.Access-Control-Allow-Origin": false,
            "method.response.header.Access-Control-Allow-Methods": false,
            "method.response.header.Access-Control-Allow-Headers": false
        }' \
        --region "$REGION" > /dev/null

    aws apigateway put-integration-response \
        --rest-api-id "$API_ID" --resource-id "$PROPOSALS_RES" \
        --http-method OPTIONS --status-code 200 \
        --response-parameters '{
            "method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'",
            "method.response.header.Access-Control-Allow-Methods": "'"'"'GET,POST,OPTIONS'"'"'",
            "method.response.header.Access-Control-Allow-Headers": "'"'"'Content-Type,Authorization'"'"'"
        }' \
        --region "$REGION" > /dev/null

    # ── GET /proposals/{id} → get-proposal ───────────────────────────────────
    aws apigateway put-method \
        --rest-api-id "$API_ID" --resource-id "$PROPOSAL_ID_RES" \
        --http-method GET --authorization-type NONE \
        --region "$REGION" > /dev/null

    aws apigateway put-integration \
        --rest-api-id "$API_ID" --resource-id "$PROPOSAL_ID_RES" \
        --http-method GET --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:get-proposal/invocations" \
        --region "$REGION" > /dev/null

    # ── Deploy ────────────────────────────────────────────────────────────────
    # As mudanças no API Gateway só ficam ativas após um "deployment".
    # O stage é como um ambiente: prod, staging, dev, etc.
    # A URL final será: https://{API_ID}.execute-api.{REGION}.amazonaws.com/{STAGE}
    aws apigateway create-deployment \
        --rest-api-id "$API_ID" \
        --stage-name "$STAGE" \
        --region "$REGION" > /dev/null

    info "API Gateway criada e deployada (stage: $STAGE)"

else
    API_ID="$EXISTING_API"
    warn "API Gateway já existe: $API_ID. Criando novo deployment..."
    aws apigateway create-deployment \
        --rest-api-id "$API_ID" \
        --stage-name "$STAGE" \
        --region "$REGION" > /dev/null
fi

# ── Permissões: API Gateway pode invocar as Lambdas ──────────────────────────
# Por padrão, o API Gateway não tem permissão de invocar Lambdas.
# Este comando adiciona uma "resource-based policy" na Lambda permitindo
# chamadas originadas do API Gateway específico.
aws lambda add-permission \
    --function-name submit-proposal \
    --statement-id "apigw-submit-${API_ID}" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/proposals" \
    --region "$REGION" > /dev/null 2>&1 || true

aws lambda add-permission \
    --function-name get-proposal \
    --statement-id "apigw-get-${API_ID}" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/GET/proposals/*" \
    --region "$REGION" > /dev/null 2>&1 || true

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"
info "API URL: $API_URL"

# ──────────────────────────────────────────────────────────────────────────────
# S3 — HOSPEDAGEM DO FRONTEND
#
# CONCEITO: S3 (Simple Storage Service) é o serviço de armazenamento de objetos.
# Além de armazenar arquivos, ele pode servir websites estáticos (HTML, CSS, JS)
# diretamente via HTTP — sem precisar de servidor.
#
# Para hospedar um site estático no S3:
#   1. Criar o bucket com nome único global
#   2. Desabilitar o "Block Public Access" (por padrão tudo é privado)
#   3. Adicionar uma bucket policy permitindo leitura pública
#   4. Habilitar o website hosting (define qual arquivo é o index)
#   5. Fazer upload dos arquivos
#
# Nome do bucket deve ser globalmente único na AWS (não só na sua conta).
# Usamos o Account ID como sufixo para garantir unicidade.
# ──────────────────────────────────────────────────────────────────────────────
step "12. Criando bucket S3 para o frontend"

BUCKET_NAME="${APP_NAME}-frontend-${ACCOUNT_ID}"

# Cria o bucket (us-east-1 não aceita --create-bucket-configuration)
if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" > /dev/null 2>&1 || warn "Bucket já existe."
else
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null 2>&1 || warn "Bucket já existe."
fi

# Desabilita o Block Public Access (necessário para site estático público)
aws s3api delete-public-access-block \
    --bucket "$BUCKET_NAME" \
    --region "$REGION"

# Adiciona policy que permite qualquer pessoa (Principal: *) ler (s3:GetObject)
# os objetos do bucket. Isso é necessário para o browser conseguir carregar o HTML.
aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME" \
    --policy "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:GetObject\",
            \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\"
        }]
    }" \
    --region "$REGION"

# Habilita o website hosting: define index.html como página principal
aws s3api put-bucket-website \
    --bucket "$BUCKET_NAME" \
    --website-configuration '{
        "IndexDocument": {"Suffix": "index.html"},
        "ErrorDocument": {"Key": "index.html"}
    }' \
    --region "$REGION"

# Injeta a URL da API no placeholder do frontend e faz upload
sed "s|__API_URL_PLACEHOLDER__|${API_URL}|g" ../frontend/index.html \
    > /tmp/index-aws.html

aws s3 cp /tmp/index-aws.html "s3://${BUCKET_NAME}/index.html" \
    --content-type "text/html" \
    --region "$REGION" > /dev/null

FRONTEND_URL="http://${BUCKET_NAME}.s3-website-${REGION}.amazonaws.com"
info "Frontend publicado: $FRONTEND_URL"

# ──────────────────────────────────────────────────────────────────────────────
# RESUMO FINAL
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Avalia Proposta — Deploy na AWS concluído!           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Frontend${NC}        : $FRONTEND_URL"
echo -e "  ${CYAN}API Base URL${NC}    : $API_URL"
echo -e "  ${CYAN}POST proposta${NC}   : $API_URL/proposals"
echo -e "  ${CYAN}GET resultado${NC}   : $API_URL/proposals/{id}"
echo ""
echo -e "  ${CYAN}RDS Endpoint${NC}    : $DB_ENDPOINT"
echo -e "  ${CYAN}SQS Queue${NC}       : $QUEUE_URL"
echo ""
echo -e "  ${YELLOW}Para destruir todos os recursos e evitar cobranças:${NC}"
echo -e "  ${YELLOW}  ./destroy-aws.sh${NC}"
echo ""
