# ملخص الشات — ProfitLens SaaS

## المشروع
- **الريبو:** `omar-edrees/profitlens-saas`
- **Branch رئيسي:** `main`
- **Branch التطوير:** `claude/dazzling-brown-cgdh27`
- **Stack:** HTML/JS/CSS static + Vercel Serverless API + Supabase (Auth + DB)
- **Supabase Project:** `yyicjxbsbudfhgdslqff.supabase.co`

---

## اللي اتعمل في الشات ده

### 1. ترجمة كاملة للعربي
- نظام ترجمة `T = { en: {...}, ar: {...} }` مع `applyLang()`
- **379 key** في كل لغة — صفر ناقص
- كل الـ `data-t` attributes والـ `T[LANG].key` references اتتحقق منها
- إضافة `tfmt(key, ...args)` لـ template strings
- RTL layout عند تفعيل العربي (`dir="rtl"` على `<html>`)
- ترجمة الـ Excel export (كل الـ sheets والـ headers والـ labels)
- ترجمة الـ product ranking table والـ verdict strings
- استبدال كل `' EGP'` hardcoded بـ `' '+CURRENCY` في الـ JS

### 2. Security Hardening — API

**ملف: `api/admin/users.js`**
- ❌ كان بيعمل manual JWT decode بدون signature verification
- ✅ استبدلناه بـ `admin.auth.getUser(token)` — نفس الطريقة في باقي الـ files

**ملف: `api/redeem.js`**
- ❌ كان فيه race condition (TOCTOU) على الـ promo code — ممكن 100 أكونت يستخدموا code بـ max_uses=1
- ✅ Atomic optimistic-lock: `UPDATE WHERE uses_count = N` — بس الأول يعدي

**كل الـ API files:**
- ❌ `Access-Control-Allow-Origin: *` على كل endpoint
- ✅ شيلنا CORS headers كلها (الـ frontend والـ API على نفس الـ domain)

**`api/admin/users.js` PATCH:**
- ❌ كان بيعمل `upsert` — ممكن يخلق phantom profile rows
- ✅ غيّرناه لـ `update`

**`package.json`:**
- أضفنا `"type": "module"` وحوّلنا كل الـ API files من CJS لـ ESM

### 3. Security Headers — `vercel.json`
أضفنا:
- `X-Frame-Options: DENY` — يمنع clickjacking
- `X-Content-Type-Options: nosniff`
- `Strict-Transport-Security` (HSTS)
- `Referrer-Policy`
- `Permissions-Policy`
- `Content-Security-Policy` — يقيّد CDNs والـ connect-src
- `Cache-Control: no-store` على الـ API routes

### 4. Database RLS — Supabase
**ملف: `db/schema.sql`** (اتحدّث — لازم يتشغّل في Supabase SQL Editor)

المشكلة كانت:
- أي user يقدر يغير `plan` و`role` بتاعه مباشرة عبر Supabase REST API
- UPDATE policy بدون `WITH CHECK`

الإصلاح:
```sql
-- Lock billing columns
REVOKE UPDATE (role, plan) ON public.profiles FROM anon, authenticated;

-- Proper scoped policies with WITH CHECK
CREATE POLICY profiles_update_own ON public.profiles
  FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- admin_set_plan() RPC — الطريقة الوحيدة الآمنة لتغيير الplan
CREATE OR REPLACE FUNCTION public.admin_set_plan(target_email text, new_plan text) ...
```

**تم اختبار الـ fix:** الـ endpoint رجع `[]` من `about:blank` console بدون Bearer token ✅

### 5. Data Mixing Fix — `app.html`
- ❌ اليوزر الجديد كان ممكن يشوف بيانات اليوزر السابق على نفس الجهاز
- ✅ `localStorage.removeItem(LS_KEY)` عند logout وعند بداية كل session

### 6. Pricing Page — `pricing.html`
- السعر: **500 EGP** (من 1500 EGP) مع badge **-67%** أحمر
- badge أصفر **⏳ عرض لفترة محدودة** فوق السعر
- Feature list جديدة (9 features) بتعكس الـ tool الفعلية:
  1. تحليل ربحية كامل
  2. تحليل إعلانات متكامل — CPA, ROAS, Break-even
  3. تحليل شحن وتوصيل
  4. Target Profit Simulator
  5. Scale Detector
  6. مقارنة منتجات
  7. Overview شامل
  8. كل العملات
  9. بدون اشتراك شهري

---

## حاجة واحدة لسه محتاج تعملها يدوياً

**شغّل `db/schema.sql` في Supabase SQL Editor** كل مرة بتعمل تعديل على الـ schema.

---

## Vercel Setup
- Production Branch: `main`
- Environment Variables المطلوبة:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
  - `SUPABASE_SERVICE_ROLE_KEY`

---

## ملاحظات مهمة
- الـ anon key ظاهر في الكود — **ده طبيعي في Supabase** — الحماية الحقيقية هي الـ RLS
- Bearer tokens لا تبعتها في الشات — تغيّر بسرعة ومحتاجة invalidation
- لو غيّرت الأسعار، بس عدّل `PRICE_EGP` و`PRICE_ORIGINAL` في `pricing.html` والـ badge بيتحسب أوتوماتيك
