# ServeFlow audit: handoff report vs. repository (2026-11-03)

Audited commit `bb34ea4` (the only commit on `main`) against the
"SERVEFLOW — Complete Project Handoff & Technical Development Report", the
README and the docs. Fixes are on branch `fix/security-hardening`.

Legend: **Missing** = claimed but does not exist · **Empty** = file exists, 0 bytes ·
**Contradicts** = exists but differs from the claim.

## 1. Claimed in the handoff/README but not in the project

### Git history and workflow
| Claim | Reality |
|---|---|
| Incremental history, meaningful commits, "genuine development process" | **Missing.** The repo had exactly 1 commit ("Update README.md") containing all 65 files. |
| `main` → `develop` → `feature/*` workflow; README ticks "Git Workflow Setup" | **Missing.** Only `main` exists. |
| README "Commit Changes" step | **Contradicts** the handoff rule: it says `git add .`, which the handoff forbids. Fixed. |

### Repository structure (handoff §5)
| Claimed path | Reality |
|---|---|
| `.github/` | **Missing** (also listed in README structure). |
| `assets/icons/`, `assets/images/`, `assets/mockups/` | **Missing.** Only `assets/.gitkeep`. |
| `database/migrations/` | **Missing** (now added). |
| `frontend/app/`, `components/`, `hooks/`, `lib/`, `public/`-sibling `styles/`, `types/` ("original structure") | **Missing.** Only `frontend/src/` exists, so there is nothing to "reconcile". |
| `frontend/.env.example` | **Missing.** It could never have been committed: `frontend/.gitignore` ignored `.env*`. Fixed. |
| `backend/` controllers, routes, services, middleware, config, types, utils (14 `.ts` files) | **Empty.** All 0 bytes. No backend framework is installed either. |

### Frontend (handoff §10–12)
| Claim | Reality |
|---|---|
| Page shows "ServeFlow Connected 🚀"; console logs `DATA: Array(0)` | **Missing.** `src/app/page.tsx` is the stock create-next-app page. No Supabase query exists anywhere. |
| `src/lib/supabase/client.ts` "connected" | Exists but **is imported by nothing**. |
| `frontend/src/app/dashboard/page.tsx` with onboarding form (name, email, phone, address) | **Missing.** No dashboard route, no form, no insert code. |
| Restaurant onboarding UI "Created" (§18) | **Missing.** |
| Next.js 16.3.4 / React 19.2.8 / supabase-js ^2.116.0 | Matches `package.json`. |
| `src/lib/env.ts` | Not mentioned in the handoff; existed but was unused. |
| Page metadata | Still "Create Next App". |

### Database files (handoff §8)
| Claim | Reality |
|---|---|
| `001_extensions.sql` | **Empty.** |
| `004_branches.sql`, `005_users.sql`, `006_tables.sql`, `007_table_sessions.sql` | **Empty.** |
| `database/schema.sql`, `database/seeds/seed.sql` | **Empty.** |
| `restaurant_tables` and `table_sessions` exist | **No SQL anywhere** creates them, yet `009_orders.sql` and `010_service_requests.sql` reference `table_sessions`. Running the files "sequentially" as the README instructs **fails at 009**. |
| README "This will create the core database schema" | **False** for the reason above. |
| `staff_users` has `restaurant_id`, `password_hash`, `updated_at` | **Contradicts** `003`: it has `branch_id`, no `password_hash`, no `updated_at`. |
| Live DB has 10 tables (no `branches`) | **Contradicts** `003`, which creates `branches` (11 tables). README and docs also present branches as built. |
| Payments "associated with orders and restaurants" | `payments` has no `restaurant_id`; only via order → session. |
| `orders` support for delivery/takeaway | `orders.session_id` is `NOT NULL`, so only dine-in orders are possible. |
| RLS policies | **None** in any SQL file. |

### Documentation
| Claim | Reality |
|---|---|
| 12 docs files (architecture, business, product, roadmap…) | **10 of 12 are empty**: `docs/api-design.md`, `docs/architecture/api-design.md`, `docs/database-schema.md`, `docs/requirements.md`, `docs/roadmap.md`, `docs/business/pricing.md`, `docs/business/restaurant-onboarding.md`, `docs/product/features.md`, `requirements.md`, `user-flows.md`. Some are duplicate paths of each other. |
| `docs/architecture/database-schema.md` describes the schema | **Contradicts the SQL**: `restaurants.owner_id` (SQL: `owner_email`), table `users` (SQL: `staff_users`), table `tables` (SQL: `restaurant_tables`, absent), `menu_categories.branch_id` (SQL: `restaurant_id`), `orders.branch_id`/`table_id` (SQL: `session_id`), `order_items.price` (SQL: `unit_price`/`total_price`), `service_requests.table_id` (SQL: `session_id`). |

### README feature/progress claims
| Claim | Reality |
|---|---|
| Tech stack: Authentication = Supabase Auth | Not implemented (no login anywhere). Fixed wording. |
| Tech stack: Deployment = Vercel | No deployment config or evidence. Fixed wording. |
| "Supabase Integration" ✅ | Client unused. Fixed. |
| Core modules ✅ (Users, Tables, Sessions…) | Users/Tables/Sessions SQL files were empty; no module has UI or API. Fixed. |
| Payments: Cash/Card/UPI listed as features | Table only; no gateway. Fixed. |
| Env var `NEXT_PUBLIC_SUPABASE_ANON_KEY` | **Contradicts code**, which reads `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`. Following the README gave a broken app. Fixed. |

## 2. Vulnerabilities found and fixed

| # | Severity | Issue | Fix | Commit |
|---|---|---|---|---|
| 1 | Critical | `next@16.3.4`: unauthenticated RCE (GHSA-673q-mjm6-r5xr) | → `16.4.4` | `fix(deps)` |
| 2 | High | `sharp`, `zod`, `source-map-js`, `brace-expansion` advisories | `npm audit fix`; prod audit now 0 | `fix(deps)` |
| 3 | Critical | No RLS on any table → publishable key = full read/write of all data (emails, phones, GST, staff, orders, payments) | RLS everywhere, old policies dropped, anon revoked | `fix(db): enable RLS…` |
| 4 | Critical | No tenant isolation; restaurants/staff not linked to auth users | `owner_id`, `auth_user_id`, role-based policies | same |
| 5 | High | Client-supplied `unit_price` / `total_amount` → order anything for ₹0 | Prices & totals computed by triggers; columns not client-writable | same |
| 6 | High | Cross-restaurant items could be added to an order | Trigger checks item belongs to the order's restaurant and is available | same |
| 7 | High | Payments readable/writable by anyone; kitchen could mark orders PAID/REFUNDED | Payments owner/manager only, no delete; status guard trigger | same |
| 8 | High | Staff self-promotion to OWNER / moving restaurants | Owner-only staff management + guard trigger | same |
| 9 | Medium | Negative quantity/price/amount accepted; unbounded text | CHECK constraints (NOT VALID, see follow-ups) | same |
| 10 | Medium | Deleting a session/order cascaded into payment records | FKs changed to `ON DELETE RESTRICT` | same |
| 11 | Medium | `owner_email UNIQUE` → email squatting; owner_email client-controlled | Constraint dropped; email forced from JWT | same |
| 12 | Medium | No safe path for anonymous customers (would have required opening tables) | `place_order`, `create_service_request`, `get_session_orders` RPCs with 244-bit session code, 12h expiry, throttle | same |
| 13 | Medium | `staff_users.password_hash` (live DB) duplicating auth, exposed while RLS was off | Optional migration to drop it | same |
| 14 | Medium | Secret key could be pasted into `NEXT_PUBLIC_` var and shipped to browsers | `env.ts` refuses `sb_secret_`/service_role keys, validates URL | `fix(frontend)` |
| 15 | Low | No security headers; `X-Powered-By` leak | frame-ancestors/XFO, nosniff, HSTS, Referrer-Policy, Permissions-Policy | `fix(frontend)` |
| 16 | Low | README's `git add .` risks committing `.env.local` | Replaced | `docs` |

### Not fixed (and why)
- **16 moderate `minimatch` advisories** inside ESLint dev tooling: dev-only, never shipped; npm's suggested "fix" downgrades ESLint to v4.
- **The live Supabase database** is not changed by these commits. You must run the migration yourself (below).
- **Supabase project ref/URL in the handoff** are not secrets (the URL is public in any frontend), but don't paste keys into handoff documents.

## 3. What you need to do

1. In Supabase SQL Editor, run `database/migrations/20261103000100_security_hardening.sql`.
2. Check Dashboard → Advisors → Security Advisor shows no RLS warnings.
3. After an owner signs up via Supabase Auth, link legacy rows (query at the bottom of the migration).
4. Fix any bad legacy rows, then `VALIDATE CONSTRAINT` each new check.
5. Optionally run `20261103000200_drop_staff_password_hash.sql`.
6. Build the onboarding page **with Supabase Auth sign-in first**: inserts into
   `restaurants` now require a signed-in user (that is intentional).
