-- RECONSTRUCTED from the handoff report's list of live columns (the original
-- file was committed empty). Before treating this as the source of truth,
-- compare it with the live table:
--   pg_dump --schema-only --table=public.restaurant_tables <connection-string>
CREATE TABLE IF NOT EXISTS restaurant_tables (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    table_number TEXT NOT NULL,
    qr_code TEXT UNIQUE,
    seating_capacity INTEGER NOT NULL DEFAULT 4,
    status table_status NOT NULL DEFAULT 'AVAILABLE',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, table_number)
);
