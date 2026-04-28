-- Schema do banco de dados Avalia Proposta
-- Executado automaticamente pelo PostgreSQL na inicialização do container

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS proposals (
    id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_text   TEXT         NOT NULL,
    result     JSONB,
    status     VARCHAR(20)  NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','processing','done','error')),
    created_at TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_proposals_status     ON proposals(status);
CREATE INDEX IF NOT EXISTS idx_proposals_created_at ON proposals(created_at DESC);
