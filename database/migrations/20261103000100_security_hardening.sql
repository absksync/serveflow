-- =============================================================================
-- ServeFlow — security hardening migration
-- =============================================================================
-- Safe to run on the existing Supabase database:
--   * idempotent (can be re-run)
--   * deletes no rows, drops no tables, drops no columns
--   * runs in one transaction: if any statement fails, nothing changes
--
-- What it fixes:
--   1. Row Level Security was not enabled anywhere. With the publishable key
--      that ships in the browser bundle, anyone could read/insert/update/delete
--      every row (owner emails, phones, GST numbers, orders, payments).
--   2. No link between restaurants/staff and Supabase Auth users, so no
--      tenant isolation was possible.
--   3. Prices and totals were taken from the client (order_items.unit_price,
--      orders.total_amount) — a customer could order anything for ₹0.
--   4. No CHECK constraints: negative quantities/prices/amounts were accepted.
--   5. Kitchen staff could mark orders PAID / REFUNDED.
--   6. Deleting a session or order silently cascaded into payment records.
--   7. owner_email UNIQUE let anyone "claim" another person's email.
--   8. Customers (anonymous) had no safe write path; they now go through
--      narrow SECURITY DEFINER functions validated by an unguessable session
--      code instead of direct table access.
--
-- Run it in the Supabase SQL Editor (or `supabase db push`). Then do the
-- manual follow-ups listed at the bottom of this file.
-- =============================================================================

BEGIN;

-- Helpers live in a schema that PostgREST does NOT expose as RPC endpoints.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, anon;

-- -----------------------------------------------------------------------------
-- 1. Link tenants to Supabase Auth
-- -----------------------------------------------------------------------------
ALTER TABLE public.restaurants
    ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES auth.users(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS restaurants_owner_id_idx ON public.restaurants(owner_id);

-- One person may own several restaurants, and nobody should be able to block
-- a real owner by registering their email first. Ownership is owner_id now.
ALTER TABLE public.restaurants DROP CONSTRAINT IF EXISTS restaurants_owner_email_key;

ALTER TABLE public.staff_users
    ADD COLUMN IF NOT EXISTS restaurant_id UUID REFERENCES public.restaurants(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS auth_user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

-- Live DB (per handoff) has staff_users.restaurant_id; repo SQL has branch_id.
-- Backfill restaurant_id from the branch when only branch_id is populated.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'staff_users'
                 AND column_name = 'branch_id')
       AND to_regclass('public.branches') IS NOT NULL THEN
        UPDATE public.staff_users s
           SET restaurant_id = b.restaurant_id
          FROM public.branches b
         WHERE s.branch_id = b.id AND s.restaurant_id IS NULL;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS staff_users_restaurant_auth_user_uidx
    ON public.staff_users(restaurant_id, auth_user_id);
CREATE INDEX IF NOT EXISTS staff_users_auth_user_id_idx ON public.staff_users(auth_user_id);

-- Unguessable customer session codes (2 x UUIDv4 ≈ 244 random bits).
ALTER TABLE public.table_sessions ADD COLUMN IF NOT EXISTS session_code TEXT;
ALTER TABLE public.table_sessions
    ALTER COLUMN session_code
    SET DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
CREATE UNIQUE INDEX IF NOT EXISTS table_sessions_session_code_uidx
    ON public.table_sessions(session_code);

-- Server-generated order numbers (column is NOT NULL with no default).
ALTER TABLE public.orders
    ALTER COLUMN order_number
    SET DEFAULT 'SF-' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYMMDD') || '-'
                || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

-- -----------------------------------------------------------------------------
-- 2. Data integrity constraints (NOT VALID = enforced for new/changed rows
--    without failing on any bad rows that already exist; see follow-ups)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    c RECORD;
BEGIN
    FOR c IN SELECT * FROM (VALUES
        ('menu_items',        'menu_items_price_nonneg',        'price >= 0'),
        ('order_items',       'order_items_quantity_range',     'quantity BETWEEN 1 AND 100'),
        ('order_items',       'order_items_prices_nonneg',      'unit_price >= 0 AND total_price >= 0'),
        ('orders',            'orders_total_nonneg',            'total_amount >= 0'),
        ('payments',          'payments_amount_positive',       'amount > 0'),
        ('restaurant_tables', 'restaurant_tables_capacity_pos', 'seating_capacity > 0'),
        ('orders',            'orders_notes_len',               'notes IS NULL OR length(notes) <= 500'),
        ('order_items',       'order_items_instructions_len',   'special_instructions IS NULL OR length(special_instructions) <= 300'),
        ('service_requests',  'service_requests_notes_len',     'notes IS NULL OR length(notes) <= 300')
    ) AS t(tbl, name, expr)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = c.name) THEN
            EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%s) NOT VALID',
                           c.tbl, c.name, c.expr);
        END IF;
    END LOOP;
END $$;

-- Financial records must never disappear through a cascade.
DO $$
DECLARE
    fk RECORD;
BEGIN
    FOR fk IN
        SELECT con.conname, cl.relname AS tbl, att.attname AS col, ref.relname AS reftbl
          FROM pg_constraint con
          JOIN pg_class cl  ON cl.oid  = con.conrelid
          JOIN pg_class ref ON ref.oid = con.confrelid
          JOIN pg_namespace n ON n.oid = cl.relnamespace
          JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
         WHERE con.contype = 'f' AND con.confdeltype = 'c' AND n.nspname = 'public'
           AND ((cl.relname = 'payments' AND ref.relname = 'orders')
             OR (cl.relname = 'orders'   AND ref.relname = 'table_sessions'))
    LOOP
        EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', fk.tbl, fk.conname);
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.%I(id) ON DELETE RESTRICT',
                       fk.tbl, fk.conname, fk.col, fk.reftbl);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Authorization helpers
-- -----------------------------------------------------------------------------
-- TRUE if the current user owns the restaurant, or is an active staff member
-- whose role is in p_roles (NULL = any role). Owners pass every role check.
CREATE OR REPLACE FUNCTION private.has_restaurant_role(p_restaurant_id UUID, p_roles public.user_role[] DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL AND (
        EXISTS (SELECT 1 FROM public.restaurants r
                 WHERE r.id = p_restaurant_id AND r.owner_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.staff_users s
                    WHERE s.restaurant_id = p_restaurant_id
                      AND s.auth_user_id = auth.uid()
                      AND s.is_active
                      AND (p_roles IS NULL OR s.role = ANY (p_roles)))
    );
$$;

CREATE OR REPLACE FUNCTION private.session_restaurant(p_session_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT restaurant_id FROM public.table_sessions WHERE id = p_session_id $$;

CREATE OR REPLACE FUNCTION private.order_restaurant(p_order_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT ts.restaurant_id FROM public.orders o
      JOIN public.table_sessions ts ON ts.id = o.session_id
     WHERE o.id = p_order_id
$$;

-- Used by the public-menu policies: anon has no access to restaurants itself.
CREATE OR REPLACE FUNCTION private.restaurant_is_active(p_restaurant_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT COALESCE((SELECT is_active FROM public.restaurants WHERE id = p_restaurant_id), FALSE) $$;

CREATE OR REPLACE FUNCTION private.category_is_public(p_category_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (SELECT 1 FROM public.menu_categories mc JOIN public.restaurants r ON r.id = mc.restaurant_id
                    WHERE mc.id = p_category_id AND mc.is_active AND r.is_active)
$$;

CREATE OR REPLACE FUNCTION private.category_restaurant(p_category_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT restaurant_id FROM public.menu_categories WHERE id = p_category_id $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA private TO authenticated, anon;

-- -----------------------------------------------------------------------------
-- 4. Triggers: ownership, server-side pricing, status rules, updated_at
-- -----------------------------------------------------------------------------
-- A signed-in user creating a restaurant always becomes its owner; they cannot
-- assign it to someone else or reassign it later.
CREATE OR REPLACE FUNCTION private.restaurants_enforce_owner()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            NEW.owner_id := auth.uid();
            NEW.owner_email := COALESCE(auth.jwt() ->> 'email', NEW.owner_email);
        ELSIF NEW.owner_id IS DISTINCT FROM OLD.owner_id
           OR NEW.owner_email IS DISTINCT FROM OLD.owner_email THEN
            RAISE EXCEPTION 'Ownership cannot be changed from the client' USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS restaurants_enforce_owner ON public.restaurants;
CREATE TRIGGER restaurants_enforce_owner BEFORE INSERT OR UPDATE ON public.restaurants
    FOR EACH ROW EXECUTE FUNCTION private.restaurants_enforce_owner();

-- Price every order line from the menu, never from the client, and make sure
-- the menu item belongs to the same restaurant as the order.
CREATE OR REPLACE FUNCTION private.order_items_price()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_available BOOLEAN;
    v_item_restaurant UUID;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.order_id IS DISTINCT FROM OLD.order_id THEN
        RAISE EXCEPTION 'order_id cannot be changed' USING ERRCODE = '42501';
    END IF;

    SELECT mi.price, mi.is_available, mc.restaurant_id
      INTO v_price, v_available, v_item_restaurant
      FROM public.menu_items mi
      JOIN public.menu_categories mc ON mc.id = mi.category_id
     WHERE mi.id = NEW.menu_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown menu item' USING ERRCODE = '23503';
    END IF;
    IF v_item_restaurant IS DISTINCT FROM private.order_restaurant(NEW.order_id) THEN
        RAISE EXCEPTION 'Menu item does not belong to this restaurant' USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'INSERT' OR NEW.menu_item_id IS DISTINCT FROM OLD.menu_item_id THEN
        IF NOT COALESCE(v_available, FALSE) THEN
            RAISE EXCEPTION 'Menu item is not available' USING ERRCODE = 'P0001';
        END IF;
        NEW.unit_price := v_price;
    ELSE
        NEW.unit_price := OLD.unit_price;  -- keep the price the customer ordered at
    END IF;
    NEW.total_price := NEW.unit_price * NEW.quantity;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS order_items_price ON public.order_items;
CREATE TRIGGER order_items_price BEFORE INSERT OR UPDATE ON public.order_items
    FOR EACH ROW EXECUTE FUNCTION private.order_items_price();

CREATE OR REPLACE FUNCTION private.orders_recompute_total()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_order UUID := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE public.orders
       SET total_amount = COALESCE((SELECT SUM(total_price) FROM public.order_items WHERE order_id = v_order), 0)
     WHERE id = v_order;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS orders_recompute_total ON public.order_items;
CREATE TRIGGER orders_recompute_total AFTER INSERT OR UPDATE OR DELETE ON public.order_items
    FOR EACH ROW EXECUTE FUNCTION private.orders_recompute_total();

-- Only owners/managers may move money-related statuses.
CREATE OR REPLACE FUNCTION private.orders_status_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NOT NULL
       AND NEW.status IS DISTINCT FROM OLD.status
       AND NEW.status IN ('PAID', 'REFUNDED', 'CANCELLED')
       AND NOT private.has_restaurant_role(private.session_restaurant(NEW.session_id),
                                           ARRAY['OWNER','MANAGER']::public.user_role[]) THEN
        RAISE EXCEPTION 'Only owners or managers can set status %', NEW.status USING ERRCODE = '42501';
    END IF;
    IF auth.uid() IS NOT NULL AND NEW.session_id IS DISTINCT FROM OLD.session_id THEN
        RAISE EXCEPTION 'session_id cannot be changed' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS orders_status_guard ON public.orders;
CREATE TRIGGER orders_status_guard BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION private.orders_status_guard();

-- Staff cannot promote themselves or move themselves to another restaurant.
CREATE OR REPLACE FUNCTION private.staff_users_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NOT NULL AND TG_OP = 'UPDATE'
       AND NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id THEN
        RAISE EXCEPTION 'restaurant_id cannot be changed' USING ERRCODE = '42501';
    END IF;
    IF auth.uid() IS NOT NULL AND NEW.role = 'OWNER'
       AND NOT EXISTS (SELECT 1 FROM public.restaurants
                        WHERE id = NEW.restaurant_id AND owner_id = auth.uid()) THEN
        RAISE EXCEPTION 'Only the restaurant owner can grant the OWNER role' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS staff_users_guard ON public.staff_users;
CREATE TRIGGER staff_users_guard BEFORE INSERT OR UPDATE ON public.staff_users
    FOR EACH ROW EXECUTE FUNCTION private.staff_users_guard();

CREATE OR REPLACE FUNCTION private.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ''
AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOR t IN SELECT table_name FROM information_schema.columns
              WHERE table_schema = 'public' AND column_name = 'updated_at'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS set_updated_at ON public.%I', t);
        EXECUTE format('CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I
                        FOR EACH ROW EXECUTE FUNCTION private.set_updated_at()', t);
    END LOOP;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA private TO authenticated, anon;

-- -----------------------------------------------------------------------------
-- 5. Row Level Security
-- -----------------------------------------------------------------------------
-- Enable RLS everywhere and remove ALL pre-existing policies on these tables
-- (an "allow all" policy added to make the onboarding form work would
-- otherwise be OR-ed with the policies below and defeat them).
DO $$
DECLARE
    t TEXT;
    p RECORD;
BEGIN
    FOREACH t IN ARRAY ARRAY['restaurants','branches','staff_users','restaurant_tables',
                             'table_sessions','menu_categories','menu_items','orders',
                             'order_items','service_requests','payments']
    LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE NOTICE 'Table public.% not found, skipping', t;
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        FOR p IN SELECT policyname FROM pg_policies WHERE schemaname = 'public' AND tablename = t
        LOOP
            RAISE NOTICE 'Dropping existing policy "%" on %', p.policyname, t;
            EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, t);
        END LOOP;
        -- Anonymous visitors get no direct table access at all...
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        -- ...and signed-in users get table privileges, narrowed by RLS below.
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    END LOOP;
END $$;

-- Column-level limits: totals, prices and ownership are server-managed.
REVOKE INSERT, UPDATE ON public.orders FROM authenticated;
GRANT INSERT (session_id, notes) ON public.orders TO authenticated;
GRANT UPDATE (status, notes) ON public.orders TO authenticated;

REVOKE INSERT, UPDATE ON public.order_items FROM authenticated;
GRANT INSERT (order_id, menu_item_id, quantity, special_instructions) ON public.order_items TO authenticated;
GRANT UPDATE (quantity, special_instructions) ON public.order_items TO authenticated;

-- restaurants
-- owner_id check is inline (not only via the helper) so that
-- insert(...).select() can return the row created in the same statement.
CREATE POLICY restaurants_select ON public.restaurants FOR SELECT TO authenticated
    USING (owner_id = auth.uid() OR private.has_restaurant_role(id));
CREATE POLICY restaurants_insert ON public.restaurants FOR INSERT TO authenticated
    WITH CHECK (owner_id = auth.uid());
CREATE POLICY restaurants_update ON public.restaurants FOR UPDATE TO authenticated
    USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid());
-- No DELETE policy: deactivate with is_active = false instead.

-- branches (exists in the repo SQL but NOT in the live DB's verified table
-- list, so only create these policies when the table is present)
DO $$
BEGIN
    IF to_regclass('public.branches') IS NOT NULL THEN
        CREATE POLICY branches_select ON public.branches FOR SELECT TO authenticated
            USING (private.has_restaurant_role(restaurant_id));
        CREATE POLICY branches_write ON public.branches FOR ALL TO authenticated
            USING (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]))
            WITH CHECK (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]));
    END IF;
END $$;

-- staff_users: everyone in the restaurant can see colleagues; only the owner
-- manages staff (prevents a manager from escalating privileges).
CREATE POLICY staff_users_select ON public.staff_users FOR SELECT TO authenticated
    USING (private.has_restaurant_role(restaurant_id) OR auth_user_id = auth.uid());
CREATE POLICY staff_users_write ON public.staff_users FOR ALL TO authenticated
    USING (private.has_restaurant_role(restaurant_id, ARRAY['OWNER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(restaurant_id, ARRAY['OWNER']::public.user_role[]));

-- restaurant_tables
CREATE POLICY restaurant_tables_select ON public.restaurant_tables FOR SELECT TO authenticated
    USING (private.has_restaurant_role(restaurant_id));
CREATE POLICY restaurant_tables_write ON public.restaurant_tables FOR ALL TO authenticated
    USING (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]));

-- table_sessions (session_code is a bearer secret: staff only)
CREATE POLICY table_sessions_select ON public.table_sessions FOR SELECT TO authenticated
    USING (private.has_restaurant_role(restaurant_id));
CREATE POLICY table_sessions_write ON public.table_sessions FOR ALL TO authenticated
    USING (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]));

-- menu: public, read-only for active items of active restaurants
GRANT SELECT ON public.menu_categories, public.menu_items TO anon;
CREATE POLICY menu_categories_public_read ON public.menu_categories FOR SELECT TO anon, authenticated
    USING (is_active AND private.restaurant_is_active(restaurant_id));
CREATE POLICY menu_categories_staff_read ON public.menu_categories FOR SELECT TO authenticated
    USING (private.has_restaurant_role(restaurant_id));
CREATE POLICY menu_categories_write ON public.menu_categories FOR ALL TO authenticated
    USING (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(restaurant_id, ARRAY['OWNER','MANAGER']::public.user_role[]));

CREATE POLICY menu_items_public_read ON public.menu_items FOR SELECT TO anon, authenticated
    USING (is_available AND private.category_is_public(category_id));
CREATE POLICY menu_items_staff_read ON public.menu_items FOR SELECT TO authenticated
    USING (private.has_restaurant_role(private.category_restaurant(category_id)));
CREATE POLICY menu_items_write ON public.menu_items FOR ALL TO authenticated
    USING (private.has_restaurant_role(private.category_restaurant(category_id), ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(private.category_restaurant(category_id), ARRAY['OWNER','MANAGER']::public.user_role[]));

-- orders: all staff read and update status (guard trigger limits PAID etc.)
CREATE POLICY orders_select ON public.orders FOR SELECT TO authenticated
    USING (private.has_restaurant_role(private.session_restaurant(session_id)));
CREATE POLICY orders_insert ON public.orders FOR INSERT TO authenticated
    WITH CHECK (private.has_restaurant_role(private.session_restaurant(session_id)));
CREATE POLICY orders_update ON public.orders FOR UPDATE TO authenticated
    USING (private.has_restaurant_role(private.session_restaurant(session_id)))
    WITH CHECK (private.has_restaurant_role(private.session_restaurant(session_id)));
-- No DELETE: cancel instead.

-- order_items
CREATE POLICY order_items_select ON public.order_items FOR SELECT TO authenticated
    USING (private.has_restaurant_role(private.order_restaurant(order_id)));
CREATE POLICY order_items_insert ON public.order_items FOR INSERT TO authenticated
    WITH CHECK (private.has_restaurant_role(private.order_restaurant(order_id)));
CREATE POLICY order_items_update ON public.order_items FOR UPDATE TO authenticated
    USING (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]));
CREATE POLICY order_items_delete ON public.order_items FOR DELETE TO authenticated
    USING (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]));

-- service_requests
CREATE POLICY service_requests_select ON public.service_requests FOR SELECT TO authenticated
    USING (private.has_restaurant_role(private.session_restaurant(session_id)));
CREATE POLICY service_requests_write ON public.service_requests FOR ALL TO authenticated
    USING (private.has_restaurant_role(private.session_restaurant(session_id)))
    WITH CHECK (private.has_restaurant_role(private.session_restaurant(session_id)));

-- payments: owners/managers only; kitchen has no access; never deletable
CREATE POLICY payments_select ON public.payments FOR SELECT TO authenticated
    USING (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]));
CREATE POLICY payments_insert ON public.payments FOR INSERT TO authenticated
    WITH CHECK (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]));
CREATE POLICY payments_update ON public.payments FOR UPDATE TO authenticated
    USING (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]))
    WITH CHECK (private.has_restaurant_role(private.order_restaurant(order_id), ARRAY['OWNER','MANAGER']::public.user_role[]));
REVOKE DELETE ON public.payments FROM authenticated;

-- -----------------------------------------------------------------------------
-- 6. Customer API (anonymous, QR flow) — the ONLY way anon can write
-- -----------------------------------------------------------------------------
-- Returns the ACTIVE session for a code, or raises. Sessions older than
-- 12 hours are refused even if staff forgot to close them.
CREATE OR REPLACE FUNCTION private.active_session(p_session_code TEXT)
RETURNS public.table_sessions
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v public.table_sessions;
BEGIN
    IF p_session_code IS NULL OR length(p_session_code) < 32 THEN
        RAISE EXCEPTION 'Invalid session' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v FROM public.table_sessions
     WHERE session_code = p_session_code
       AND status = 'ACTIVE'
       AND started_at > now() - interval '12 hours';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid or expired session' USING ERRCODE = '42501';
    END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.place_order(p_session_code TEXT, p_items JSONB, p_notes TEXT DEFAULT NULL)
RETURNS TABLE (order_id UUID, order_number TEXT, total_amount NUMERIC)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_session public.table_sessions;
    v_order_id UUID;
    v_item JSONB;
    v_qty INTEGER;
BEGIN
    v_session := private.active_session(p_session_code);

    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'An order must contain between 1 and 50 lines' USING ERRCODE = '22023';
    END IF;

    -- Basic abuse throttle: at most 5 orders per session per 5 minutes.
    IF (SELECT count(*) FROM public.orders o
         WHERE o.session_id = v_session.id AND o.created_at > now() - interval '5 minutes') >= 5 THEN
        RAISE EXCEPTION 'Too many orders, please wait a moment' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.orders (session_id, notes)
    VALUES (v_session.id, left(p_notes, 500))
    RETURNING id INTO v_order_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_qty := COALESCE((v_item ->> 'quantity')::INTEGER, 1);
        IF v_qty NOT BETWEEN 1 AND 20 THEN
            RAISE EXCEPTION 'Quantity must be between 1 and 20' USING ERRCODE = '22023';
        END IF;
        -- unit_price/total_price are filled in by the order_items_price trigger
        INSERT INTO public.order_items (order_id, menu_item_id, quantity, unit_price, total_price, special_instructions)
        VALUES (v_order_id, (v_item ->> 'menu_item_id')::UUID, v_qty, 0, 0,
                left(v_item ->> 'special_instructions', 300));
    END LOOP;

    RETURN QUERY SELECT o.id, o.order_number, o.total_amount FROM public.orders o WHERE o.id = v_order_id;
END $$;

CREATE OR REPLACE FUNCTION public.create_service_request(p_session_code TEXT, p_type public.request_type, p_notes TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_session public.table_sessions;
    v_id UUID;
BEGIN
    v_session := private.active_session(p_session_code);
    -- De-duplicate: one pending request of each type per table.
    SELECT id INTO v_id FROM public.service_requests
     WHERE session_id = v_session.id AND request_type = p_type AND status = 'PENDING';
    IF FOUND THEN
        RETURN v_id;
    END IF;
    INSERT INTO public.service_requests (session_id, request_type, notes)
    VALUES (v_session.id, p_type, left(p_notes, 300))
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.get_session_orders(p_session_code TEXT)
RETURNS TABLE (order_id UUID, order_number TEXT, status public.order_status, total_amount NUMERIC, created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_session public.table_sessions;
BEGIN
    v_session := private.active_session(p_session_code);
    RETURN QUERY
        SELECT o.id, o.order_number, o.status, o.total_amount, o.created_at
          FROM public.orders o WHERE o.session_id = v_session.id
         ORDER BY o.created_at;
END $$;

REVOKE ALL ON FUNCTION public.place_order(TEXT, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_service_request(TEXT, public.request_type, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_session_orders(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order(TEXT, JSONB, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_service_request(TEXT, public.request_type, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_session_orders(TEXT) TO anon, authenticated;
REVOKE ALL ON FUNCTION private.active_session(TEXT) FROM PUBLIC, anon, authenticated;

COMMIT;

-- =============================================================================
-- MANUAL FOLLOW-UPS (run and check each one yourself)
-- =============================================================================
-- a) Existing restaurants have owner_id = NULL and are now invisible to the
--    app. After the real owner signs up through Supabase Auth, link them:
--      UPDATE public.restaurants r SET owner_id = u.id
--        FROM auth.users u
--       WHERE r.owner_id IS NULL AND lower(u.email) = lower(r.owner_email)
--         AND u.email_confirmed_at IS NOT NULL;
--
-- b) Link staff to their auth accounts the same way (staff_users.auth_user_id).
--
-- c) Check for old rows that break the new rules, fix them, then validate:
--      ALTER TABLE public.order_items VALIDATE CONSTRAINT order_items_quantity_range;
--      (repeat for each constraint added in section 2)
--
-- d) staff_users.password_hash (present in the live DB per the handoff)
--    duplicates Supabase Auth and was readable by anyone before this
--    migration. See 20261103000200_drop_staff_password_hash.sql.
--
-- e) In the Supabase dashboard: Advisors -> Security Advisor should show no
--    "RLS disabled" or "policy always true" warnings after this runs.
-- =============================================================================
