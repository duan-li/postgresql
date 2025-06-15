-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create a sample vector table
CREATE TABLE IF NOT EXISTS document_embeddings (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536),  -- Adjust dimensions based on your model
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create an index for vector similarity search
CREATE INDEX IF NOT EXISTS document_embeddings_embedding_idx 
    ON document_embeddings 
    USING ivfflat (embedding vector_cosine_ops) 
    WITH (lists = 100);

-- Create a read-only user for your application
CREATE USER app_readonly WITH PASSWORD '${APP_READONLY_PASSWORD:-change_me}';
GRANT CONNECT ON DATABASE vector_db TO app_readonly;
GRANT USAGE ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;

-- Create a read-write user for your application
CREATE USER app_readwrite WITH PASSWORD '${APP_READWRITE_PASSWORD:-change_me}';
GRANT CONNECT ON DATABASE vector_db TO app_readwrite;
GRANT USAGE, CREATE ON SCHEMA public TO app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_readwrite;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_readwrite;
