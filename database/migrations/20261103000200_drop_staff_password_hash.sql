-- =============================================================================
-- OPTIONAL, DESTRUCTIVE — read before running.
-- =============================================================================
-- The handoff says the live staff_users table has a password_hash column.
-- Passwords belong in Supabase Auth (auth.users), which handles hashing,
-- rate limiting, resets and MFA. Before RLS was enabled, this column was
-- readable by anyone holding the publishable key.
--
-- This permanently deletes the column and its data. Run it only after:
--   1. the security hardening migration (…000100) has been applied, and
--   2. you have confirmed nothing in the app reads password_hash, and
--   3. staff have Supabase Auth accounts (or there is no real staff data yet).
--
-- Check first:
--   SELECT count(*) FILTER (WHERE password_hash IS NOT NULL) FROM public.staff_users;
-- =============================================================================

ALTER TABLE public.staff_users DROP COLUMN IF EXISTS password_hash;
