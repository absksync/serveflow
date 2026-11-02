-- RECONSTRUCTED from the handoff report's list of live columns (the original
-- file was committed empty). 009_orders.sql and 010_service_requests.sql
-- reference this table, so without it a fresh setup fails at 009.
-- Verify against the live table with pg_dump --schema-only.
CREATE TABLE IF NOT EXISTS table_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    table_id UUID NOT NULL REFERENCES restaurant_tables(id) ON DELETE CASCADE,
    session_code TEXT NOT NULL UNIQUE,
    status session_status NOT NULL DEFAULT 'ACTIVE',
    started_at TIMESTAMPTZ DEFAULT NOW(),
    ended_at TIMESTAMPTZ
);
