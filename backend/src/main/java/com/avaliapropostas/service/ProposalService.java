package com.avaliapropostas.service;

import com.avaliapropostas.model.Proposal;

import java.sql.*;

/**
 * Acesso ao PostgreSQL para operações de persistência de propostas.
 *
 * Reutiliza a conexão entre invocações quentes da Lambda (static field),
 * reconectando automaticamente quando a conexão for encerrada pelo banco.
 */
public class ProposalService {

    private static final String DB_URL  = System.getenv("DB_URL");
    private static final String DB_USER = System.getenv("DB_USER");
    private static final String DB_PASS = System.getenv("DB_PASS");

    // Conexão estática reutilizada entre invocações quentes
    private static Connection cachedConn;

    private static synchronized Connection getConnection() throws SQLException {
        if (cachedConn == null || cachedConn.isClosed()) {
            cachedConn = DriverManager.getConnection(DB_URL, DB_USER, DB_PASS);
        }
        return cachedConn;
    }

    /** Insere nova proposta com status 'pending' e retorna o UUID gerado. */
    public String save(String rawText) throws SQLException {
        String sql = "INSERT INTO proposals (raw_text, status) VALUES (?, 'pending') RETURNING id";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, rawText);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) return rs.getString("id");
                throw new SQLException("Nenhuma linha retornada ao inserir proposta.");
            }
        }
    }

    /** Atualiza apenas o campo status. */
    public void updateStatus(String id, String status) throws SQLException {
        String sql = "UPDATE proposals SET status = ?, updated_at = NOW() WHERE id = ?::uuid";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, status);
            stmt.setString(2, id);
            stmt.executeUpdate();
        }
    }

    /** Persiste o resultado JSON da análise e marca status como 'done'. */
    public void saveResult(String id, String resultJson) throws SQLException {
        String sql = "UPDATE proposals SET result = ?::jsonb, status = 'done', updated_at = NOW() WHERE id = ?::uuid";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, resultJson);
            stmt.setString(2, id);
            stmt.executeUpdate();
        }
    }

    /** Registra uma mensagem de erro e marca status como 'error'. */
    public void saveError(String id, String errorMsg) throws SQLException {
        // Escapa aspas para não quebrar o JSON inline
        String safe = errorMsg == null ? "erro desconhecido" : errorMsg.replace("\"", "'");
        String errorJson = "{\"erro\":\"" + safe + "\"}";
        String sql = "UPDATE proposals SET result = ?::jsonb, status = 'error', updated_at = NOW() WHERE id = ?::uuid";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, errorJson);
            stmt.setString(2, id);
            stmt.executeUpdate();
        }
    }

    /** Retorna a proposta completa pelo ID, ou null se não encontrada. */
    public Proposal findById(String id) throws SQLException {
        String sql = "SELECT id, raw_text, result::text, status, created_at, updated_at " +
                     "FROM proposals WHERE id = ?::uuid";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, id);
            try (ResultSet rs = stmt.executeQuery()) {
                if (!rs.next()) return null;
                Proposal p = new Proposal();
                p.setId(rs.getString("id"));
                p.setRawText(rs.getString("raw_text"));
                p.setResult(rs.getString("result"));
                p.setStatus(rs.getString("status"));
                p.setCreatedAt(rs.getTimestamp("created_at"));
                p.setUpdatedAt(rs.getTimestamp("updated_at"));
                return p;
            }
        }
    }

    /** Retorna apenas o texto cru (evita trazer o JSONB desnecessariamente). */
    public String getRawText(String id) throws SQLException {
        String sql = "SELECT raw_text FROM proposals WHERE id = ?::uuid";
        try (PreparedStatement stmt = getConnection().prepareStatement(sql)) {
            stmt.setString(1, id);
            try (ResultSet rs = stmt.executeQuery()) {
                return rs.next() ? rs.getString("raw_text") : null;
            }
        }
    }
}
