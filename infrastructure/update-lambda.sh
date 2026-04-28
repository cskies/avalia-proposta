#!/bin/bash
# update-lambda.sh — Recompila e redeploya todas as funções Lambda
# Útil durante o desenvolvimento para aplicar mudanças rapidamente

set -euo pipefail

ENDPOINT="http://localhost:4566"
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

aws_local() { aws --endpoint-url="$ENDPOINT" "$@"; }

echo "→ Compilando backend..."
(cd ../backend && mvn clean package -DskipTests -q)
echo "✓ Build concluído."

for FUNC in submit-proposal analyze-proposal get-proposal; do
    echo "→ Atualizando Lambda: $FUNC..."
    aws_local lambda update-function-code \
        --function-name "$FUNC" \
        --zip-file fileb://../backend/target/avalia-proposta.jar \
        --output text --query 'FunctionName' > /dev/null
    echo "✓ $FUNC atualizada."
done

echo ""
echo "Todas as Lambdas atualizadas com sucesso!"
