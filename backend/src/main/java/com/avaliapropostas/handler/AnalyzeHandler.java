package com.avaliapropostas.handler;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.avaliapropostas.service.ClaudeService;
import com.avaliapropostas.service.ProposalService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * Consumidor SQS: lê mensagens da fila, chama a Claude API e persiste o resultado.
 *
 * Fluxo por mensagem:
 *   1. Extrai proposalId do body JSON
 *   2. Marca status como 'processing' no banco
 *   3. Busca o raw_text
 *   4. Chama ClaudeService.analyze()
 *   5. Salva resultado e marca 'done' (ou 'error' em falha)
 */
public class AnalyzeHandler implements RequestHandler<SQSEvent, Void> {

    private final ProposalService proposalService;
    private final ClaudeService   claudeService;
    private final ObjectMapper    mapper;

    public AnalyzeHandler() {
        this.proposalService = new ProposalService();
        this.claudeService   = new ClaudeService();
        this.mapper          = new ObjectMapper();
    }

    @Override
    public Void handleRequest(SQSEvent event, Context ctx) {
        for (SQSEvent.SQSMessage message : event.getRecords()) {
            processMessage(message, ctx);
        }
        return null;
    }

    private void processMessage(SQSEvent.SQSMessage message, Context ctx) {
        String proposalId = null;

        try {
            JsonNode json = mapper.readTree(message.getBody());
            proposalId = json.path("proposalId").asText(null);

            if (proposalId == null || proposalId.isBlank()) {
                ctx.getLogger().log("Mensagem SQS sem proposalId, ignorando.");
                return;
            }

            ctx.getLogger().log("Iniciando análise — proposalId: " + proposalId);
            proposalService.updateStatus(proposalId, "processing");

            String rawText = proposalService.getRawText(proposalId);
            if (rawText == null) {
                throw new RuntimeException("Proposta não encontrada no banco: " + proposalId);
            }

            String analysisJson = claudeService.analyze(rawText);
            ctx.getLogger().log("Análise concluída — proposalId: " + proposalId);

            proposalService.saveResult(proposalId, analysisJson);

        } catch (Exception e) {
            ctx.getLogger().log("Erro ao processar proposalId=" + proposalId + ": " + e.getMessage());

            if (proposalId != null) {
                try {
                    proposalService.saveError(proposalId, e.getMessage());
                } catch (Exception dbErr) {
                    ctx.getLogger().log("Falha ao registrar erro no banco: " + dbErr.getMessage());
                }
            }

            // Não relança a exceção: a mensagem não volta para a fila,
            // evitando reprocessamento infinito de erros de validação.
        }
    }
}
