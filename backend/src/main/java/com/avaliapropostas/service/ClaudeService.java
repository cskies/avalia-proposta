package com.avaliapropostas.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Envia o texto da proposta para a Claude API e retorna a análise em JSON.
 *
 * Usa java.net.http.HttpClient (Java 11+) para evitar dependências extras.
 * O HttpClient é estático para reuso entre invocações quentes da Lambda.
 */
public class ClaudeService {

    private static final String API_URL = "https://api.anthropic.com/v1/messages";
    private static final String MODEL   = "claude-sonnet-4-6";

    private static final HttpClient HTTP_CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private final String apiKey;
    private final ObjectMapper mapper;

    public ClaudeService() {
        this.apiKey = System.getenv("CLAUDE_API_KEY");
        this.mapper = new ObjectMapper();
    }

    /**
     * Analisa a proposta e retorna a string JSON com os campos definidos no prompt.
     * Lança RuntimeException em caso de erro de comunicação ou resposta inválida.
     */
    public String analyze(String proposalText) throws Exception {
        String prompt = buildPrompt(proposalText);
        String requestBody = buildRequestBody(prompt);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(API_URL))
                .header("x-api-key", apiKey)
                .header("anthropic-version", "2023-06-01")
                .header("content-type", "application/json")
                .timeout(Duration.ofSeconds(90))
                .POST(HttpRequest.BodyPublishers.ofString(requestBody))
                .build();

        HttpResponse<String> response = HTTP_CLIENT.send(request,
                HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() != 200) {
            throw new RuntimeException(
                "Claude API retornou erro HTTP " + response.statusCode() +
                ": " + response.body()
            );
        }

        return extractJsonFromResponse(response.body());
    }

    private String buildPrompt(String texto) {
        return "Você é um especialista em negociações comerciais B2B.\n" +
               "Analise a proposta abaixo e retorne em JSON com as chaves:\n" +
               "resumo, pontos_positivos (array), pontos_atencao (array),\n" +
               "avaliacao_preco (caro/justo/barato + justificativa),\n" +
               "riscos (array), como_negociar (array com 3 argumentos),\n" +
               "veredito (aceitar/negociar/recusar).\n" +
               "Proposta: " + texto;
    }

    private String buildRequestBody(String prompt) throws Exception {
        ObjectNode body = mapper.createObjectNode();
        body.put("model", MODEL);
        body.put("max_tokens", 2048);

        ArrayNode messages = mapper.createArrayNode();
        ObjectNode userMsg = mapper.createObjectNode();
        userMsg.put("role", "user");
        userMsg.put("content", prompt);
        messages.add(userMsg);

        body.set("messages", messages);
        return mapper.writeValueAsString(body);
    }

    /** Extrai o texto do campo content[0].text e limpa blocos de código Markdown se presentes. */
    private String extractJsonFromResponse(String responseBody) throws Exception {
        JsonNode root = mapper.readTree(responseBody);
        JsonNode content = root.path("content");

        if (!content.isArray() || content.isEmpty()) {
            throw new RuntimeException("Resposta da Claude sem campo 'content': " + responseBody);
        }

        String text = content.get(0).path("text").asText("").trim();

        // Remove wrapper ```json ... ``` quando o modelo formata a resposta assim
        if (text.startsWith("```json")) text = text.substring(7);
        else if (text.startsWith("```"))   text = text.substring(3);
        if (text.endsWith("```"))          text = text.substring(0, text.length() - 3);

        text = text.trim();

        // Valida que é JSON válido antes de retornar
        mapper.readTree(text);

        return text;
    }
}
