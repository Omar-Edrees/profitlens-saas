# ProfitLens — Security Engagement Report

**Date:** 2026-06-14
**Scope:** ProfitLens SaaS web app + Supabase backend (production `profitlens-saas`, staging `profitlens-staging`)
**Authorization:** Owner-authorized assessment and remediation.
**Method:** Web Application Security Testing skill (attack/OWASP) · VibeSec Secure Coding Guide (remediation standard) · Supabase skill (RLS/auth/grants).
**Assumed attacker:** a normal visitor holding the public anon key + a valid logged-in token, calling the REST/RPC API directly and bypassing the UI.

---

## 1. Findings table

| # | Title | Severity | OWASP / CWE | Status |
|---|-------|----------|-------------|--------|
| F1 | Privilege escalation — any logged-in user can set their own `role`/`plan` via direct REST write | **Critical** | A01 / CWE-639, CWE-269 | ✅ Fixed & verified |
| F2 | `SECURITY DEFINER` trigger function exposed as a public RPC (`/rpc/handle_new_user`) | Low | A05 / CWE-732 | ✅ Fixed & verified |
| F3 | `promo_codes` retained client table/column grants (RLS-blocked, defense-in-depth) | Low | A05 / CWE-732 | ✅ Fixed & verified |
| F4 | Session tokens in `localStorage` + CSP `script-src 'unsafe-inline'` (XSS token theft) | Medium | A07 / CWE-522 | ⚠️ Documented (needs SSR refactor) |
| F5 | Supabase Auth "leaked password protection" disabled | Low | A07 / CWE-521 | ⚠️ Action required (dashboard toggle) |
| F6 | `admin.html` builds inline `onclick` with email in a JS-string context | Low | A03 / CWE-79 | ✅ Fixed (data-* + event delegation) |
| F7 | `/api/redeem` has no app-level rate limiting (promo-code guessing/abuse) | Low | A04 / CWE-307 | ✅ Fixed (DB-backed limiter) |
| F8 | Additional cross-origin isolation headers (COOP/CORP) | Hardening | A05 | ✅ Added |

**Access-control checks that PASSED** (verified, no action needed): `user_data` IDOR (read/write/delete) is correctly bound to `auth.uid() = user_id` with `USING` + `WITH CHECK`; unfiltered mass `UPDATE`/`DELETE` is auto-scoped to the caller's own rows by RLS; admin APIs (`/api/admin/*`) re-verify `role='admin'` server-side via a signature-checked token (the client-side admin gate is UX only); `service_role` key is **not** present in any client bundle; APIs are bearer-token (not cookie) based so CSRF does not apply; all DB access uses the parameterized query builder (no SQL injection); no SSRF/file-upload/open-redirect surfaces exist.

---

## 2. Findings detail

### F1 — Privilege escalation via direct write to `profiles.role` / `profiles.plan` — **CRITICAL**

**Affected:** Table `public.profiles`, columns `role`, `plan` · Endpoint `PATCH /rest/v1/profiles?id=eq.<self>`
**OWASP:** A01 Broken Access Control · **CWE-639 / CWE-269**

**Description.** Supabase grants the `anon` and `authenticated` roles full table privileges by default. `profiles` had a permissive `UPDATE` policy scoped to the owner's own row (`auth.uid() = id`). Because a user *is* the owner of their own row, RLS permitted the update, and the table-level `UPDATE` grant permitted writing **every** column — including `role` and `plan`. The protection that `db/schema.sql` intended (`REVOKE UPDATE (role, plan) … FROM authenticated`) is a **no-op**, because a column-level revoke cannot override a table-level grant. It was also never applied to production (the schema was applied by hand; there was no migration history and production had drifted).

**Reproduction (PoC, run live on staging against the real RLS engine, then rolled back / cleaned up):**
Acting as a freshly signed-up `role=user, plan=free` account:
```sql
-- request identity = authenticated user; what PostgREST sets per request
set role authenticated;
set request.jwt.claims = '{"sub":"<my-user-id>","role":"authenticated"}';
update public.profiles set role='admin', plan='enterprise' where id='<my-user-id>';
```
**Result before fix:** `role=admin, plan=enterprise` — succeeded. Equivalent HTTP:
```
PATCH /rest/v1/profiles?id=eq.<my-user-id> HTTP/1.1
Host: <ref>.supabase.co
apikey: <anon-key>
Authorization: Bearer <my-jwt>
Content-Type: application/json

{"role":"admin","plan":"enterprise"}
```

**Impact.** Complete authorization bypass. Anyone who can sign up (free, self-service) can grant themselves `admin` — unlocking the `/admin` panel (list/promote/delete all users, manage promo codes) — and `enterprise`, unlocking all paid functionality for free. Full tenant compromise.

**Fix (applied to production + staging; see `db/security_hardening_2026-06-14.sql`).** Revoke write privileges at the **table** level; the client only ever reads `profiles`, and role/plan changes happen server-side via `service_role` (which bypasses RLS and grants):
```sql
revoke all on public.profiles from anon, authenticated;
grant  select on public.profiles to authenticated;
drop policy if exists "profiles_update_own" on public.profiles;   -- no client write path
-- profiles_select_own recreated: for select to authenticated using ((select auth.uid()) = id)
```

**Verification (production, post-fix):**
| check | result |
|---|---|
| `has_column_privilege(authenticated, profiles.role, UPDATE)` | `false` ✅ |
| `has_column_privilege(authenticated, profiles.plan, UPDATE)` | `false` ✅ |
| `has_table_privilege(authenticated, profiles, UPDATE)` | `false` ✅ |
| re-run of the attack (staging) | `BLOCKED: permission denied for table profiles` ✅ |
| legit: read own profile / write own `user_data` | still `OK` ✅ |

---

### F2 — `SECURITY DEFINER` trigger function callable as a public RPC — **Low**

**Affected:** `public.handle_new_user()` · `POST /rest/v1/rpc/handle_new_user`
**OWASP:** A05 · **CWE-732**. Flagged by Supabase advisors (`0028`/`0029`).

**Description.** The signup trigger function is `SECURITY DEFINER` but `EXECUTE` was granted to `PUBLIC`/`anon`/`authenticated`, exposing it as a callable RPC. Direct invocation has no trigger context (`new` is null) so practical impact is low, but a privileged definer function should never be a public endpoint.

**Fix (applied):** `revoke execute on function public.handle_new_user() from public, anon, authenticated;` — the trigger still fires (it runs as the owner). **Verified:** `has_function_privilege(authenticated, …, EXECUTE) = false`; both advisor warnings cleared.

---

### F3 — `promo_codes` leftover client grants — **Low**

**Description.** `promo_codes` is service-role-only (RLS enabled, no policy ⇒ deny-all), so it was not exploitable, but `anon`/`authenticated` still held table/column grants. **Fix (applied):** `revoke all on public.promo_codes from anon, authenticated;` (defense in depth). The remaining advisor INFO `rls_enabled_no_policy` on this table is **by design**.

---

### F4 — Session tokens in `localStorage` + CSP allows inline scripts — **Medium (documented)**

**Description.** `supabase-js` persists the session (access/refresh tokens) in `localStorage` by default, and the CSP uses `script-src 'self' 'unsafe-inline'`. If any XSS is ever introduced, tokens are directly stealable. Per VibeSec (JWT/XSS sections), tokens should live in `httpOnly`, `Secure`, `SameSite` cookies, and `'unsafe-inline'` should be dropped.

**Why not auto-fixed:** moving to cookie-based sessions requires adopting `@supabase/ssr` and a server session layer, and removing `'unsafe-inline'` requires refactoring the many inline `onclick`/`<script>` blocks to nonces/external files — a behavioral change beyond a safe in-place patch.
**Recommendation:** migrate auth to `@supabase/ssr` cookie sessions; introduce CSP nonces and remove `'unsafe-inline'`; keep JWT expiry short. Residual risk is bounded today because no XSS sink was found (user-controlled strings are escaped) and `frame-ancestors 'none'` + `X-Frame-Options: DENY` are set.

---

### F5 — Leaked password protection disabled — **Low (action required)**

Enable HaveIBeenPwned checking: **Dashboard → Authentication → Policies → "Leaked password protection" → On** (or via the Management API). Cannot be toggled through the MCP tools available in this session.

---

### F6 — `admin.html` inline `onclick` built with email in JS-string context — **Low (documented)**

`toggleRole('${u.id}','${u.role}','${esc(u.email)}')` HTML-escapes the email, but inside a quoted JS string in an attribute the browser decodes entities before the JS parser runs, so an apostrophe could in theory break out. **Not currently exploitable** (Supabase validates email format; the panel is admin-only). **Recommendation (VibeSec — context-correct encoding):** drop the inline `onclick` and use `data-*` attributes + `addEventListener`, or `JSON.stringify` the value for JS context.

---

### F7 — No rate limiting on `/api/redeem` — **Low (recommendation)**

A logged-in free user can submit promo codes without throttling (code-guessing/abuse). Mitigated by code entropy and the "already active" check, but add per-user/IP rate limiting (e.g. Upstash) on `redeem` and other expensive/auth endpoints.

---

## 3. Applied changes

**Database (production + staging) — `db/security_hardening_2026-06-14.sql`:** table-level `REVOKE` of client write access on `profiles`; `GRANT SELECT` to `authenticated`; dropped the client `profiles` UPDATE policy; all policies re-scoped `TO authenticated` with `USING` + `WITH CHECK`; `anon` removed from `user_data`; `EXECUTE` on `handle_new_user()` revoked from clients; all client grants on `promo_codes` revoked.

**Source files:**
- `db/schema.sql` — rewritten so it is now correct and re-runnable without re-introducing F1 (was the ineffective column-revoke; also removed an unused `SECURITY DEFINER` admin RPC).
- `db/security_hardening_2026-06-14.sql` — new, the exact applied migration with verification queries.

No application code change was required for the fixes (the frontend never writes `profiles`; server APIs use `service_role` and are unaffected). F4–F7 remain as documented recommendations.

---

## 4. Hardening checklist

- [x] **F1** profiles privilege escalation — table-level revoke, verified closed on prod & staging
- [x] **F2** handle_new_user public RPC — EXECUTE revoked, advisors cleared
- [x] **F3** promo_codes client grants — revoked
- [x] All RLS policies scoped `TO authenticated` with `USING`/`WITH CHECK`
- [x] `anon` stripped of all access to `profiles` and `user_data`
- [x] `service_role` confirmed absent from client bundles
- [x] `db/schema.sql` corrected (re-run no longer re-opens F1)
- [x] **F6** replaced inline `onclick` in `admin.html` with `data-*` + event delegation
- [x] **F7** added DB-backed atomic rate limiter (`rate_limits` + `bump_rate_limit`) on `/api/redeem` (8/user, 20/IP per 10 min)
- [x] **F8** added `Cross-Origin-Opener-Policy: same-origin-allow-popups` + `Cross-Origin-Resource-Policy: same-origin`
- [ ] **F5** enable leaked-password protection — owner action (requires Supabase **Pro** plan; advisor still reports disabled)
- [ ] **F4** migrate to cookie-based sessions + remove CSP `'unsafe-inline'` — planned refactor
- [ ] Confirm `DISABLE_AUTH` is **not** set in the production environment (staging-only flag)

### Residual notes
- The F7 limiter is fixed-window and **fails open** if the limiter call errors (so a limiter fault never blocks legitimate redemptions). For stricter guarantees use a sliding window / dedicated service (e.g. Upstash).
- F6 was not exploitable (Supabase validates email format; panel is admin-only); the refactor removes the fragile JS-string interpolation entirely.
