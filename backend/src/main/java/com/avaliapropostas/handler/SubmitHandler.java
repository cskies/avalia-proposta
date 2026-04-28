package com.avaliapropostas.handler;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.avaliapropostas.service.ProposalService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.SendMessageRequest;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Recebe POST /proposals do API Gateway, persiste a proposta e publica na fila SQS.
 * Retorna 202 com o UUID gerado para que o frontend faça polling.
 */
public class SubmitHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private final ProposalService proposalService;
    private final SqsClient sqsClient;
    private final ObjectMapper mapper;
    private final String sqsQueueUrl;

    public SubmitHandler() {
        this.proposalService = new ProposalService();
        this.mapper = new ObjectMapper();
        this.sqsQueueUrl = System.getenv("SQS_QUEUE_URL");

        // Credenciais explícitas para funcionar tanto no LocalStack quanto na AWS real
        String accessKey = System.getenv().getOrDefault("AWS_ACCESS_KEY_ID", "test");
        String secretKey = System.getenv().getOrDefault("AWS_SECRET_ACCESS_KEY", "test");
        String region    = System.getenv().getOrDefault("AWS_DEFAULT_REGION", "us-east-1");

        var builder = SqsClient.builder()
                .region(Region.of(region))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(accessKey, secretKey)))
                .httpClientBuilder(UrlConnectionHttpClient.builder());

        // SQS_ENDPOINT só é definido no LocalStack; na AWS real usa o endpoint padrão
        String sqsEndpoint = System.getenv("SQS_ENDPOINT");
        if (sqsEndpoint != null && !sqsEndpoint.isBlank()) {
            builder.endpointOverride(URI.create(sqsEndpoint));
        }

        this.sqsClient = builder.build();
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context ctx) {
        ctx.getLogger().log("SubmitHandler acionado");

        try {
            String body = event.getBody();
            if (body == null || body.isBlank()) {
                return errorResponse(400, "O body da requisição está vazio.");
            }

            JsonNode json = mapper.readTree(body);
            if (!json.has("text") || json.get("text").asText().isBlank()) {
                return errorResponse(400, "O campo 'text' é obrigatório.");
            }

            String text = json.get("text").asText();

            // Persiste com status 'pending'
            String proposalId = proposalService.save(text);
            ctx.getLogger().log("Proposta salva — ID: " + proposalId);

            // Publica na fila para processamento assíncrono
            String msgBody = mapper.writeValueAsString(Map.of("proposalId", proposalId));
            sqsClient.sendMessage(SendMessageRequest.builder()
                    .queueUrl(sqsQueueUrl)
                    .messageBody(msgBody)
                    .build());
            ctx.getLogger().log("Mensagem enviada para SQS — proposalId: " + proposalId);

            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", proposalId);
            resp.put("status", "pending");
            resp.put("message", "Proposta recebida. Análise em andamento.");

            return okResponse(202, mapper.writeValueAsString(resp));

        } catch (Exception e) {
            ctx.getLogger().log("Erro no SubmitHandler: " + e.getMessage());
            return errorResponse(500, "Erro interno: " + e.getMessage());
        }
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    private APIGatewayV2HTTPResponse okResponse(int status, String body) {
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(status)
                .withBody(body)
                .withHeaders(corsHeaders())
                .build();
    }

    private APIGatewayV2HTTPResponse errorResponse(int status, String msg) {
        try {
            String body = mapper.writeValueAsString(Map.of("error", msg));
            return APIGatewayV2HTTPResponse.builder()
                    .withStatusCode(status)
                    .withBody(body)
                    .withHeaders(corsHeaders())
                    .build();
        } catch (Exception e) {
            return APIGatewayV2HTTPResponse.builder()
                    .withStatusCode(500)
                    .withBody("{\"error\":\"Erro desconhecido\"}")
                    .withHeaders(corsHeaders())
                    .build();
        }
    }

    private Map<String, String> corsHeaders() {
        return Map.of(
            "Content-Type",                 "application/json",
            "Access-Control-Allow-Origin",  "*",
            "Access-Control-Allow-Methods", "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers", "Content-Type, Authorization"
        );
    }
}
