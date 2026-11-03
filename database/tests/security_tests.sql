-- Security regression tests: anonymous attacker, cross-tenant owner, kitchen
-- staff and manager. Every line of output must start with PASS.
-- Run with: database/tests/run.sh   (needs a disposable local PostgreSQL)
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
-- ---------- fixtures (as superuser) ----------
INSERT INTO auth.users VALUES
 ('11111111-1111-1111-1111-111111111111','owner_a@x.com', now()),
 ('22222222-2222-2222-2222-222222222222','owner_b@x.com', now()),
 ('33333333-3333-3333-3333-333333333333','kitchen_a@x.com', now()),
 ('44444444-4444-4444-4444-444444444444','manager_a@x.com', now());

CREATE OR REPLACE FUNCTION pg_temp.as_user(uid text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF uid IS NULL THEN PERFORM set_config('request.jwt.claims','',false); EXECUTE 'SET ROLE anon';
  ELSE PERFORM set_config('request.jwt.claims', json_build_object('sub',uid,'email',(SELECT email FROM auth.users WHERE id=uid::uuid),'role','authenticated')::text, false);
       EXECUTE 'SET ROLE authenticated'; END IF;
END $$;
CREATE TEMP TABLE results(test text, outcome text);
GRANT ALL ON results TO anon, authenticated;
-- expect_fail: runs SQL, records PASS if it errors or affects 0 rows
CREATE OR REPLACE FUNCTION pg_temp.expect_blocked(name text, q text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE q; GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO results VALUES (name, CASE WHEN n = 0 THEN 'PASS (0 rows)' ELSE 'FAIL ('||n||' rows)' END);
EXCEPTION WHEN OTHERS THEN INSERT INTO results VALUES (name, 'PASS ('||left(SQLERRM,60)||')');
END $$;
CREATE OR REPLACE FUNCTION pg_temp.expect_ok(name text, q text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE q; GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO results VALUES (name, CASE WHEN n > 0 THEN 'PASS ('||n||' rows)' ELSE 'FAIL (0 rows)' END);
EXCEPTION WHEN OTHERS THEN INSERT INTO results VALUES (name, 'FAIL ('||left(SQLERRM,80)||')');
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO anon, authenticated;

-- ---------- owner A onboards via client (the dashboard form flow) ----------
SELECT pg_temp.as_user('11111111-1111-1111-1111-111111111111');
SELECT pg_temp.expect_ok('A creates restaurant via insert..returning',
 $q$INSERT INTO restaurants(name, owner_email, phone) VALUES ('Cafe A','spoof@evil.com','999') RETURNING id$q$);
SELECT pg_temp.expect_ok('owner_email forced to auth email',
 $q$SELECT 1 FROM restaurants WHERE name='Cafe A' AND owner_email='owner_a@x.com' AND owner_id=auth.uid()$q$);
SELECT pg_temp.expect_blocked('A cannot hand ownership to B',
 $q$UPDATE restaurants SET owner_id='22222222-2222-2222-2222-222222222222' WHERE name='Cafe A'$q$);
SELECT pg_temp.expect_blocked('A cannot delete restaurant', $q$DELETE FROM restaurants$q$);
RESET ROLE;

-- B onboards
SELECT pg_temp.as_user('22222222-2222-2222-2222-222222222222');
SELECT pg_temp.expect_ok('B creates restaurant (same email no longer blocks)', $q$INSERT INTO restaurants(name, owner_email) VALUES ('Diner B','x') RETURNING id$q$);
RESET ROLE;

-- superuser sets up the rest of A's data
DO $$
DECLARE ra uuid := (SELECT id FROM restaurants WHERE name='Cafe A');
        rb uuid := (SELECT id FROM restaurants WHERE name='Diner B');
        br uuid; t uuid; c uuid; cb uuid;
BEGIN
  INSERT INTO branches(restaurant_id,name) VALUES (ra,'Main') RETURNING id INTO br;
  INSERT INTO staff_users(branch_id,restaurant_id,auth_user_id,full_name,email,role) VALUES
   (br,ra,'33333333-3333-3333-3333-333333333333','Kay','kitchen_a@x.com','KITCHEN'),
   (br,ra,'44444444-4444-4444-4444-444444444444','Max','manager_a@x.com','MANAGER');
  INSERT INTO restaurant_tables(restaurant_id,table_number) VALUES (ra,'T1') RETURNING id INTO t;
  INSERT INTO table_sessions(restaurant_id,table_id) VALUES (ra,t);
  INSERT INTO menu_categories(restaurant_id,name) VALUES (ra,'Mains') RETURNING id INTO c;
  INSERT INTO menu_items(category_id,name,price) VALUES (c,'Biryani',250),(c,'Sold out dish',100);
  UPDATE menu_items SET is_available=false WHERE name='Sold out dish';
  INSERT INTO menu_categories(restaurant_id,name) VALUES (rb,'B Mains') RETURNING id INTO cb;
  INSERT INTO menu_items(category_id,name,price) VALUES (cb,'B Burger',10);
END $$;
SELECT session_code AS code FROM table_sessions LIMIT 1 \gset
SELECT id AS biryani FROM menu_items WHERE name='Biryani' \gset
SELECT id AS soldout FROM menu_items WHERE name='Sold out dish' \gset
SELECT id AS bburger FROM menu_items WHERE name='B Burger' \gset

-- ---------- anonymous attacker with the publishable key ----------
SELECT pg_temp.as_user(NULL);
SELECT pg_temp.expect_blocked('anon reads restaurants (emails/GST)', 'SELECT * FROM restaurants');
SELECT pg_temp.expect_blocked('anon reads staff_users', 'SELECT * FROM staff_users');
SELECT pg_temp.expect_blocked('anon reads payments', 'SELECT * FROM payments');
SELECT pg_temp.expect_blocked('anon reads session codes', 'SELECT * FROM table_sessions');
SELECT pg_temp.expect_blocked('anon inserts restaurant', $q$INSERT INTO restaurants(name,owner_email) VALUES ('x','y')$q$);
SELECT pg_temp.expect_blocked('anon inserts order directly', $q$INSERT INTO orders(session_id,order_number) SELECT id,'X' FROM table_sessions$q$);
SELECT pg_temp.expect_blocked('anon inserts payment', $q$INSERT INTO payments(order_id,amount,payment_method) VALUES (gen_random_uuid(),1,'CASH')$q$);
SELECT pg_temp.expect_ok('anon can read public menu', 'SELECT * FROM menu_items');
SELECT pg_temp.expect_blocked('anon menu hides unavailable items', $q$SELECT * FROM menu_items WHERE name='Sold out dish'$q$);
SELECT pg_temp.expect_blocked('anon calls private helper', $q$SELECT private.active_session('x')$q$);
SELECT pg_temp.expect_blocked('place_order with fake session', format($q$SELECT * FROM place_order('%s', '[{"menu_item_id":"%s"}]')$q$, repeat('a',64), :'biryani'));
SELECT pg_temp.expect_ok('place_order valid (2 x Biryani, client price ignored)', format('SELECT * FROM place_order(%L, %L::jsonb)', :'code', jsonb_build_array(jsonb_build_object('menu_item_id', :'biryani', 'quantity', 2, 'unit_price', 0))::text));
SELECT pg_temp.expect_blocked('place_order negative qty', format($q$SELECT * FROM place_order('%s', '[{"menu_item_id":"%s","quantity":-5}]')$q$, :'code', :'biryani'));
SELECT pg_temp.expect_blocked('place_order other restaurant item', format($q$SELECT * FROM place_order('%s', '[{"menu_item_id":"%s"}]')$q$, :'code', :'bburger'));
SELECT pg_temp.expect_blocked('place_order unavailable item', format($q$SELECT * FROM place_order('%s', '[{"menu_item_id":"%s"}]')$q$, :'code', :'soldout'));
SELECT pg_temp.expect_blocked('place_order empty cart', format($q$SELECT * FROM place_order('%s', '[]')$q$, :'code'));
SELECT pg_temp.expect_ok('service request', format($q$SELECT create_service_request('%s','WATER')$q$, :'code'));
SELECT pg_temp.expect_ok('track orders', format($q$SELECT * FROM get_session_orders('%s')$q$, :'code'));
RESET ROLE;
SELECT pg_temp.expect_ok('server-side price: total = 500', $q$SELECT 1 FROM orders WHERE total_amount = 500$q$);
SELECT pg_temp.expect_ok('dup WATER request deduped', $q$SELECT 1 FROM (SELECT count(*) c FROM service_requests) s WHERE c = 1$q$);

-- ---------- owner B (another tenant) ----------
SELECT pg_temp.as_user('22222222-2222-2222-2222-222222222222');
SELECT pg_temp.expect_blocked('B reads A orders', 'SELECT * FROM orders');
SELECT pg_temp.expect_blocked('B reads A staff', 'SELECT * FROM staff_users');
SELECT pg_temp.expect_blocked('B updates A order', $q$UPDATE orders SET status='CANCELLED'$q$);
SELECT pg_temp.expect_blocked('B adds himself as A staff', format($q$INSERT INTO staff_users(branch_id,restaurant_id,auth_user_id,full_name,email,role) SELECT branch_id,restaurant_id,auth.uid(),'evil','e@x','OWNER' FROM staff_users LIMIT 1$q$));
SELECT pg_temp.expect_blocked('B sees A in restaurants', $q$SELECT * FROM restaurants WHERE name='Cafe A'$q$);
RESET ROLE;

-- ---------- kitchen staff of A ----------
SELECT pg_temp.as_user('33333333-3333-3333-3333-333333333333');
SELECT pg_temp.expect_ok('kitchen reads orders', 'SELECT * FROM orders');
SELECT pg_temp.expect_ok('kitchen sets PREPARING', $q$UPDATE orders SET status='PREPARING'$q$);
SELECT pg_temp.expect_blocked('kitchen sets PAID', $q$UPDATE orders SET status='PAID'$q$);
SELECT pg_temp.expect_blocked('kitchen edits total_amount', $q$UPDATE orders SET total_amount=1$q$);
SELECT pg_temp.expect_blocked('kitchen reads payments', 'SELECT * FROM payments');
SELECT pg_temp.expect_blocked('kitchen promotes self', $q$UPDATE staff_users SET role='OWNER' WHERE auth_user_id=auth.uid()$q$);
SELECT pg_temp.expect_blocked('kitchen edits menu price', $q$UPDATE menu_items SET price=1$q$);
RESET ROLE;

-- ---------- manager of A ----------
SELECT pg_temp.as_user('44444444-4444-4444-4444-444444444444');
SELECT pg_temp.expect_blocked('manager edits unit_price', $q$UPDATE order_items SET unit_price=1$q$);
SELECT pg_temp.expect_ok('manager changes qty -> repriced', $q$UPDATE order_items SET quantity=3$q$);
SELECT pg_temp.expect_blocked('manager promotes self to OWNER', $q$UPDATE staff_users SET role='OWNER' WHERE auth_user_id=auth.uid()$q$);
SELECT pg_temp.expect_ok('manager records payment', $q$INSERT INTO payments(order_id,amount,payment_method) SELECT id,750,'UPI' FROM orders$q$);
SELECT pg_temp.expect_blocked('manager negative payment', $q$INSERT INTO payments(order_id,amount,payment_method) SELECT id,-750,'UPI' FROM orders$q$);
SELECT pg_temp.expect_blocked('manager deletes payment', 'DELETE FROM payments');
SELECT pg_temp.expect_ok('manager sets PAID', $q$UPDATE orders SET status='PAID'$q$);
RESET ROLE;
SELECT pg_temp.expect_ok('total recomputed to 750', $q$SELECT 1 FROM orders WHERE total_amount = 750$q$);
SELECT pg_temp.expect_blocked('deleting order with payment (no cascade)', 'DELETE FROM orders');

SELECT outcome LIKE 'PASS%' AS ok, test, outcome FROM results;
SELECT count(*) FILTER (WHERE outcome LIKE 'PASS%') AS passed, count(*) AS total FROM results;
