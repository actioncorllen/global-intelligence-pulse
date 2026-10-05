// Free-lane creative renderer: composes a design-family creative from the mig_349 generation
// contract + Brand DNA and renders it to a real 1080x1080 PNG via Playwright Chromium.
// NO paid provider (this is the free/deterministic render lane; the paid Gemini lane is NOT run).
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const pw = require('/opt/node22/lib/node_modules/playwright');

const C = { bgDark:'#0B1020', ink:'#0A0F1E', cream:'#F7F4EC', cyan:'#22D3EE', teal:'#0E7490', neutral:'#6B7280' };
const COPY = {
  eyebrowBold:'GLOBAL INTELLIGENCE PLATFORM',
  eyebrowEd:'MARKET INTELLIGENCE',
  headline:'Turn market signals into action',
  body:'Strateloq turns global change into opportunities you can act on.',
  cta:'Explore the product',
  brand:'STRATELOQ',
};

// BOLD_SIGNAL — dark premium, oversized headline, restrained cyan, minimal signal motif, one CTA.
const boldHTML = `<!doctype html><html><head><meta charset="utf-8"><style>
 *{margin:0;padding:0;box-sizing:border-box;-webkit-font-smoothing:antialiased}
 html,body{width:1080px;height:1080px}
 .stage{width:1080px;height:1080px;position:relative;overflow:hidden;
   background:radial-gradient(1200px 900px at 78% 18%, #142036 0%, ${C.bgDark} 55%, #070B16 100%);
   font-family:'Liberation Sans','Helvetica Neue',Arial,sans-serif;color:#EAF0FF}
 .pad{position:absolute;inset:86px}
 .eyebrow{font-size:22px;letter-spacing:6px;font-weight:700;color:${C.cyan};text-transform:uppercase}
 .brand{position:absolute;top:0;right:0;font-size:26px;letter-spacing:5px;font-weight:800;color:#AEB8CC}
 h1{position:absolute;top:150px;left:0;right:120px;font-size:112px;line-height:1.02;font-weight:800;
   letter-spacing:-2px;color:#FFFFFF}
 h1 .accent{color:${C.cyan}}
 .body{position:absolute;top:560px;left:0;right:300px;font-size:30px;line-height:1.45;color:#9AA7BD;font-weight:400}
 .cta{position:absolute;bottom:0;left:0;display:inline-flex;align-items:center;gap:14px;
   background:${C.cyan};color:#04121A;font-weight:800;font-size:28px;padding:22px 34px;border-radius:999px}
 .cta .arr{font-size:30px}
 .signal{position:absolute;right:76px;bottom:150px}
 .tick{position:absolute;bottom:150px;left:0;right:0;height:1px;background:linear-gradient(90deg,transparent,rgba(255,255,255,.08),transparent)}
</style></head><body>
 <div class="stage"><div class="pad">
   <div class="eyebrow">${COPY.eyebrowBold}</div>
   <div class="brand">${COPY.brand}</div>
   <h1>Turn market<br>signals into <span class="accent">action.</span></h1>
   <div class="body">${COPY.body}</div>
   <div class="tick"></div>
   <svg class="signal" width="360" height="190" viewBox="0 0 360 190" fill="none">
     <g opacity="0.9">
       <rect x="0"   y="130" width="34" height="60"  rx="4" fill="#223049"/>
       <rect x="54"  y="104" width="34" height="86"  rx="4" fill="#2A3C5C"/>
       <rect x="108" y="78"  width="34" height="112" rx="4" fill="#33507A"/>
       <rect x="162" y="52"  width="34" height="138" rx="4" fill="#3E67A0"/>
       <rect x="216" y="30"  width="34" height="160" rx="4" fill="${C.teal}"/>
       <rect x="270" y="10"  width="34" height="180" rx="4" fill="${C.cyan}"/>
     </g>
     <path d="M17 150 L71 128 L125 100 L179 70 L233 46 L287 22" stroke="${C.cyan}" stroke-width="4"
       fill="none" stroke-linecap="round" stroke-linejoin="round"/>
     <circle cx="287" cy="22" r="9" fill="#04121A" stroke="${C.cyan}" stroke-width="4"/>
   </svg>
   <div class="cta">${COPY.cta}<span class="arr">&#8594;</span></div>
 </div></div>
</body></html>`;

// EDITORIAL_INTELLIGENCE — warm cream, sophisticated serif headline, restrained dark teal fine-line
// intelligence illustration, generous whitespace, understated CTA.
const edHTML = `<!doctype html><html><head><meta charset="utf-8"><style>
 *{margin:0;padding:0;box-sizing:border-box;-webkit-font-smoothing:antialiased}
 html,body{width:1080px;height:1080px}
 .stage{width:1080px;height:1080px;position:relative;overflow:hidden;background:${C.cream};
   font-family:'Liberation Sans',Arial,sans-serif;color:${C.ink}}
 .pad{position:absolute;inset:92px}
 .eyebrow{font-size:21px;letter-spacing:7px;font-weight:700;color:${C.teal};text-transform:uppercase}
 .brand{position:absolute;top:0;right:0;font-size:24px;letter-spacing:1px;font-weight:700;color:#5A6472;font-family:'Liberation Serif',Georgia,serif}
 h1{position:absolute;top:150px;left:0;right:90px;font-family:'Liberation Serif',Georgia,'Times New Roman',serif;
   font-size:104px;line-height:1.05;font-weight:700;letter-spacing:-1px;color:${C.ink}}
 .rule{position:absolute;top:470px;left:0;width:96px;height:4px;background:${C.teal}}
 .body{position:absolute;top:510px;left:0;right:360px;font-size:30px;line-height:1.5;color:#3C4654;font-weight:400}
 .cta{position:absolute;bottom:0;left:0;font-size:28px;font-weight:700;color:${C.teal};
   border-bottom:3px solid ${C.teal};padding-bottom:6px}
 .illus{position:absolute;right:70px;bottom:150px}
</style></head><body>
 <div class="stage"><div class="pad">
   <div class="eyebrow">${COPY.eyebrowEd}</div>
   <div class="brand">Strateloq</div>
   <h1>Turn market signals into action</h1>
   <div class="rule"></div>
   <div class="body">${COPY.body}</div>
   <svg class="illus" width="300" height="300" viewBox="0 0 300 300" fill="none" stroke="${C.teal}">
     <circle cx="150" cy="150" r="120" stroke-width="1.5" opacity="0.55"/>
     <ellipse cx="150" cy="150" rx="120" ry="46" stroke-width="1.5" opacity="0.5"/>
     <ellipse cx="150" cy="150" rx="46" ry="120" stroke-width="1.5" opacity="0.5"/>
     <path d="M30 150 H270 M150 30 V270" stroke-width="1" opacity="0.3"/>
     <polyline points="54,196 102,170 150,150 198,120 246,84" stroke-width="3" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
     <circle cx="54"  cy="196" r="6" fill="${C.teal}" stroke="none"/>
     <circle cx="150" cy="150" r="6" fill="${C.teal}" stroke="none"/>
     <circle cx="246" cy="84"  r="9" fill="${C.cream}" stroke-width="3"/>
   </svg>
   <div class="cta">${COPY.cta} &#8594;</div>
 </div></div>
</body></html>`;

const OUT = './out_creatives';
mkdirSync(OUT, { recursive: true });

async function render(label, html) {
  const browser = await pw.chromium.launch({ headless:true, executablePath:'/opt/pw-browsers/chromium',
    args:['--no-sandbox','--disable-dev-shm-usage','--force-color-profile=srgb'] });
  try {
    const ctx = await browser.newContext({ viewport:{ width:1080, height:1080 }, deviceScaleFactor:1 });
    const page = await ctx.newPage();
    await page.setContent(html, { waitUntil:'load' });
    await page.waitForTimeout(250);
    const buf = await page.screenshot({ type:'png' });
    const p = `${OUT}/${label}.png`;
    writeFileSync(p, buf);
    console.log(JSON.stringify({ label, bytes: buf.length, path: p }));
  } finally { await browser.close(); }
}

await render('BOLD_SIGNAL', boldHTML);
await render('EDITORIAL_INTELLIGENCE', edHTML);
