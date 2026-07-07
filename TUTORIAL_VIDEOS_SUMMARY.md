# ملخص شات "فيديوهات شرح التول" — ProfitLens

> ده ملخص لجلسة واحدة محددة (مش كل تاريخ المشروع). اقرأه لو بتكمل شغل فيديوهات الشرح في شات جديد.

## الهدف
حط فيديوهات شرح (Tutorial) جوه التول (`app.html`) من غير ما تبطّئ الصفحة، وبميزانية مجانية.

## الحل اللي اتنفذ
- زرار جديد اسمه **"شرح التول"** ضيفناه في منيو البروفايل (جنب الفيدباك و"رسائلي").
- بيفتح **modal** فيه قايمة فيديوهات.
- **Lazy load / facade pattern**: أول ما الـ modal يفتح، بيظهر بس **thumbnail** الفيديو (صورة من يوتيوب) + زرار Play. الفيديو (iframe) نفسه **مبيتحملش خالص** غير لما المستخدم يدوس عليه. يعني الصفحة الأساسية والمنيو مش بيتأثروا بالفيديوهات خالص.
- الاستضافة: **YouTube (Unlisted)** — مجاني تمامًا، وبرضه مش هيظهر في نتائج البحث أو في القناة العامة، بس أي حد معاه الرابط (أو الـ ID) يقدر يشغّله جوه التول.

## الملفات اللي اتعدّلت
كل التعديلات في ملف واحد: **`app.html`**

### 1. CSS (بعد سطر `.mymsg-lightbox-close:hover`)
كلاسات جديدة كلها بادئة `.tut-`:
`.tut-overlay`, `.tut-modal`, `.tut-head`, `.tut-body`, `.tut-item`, `.tut-player-wrap`, `.tut-play-btn`, `.tut-empty` … إلخ.

### 2. الترجمة (`T.en` و`T.ar`)
مفاتيح جديدة:
```js
tut_btn, tut_title, tut_empty, tut_empty_sub
```
(قيمة `tut_btn` بالعربي = "شرح التول")

### 3. زرار المنيو
`tutorialItem` جوه بناء الـ profile menu — بيستدعي `tutOpen()`.

### 4. JavaScript — قسم "TUTORIAL VIDEOS" (قبل قسم "MY MESSAGES")
- **`TUT_VIDEOS`** ← ⭐ **ده المكان اللي محتاج تتعدّل لما الفيديوهات تتحمّل على يوتيوب**:
  ```js
  const TUT_VIDEOS = [
    // { id:'dQw4w9WgXcQ', title_ar:'إزاي تبدأ مع التول', title_en:'Getting started' },
  ];
  ```
  لسه فاضي (array فاضي) → عشان كده الـ modal دلوقتي بيظهر رسالة "لسه مفيش فيديوهات شرح".
- `tutOpen()` / `tutClose()` / `tutPlay(wrap)` — فتح/قفل الـ modal وتشغيل الفيديو عند الضغط بس.
- الفيديو بيتشغل بـ `youtube-nocookie.com/embed/...` (نسخة يوتيوب الأخف على الخصوصية).

### 5. HTML — الـ overlay نفسه
جنب `mymsg-overlay` — `<div class="tut-overlay" id="tut_overlay">...</div>`.

## Git / Branch
- الشغل كله على البرانش: **`claude/embed-tutorial-videos-78rdva`**
- Push للبرانش ده: ✅ تم
- زامنّاه (fast-forward) مع **`profitlens-testing`**: ✅ تم (زي قاعدة الـ CLAUDE.md)
- **`main` متغيّرش خالص** (زي القاعدة — محتاج مراجعة يدوية بعدين)
- آخر commit: `feat: add tutorial videos modal under profile menu`

## اللوجو
- اتصدّر لوجو ProfitLens (نفس تصميم `favicon.svg`) بصيغة PNG بجودة 800×800 وبعتناه للمستخدم يستخدمه كصورة قناة يوتيوب.

## قناة اليوتيوب
- اتعملت قناة يوتيوب Brand Account باسم **ProfitLens**
- المعرّف: **`@ProfitLens-h1w`**
- لسه محتاجة: رفع اللوجو كصورة قناة (كانت لسه شايلة الصورة الافتراضية بحرف "P").

## الخطوة الجاية (لما تفتح شات جديد كمّل من هنا)
1. رفع الفيديوهات على قناة `@ProfitLens-h1w` كـ **Unlisted** (مش Public ولا Private).
2. لكل فيديو: هات الرابط (`youtube.com/watch?v=XXXXXXXXXXX`) والـ **ID** (اللي بعد `v=`).
3. ضيف كل فيديو كـ entry جوه `TUT_VIDEOS` في `app.html`:
   ```js
   { id:'XXXXXXXXXXX', title_ar:'عنوان الفيديو بالعربي', title_en:'Video title in English' },
   ```
4. Commit + push على `claude/embed-tutorial-videos-78rdva` (أو أي برانش جديد)، وزامن مع `profitlens-testing`.
5. اختبار سريع: افتح التول → منيو البروفايل → "شرح التول" → اتأكد إن الفيديو بيشتغل صح والـ thumbnail بيظهر.
