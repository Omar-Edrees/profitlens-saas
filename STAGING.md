# بيئات المشروع (Production / Staging)

توثيق إعداد بيئة التجربة (Staging) المعزولة عن اللايف (Production) لمشروع **ProfitLens SaaS**.

## نظرة عامة

```
الفرع (Branch)        البيئة على Vercel        قاعدة البيانات (Supabase)
main                  Production (اللايف)       profitlens-saas    (yyicjxbsbudfhgdslqff)
profitlens-testing    Preview   (التجربة)        profitlens-staging (vrpsjonnsgfhwdmvrsrx)
```

- **main** هو الفرع الافتراضي وبيتنشر تلقائياً كـ Production على Vercel.
- **profitlens-testing** هو فرع التجربة وبيتنشر كـ Preview، وبيتوصّل على قاعدة بيانات تجربة منفصلة تماماً.
- بيانات العملاء الحقيقية موجودة في اللايف فقط؛ التجربة فيها بيانات وهمية.

## المتغيرات (Environment Variables) على Vercel

| المتغير | نطاق Production | نطاق Preview (profitlens-testing) |
|---------|-----------------|-----------------------------------|
| `SUPABASE_URL` | مشروع اللايف | `https://vrpsjonnsgfhwdmvrsrx.supabase.co` |
| `SUPABASE_ANON_KEY` | مفتاح اللايف | مفتاح anon بتاع التجربة |
| `SUPABASE_SERVICE_ROLE_KEY` | مفتاح اللايف | secret key بتاع التجربة |

> مفاتيح اللايف نطاقها **Production فقط**، ومفاتيح التجربة نطاقها **Preview فقط** — عشان الفصل الكامل بين البيئتين.

## طريقة الشغل اليومية

1. اشتغل وعدّل على فرع `profitlens-testing`.
2. ارفع الفرع → Vercel يطلّع رابط Preview شغّال على قاعدة بيانات التجربة.
3. جرّب كل حاجة على رابط الـ Preview.
4. لو كله تمام → ادمج (merge) من `profitlens-testing` إلى `main` → اللايف يتحدّث تلقائياً.

## تعديلات قاعدة البيانات (Schema)

البيانات نفسها لا تنتقل بين البيئتين — اللي بينتقل هو **تركيب الجداول** فقط:

1. اكتب أي تعديل كملف SQL داخل فولدر `db/`.
2. طبّقه أولاً على قاعدة بيانات التجربة (`profitlens-staging`) وجرّب.
3. لمّا يبقى تمام، طبّق **نفس الـ SQL بالظبط** على قاعدة بيانات اللايف (`profitlens-saas`) وقت الدمج.

## استرجاع (Rollback) عند حدوث مشكلة في اللايف

- **الكود:** من Vercel → Deployments → اختر آخر نسخة مستقرة → **Instant Rollback**.
- **قاعدة البيانات:** من Supabase → Database → Backups (نسخ يومية على الخطة المجانية).
