package com.avaliapropostas.model;

import java.sql.Timestamp;

/**
 * Representa uma proposta comercial submetida para análise.
 */
public class Proposal {

    private String id;
    private String rawText;
    private String result;    // JSON retornado pela Claude API, armazenado como JSONB
    private String status;    // pending | processing | done | error
    private Timestamp createdAt;
    private Timestamp updatedAt;

    public String getId()                  { return id; }
    public void   setId(String id)         { this.id = id; }

    public String getRawText()             { return rawText; }
    public void   setRawText(String t)     { this.rawText = t; }

    public String getResult()              { return result; }
    public void   setResult(String r)      { this.result = r; }

    public String getStatus()              { return status; }
    public void   setStatus(String s)      { this.status = s; }

    public Timestamp getCreatedAt()        { return createdAt; }
    public void      setCreatedAt(Timestamp t) { this.createdAt = t; }

    public Timestamp getUpdatedAt()        { return updatedAt; }
    public void      setUpdatedAt(Timestamp t) { this.updatedAt = t; }
}
