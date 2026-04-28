ENDPOINT  := http://localhost:4566
REGION    := us-east-1
FRONTEND  := ../frontend/index.html

.PHONY: help up down build init update logs clean status test-api

help: ## Mostra esta ajuda
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

up: ## Sobe LocalStack + PostgreSQL em background
	docker compose up -d
	@echo "Aguardando serviços..."
	@until curl -sf $(ENDPOINT)/_localstack/health | grep -q '"sqs"'; do sleep 2; done
	@until docker exec postgres pg_isready -U admin -q 2>/dev/null; do sleep 2; done
	@echo "Todos os serviços prontos!"

down: ## Para e remove os containers (mantém volumes)
	docker compose down

down-clean: ## Para containers e APAGA todos os volumes (reset completo)
	docker compose down -v

build: ## Compila o backend Java (gera avalia-proposta.jar)
	cd ../backend && mvn clean package -DskipTests -q
	@echo "JAR gerado: backend/target/avalia-proposta.jar"

init: up build ## Sobe infra + compila + cria todos os recursos AWS
	./init.sh

update: build ## Recompila e redeploya as Lambdas (sem recriar a infra)
	./update-lambda.sh

logs: ## Acompanha logs dos containers em tempo real
	docker compose logs -f

logs-localstack: ## Apenas logs do LocalStack
	docker compose logs -f localstack

status: ## Status dos serviços LocalStack
	@curl -sf $(ENDPOINT)/_localstack/health | python3 -m json.tool

list-lambdas: ## Lista funções Lambda criadas
	@AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	    aws --endpoint-url=$(ENDPOINT) --region=$(REGION) \
	    lambda list-functions --query 'Functions[].{Nome:FunctionName,Status:State}' --output table

list-queues: ## Lista filas SQS criadas
	@AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	    aws --endpoint-url=$(ENDPOINT) --region=$(REGION) \
	    sqs list-queues

test-api: ## Testa submissão de proposta (defina API_ID=xxx antes)
	@test -n "$(API_ID)" || (echo "Uso: make test-api API_ID=<id>" && exit 1)
	@curl -sf -X POST "$(ENDPOINT)/$(API_ID)/proposals" \
	    -H "Content-Type: application/json" \
	    -d '{"text":"Proposta: licença de software por R$50.000/ano com suporte incluído."}' \
	    | python3 -m json.tool

clean: down ## Para containers e remove o JAR compilado
	rm -f ../backend/target/avalia-proposta.jar
