-- gen_random_uuid() is built into PostgreSQL 13+, so no extension is strictly
-- required for UUID primary keys. pgcrypto is enabled for hashing/random bytes
-- helpers; on Supabase it lives in the "extensions" schema.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
