package com.avaliapropostas.handler;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.avaliapropostas.model.Proposal;
import com.avaliapropostas.service.ProposalService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.util.Map;

/**
 * Recebe GET /proposals/{id} do API Gateway e retorna o estado atual da análise.
 * O frontend faz polling neste endpoint até status == 'done' ou 'error'.
 */
public class GetResultHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private final ProposalService proposalService;
    private final ObjectMapper    mapper;

    public GetResultHandler() {
        this.proposalService = new ProposalService();
        this.mapper          = new ObjectMapper();
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context ctx) {
        try {
            Map<String, String> pathParams = event.getPathParameters();
            if (pathParams == null || !pathParams.containsKey("id")) {
                return errorResponse(400, "Parâmetro 'id' é obrigatório na URL.");
            }

            String proposalId = pathParams.get("id");
            ctx.getLogger().log("Buscando proposta — ID: " + proposalId);

            Proposal proposal = proposalService.findById(proposalId);
            if (proposal == null) {
                return errorResponse(404, "Proposta não encontrada.");
            }

            ObjectNode resp = mapper.createObjectNode();
            resp.put("id",         proposal.getId());
            resp.put("status",     proposal.getStatus());
            resp.put("created_at", proposal.getCreatedAt() != null ? proposal.getCreatedAt().toString() : null);
            resp.put("updated_at", proposal.getUpdatedAt() != null ? proposal.getUpdatedAt().toString() : null);

            // Inclui o result como objeto JSON (não como string escapada)
            if (proposal.getResult() != null) {
                resp.set("result", mapper.readTree(proposal.getResult()));
            }

            return okResponse(200, mapper.writeValueAsString(resp));

        } catch (Exception e) {
            ctx.getLogger().log("Erro no GetResultHandler: " + e.getMessage());
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
