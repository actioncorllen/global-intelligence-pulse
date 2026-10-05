// Free-lane creative renderer v2 (post-founder-rejection craft pass). HTML/CSS/SVG -> Chromium PNG.
// NO paid provider. Materially more art-directed than v1 per founder feedback:
//  BOLD_SIGNAL: distinctive signal-detection (sonar) metaphor integrated with the typography.
//  EDITORIAL_INTELLIGENCE: sophisticated fine-line contour field mapping signal->momentum->action.
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const pw = require('/opt/node22/lib/node_modules/playwright');

const C = { bgDark:'#0B1020', ink:'#0A0F1E', cream:'#F7F4EC', cyan:'#22D3EE', teal:'#0E7490', neutral:'#6B7280' };
const COPY = { eyebrowBold:'GLOBAL INTELLIGENCE PLATFORM', eyebrowEd:'MARKET INTELLIGENCE',
  body:'Strateloq turns global change into opportunities you can act on.', cta:'Explore the product' };

// ---------- BOLD_SIGNAL: sonar signal-detection motif ----------
function boldSvg() {
  const cx=852, cy=610; let rings='';
  for (const r of [66,132,205,286,378,478]) {
    const op=(0.42 - r*0.00050).toFixed(3);
    rings += `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="#2BBBD6" stroke-width="1.4" opacity="${op}"/>`;
  }
  // scan wedge
  const wedge = `<path d="M${cx} ${cy} L${cx+520} ${cy-280} A590 590 0 0 1 ${cx+560} ${cy+150} Z" fill="url(#scan)" opacity="0.5"/>`;
  // signal node field (deterministic constellation) kept to the right half, dim
  let seed=11; const rnd=()=>{seed=(seed*1103515245+12345)&0x7fffffff; return seed/0x7fffffff;};
  let nodes='';
  for (let i=0;i<30;i++){
    const ang=rnd()*Math.PI*2, rad=70+rnd()*440;
    const x=cx+Math.cos(ang)*rad, y=cy+Math.sin(ang)*rad*0.9;
    if (x<560||y<250||x>1060||y>1040) continue;
    const s=1.6+rnd()*2.3, op=(0.18+rnd()*0.4).toFixed(2);
    nodes+=`<circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${s.toFixed(1)}" fill="#7FE9F7" opacity="${op}"/>`;
  }
  // the detected opportunity node (bright, glowing) + connector from the end of the headline ("action.")
  const nx=946, ny=452;
  const detected = `<line x1="398" y1="356" x2="${nx-15}" y2="${ny}" stroke="${C.cyan}" stroke-width="2" opacity="0.6" stroke-dasharray="2 8" stroke-linecap="round"/>
    <circle cx="${nx}" cy="${ny}" r="25" fill="none" stroke="${C.cyan}" stroke-width="2" opacity="0.5"/>
    <circle cx="${nx}" cy="${ny}" r="10" fill="${C.cyan}" filter="url(#glow)"/>
    <circle cx="${nx}" cy="${ny}" r="4.5" fill="#04121A"/>`;
  return `<svg width="1080" height="1080" viewBox="0 0 1080 1080" fill="none" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <radialGradient id="scan" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse"
         gradientTransform="translate(${cx} ${cy}) rotate(-28) scale(640)">
        <stop stop-color="${C.cyan}" stop-opacity="0.22"/><stop offset="1" stop-color="${C.cyan}" stop-opacity="0"/>
      </radialGradient>
      <filter id="glow" x="-120%" y="-120%" width="340%" height="340%"><feGaussianBlur stdDeviation="7" result="b"/>
        <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    </defs>
    ${wedge}${rings}${nodes}${detected}</svg>`;
}

const boldHTML = `<!doctype html><html><head><meta charset="utf-8"><style>
 *{margin:0;padding:0;box-sizing:border-box;-webkit-font-smoothing:antialiased}html,body{width:1080px;height:1080px}
 .stage{width:1080px;height:1080px;position:relative;overflow:hidden;
   background:radial-gradient(1300px 1000px at 72% 58%, #15233c 0%, ${C.bgDark} 52%, #05080f 100%);
   font-family:'Liberation Sans','Helvetica Neue',Arial,sans-serif;color:#EAF0FF}
 .art{position:absolute;inset:0}
 .pad{position:absolute;inset:86px}
 .eyebrow{font-size:22px;letter-spacing:6px;font-weight:700;color:${C.cyan};text-transform:uppercase}
 .brand{position:absolute;top:0;right:0;font-size:25px;letter-spacing:5px;font-weight:800;color:#9DB0CC}
 h1{position:absolute;top:150px;left:0;right:300px;font-size:80px;line-height:1.04;font-weight:800;letter-spacing:-2px;color:#FFFFFF}
 h1 .accent{color:${C.cyan}}
 .body{position:absolute;top:470px;left:0;right:560px;font-size:28px;line-height:1.45;color:#9AA7BD}
 .cta{position:absolute;bottom:0;left:0;display:inline-flex;align-items:center;gap:14px;background:${C.cyan};color:#04121A;font-weight:800;font-size:27px;padding:22px 34px;border-radius:999px}
 .tag{position:absolute;bottom:4px;right:0;font-size:16px;letter-spacing:3px;color:#56657F;text-transform:uppercase}
</style></head><body><div class="stage">
 <div class="art">${boldSvg()}</div>
 <div class="pad">
   <div class="eyebrow">${COPY.eyebrowBold}</div>
   <div class="brand">STRATELOQ</div>
   <h1>Turn market<br>signals into<br><span class="accent">action.</span></h1>
   <div class="body">${COPY.body}</div>
   <div class="cta">${COPY.cta} &#8594;</div>
   <div class="tag">Signal detected &rarr; Opportunity</div>
 </div></div></body></html>`;

// ---------- EDITORIAL_INTELLIGENCE: fine-line contour field, signal->momentum->action ----------
function edSvg() {
  // contour field (nested flowing isolines) in the right/lower region
  let contours='';
  for (let i=0;i<11;i++){
    const baseY=250+i*62, amp=26+i*3, ph=i*0.6;
    let d=`M60 ${baseY+Math.sin(ph)*amp}`;
    for (let x=60;x<=980;x+=40){
      const y=baseY+Math.sin((x/150)+ph)*amp - (x-60)*0.12;
      d+=` L${x} ${y.toFixed(1)}`;
    }
    const op=(0.16+i*0.028).toFixed(3);
    contours+=`<path d="${d}" fill="none" stroke="${C.teal}" stroke-width="1.1" opacity="${op}"/>`;
  }
  // rising highlighted path: signal -> momentum -> action (below the headline, strong movement)
  const p1=[150,732], p2=[486,604], p3=[828,478];
  const path=`<path d="M${p1[0]} ${p1[1]} C 300 706, 372 652, ${p2[0]} ${p2[1]} S 702 540, ${p3[0]} ${p3[1]}"
     fill="none" stroke="${C.teal}" stroke-width="3" stroke-linecap="round"/>`;
  const node=(x,y,hl)=> hl
    ? `<circle cx="${x}" cy="${y}" r="13" fill="${C.cream}" stroke="${C.teal}" stroke-width="3.5"/><circle cx="${x}" cy="${y}" r="4" fill="${C.teal}"/>`
    : `<circle cx="${x}" cy="${y}" r="6.5" fill="${C.teal}"/>`;
  const label=(x,y,t,anchor='middle')=>`<text x="${x}" y="${y}" font-family="'Liberation Sans',Arial,sans-serif" font-size="17" letter-spacing="3" fill="#6E7A86" text-anchor="${anchor}">${t}</text>`;
  return `<svg width="1080" height="1080" viewBox="0 0 1080 1080" fill="none" xmlns="http://www.w3.org/2000/svg">
    ${contours}${path}
    ${node(p1[0],p1[1],false)}${node(p2[0],p2[1],false)}${node(p3[0],p3[1],true)}
    ${label(p1[0],p1[1]+34,'SIGNAL','middle')}${label(p2[0],p2[1]+34,'MOMENTUM','middle')}${label(p3[0]+6,p3[1]-26,'ACTION','start')}
  </svg>`;
}

const edHTML = `<!doctype html><html><head><meta charset="utf-8"><style>
 *{margin:0;padding:0;box-sizing:border-box;-webkit-font-smoothing:antialiased}html,body{width:1080px;height:1080px}
 .stage{width:1080px;height:1080px;position:relative;overflow:hidden;background:
   linear-gradient(180deg,#FAF8F1 0%, ${C.cream} 100%);font-family:'Liberation Sans',Arial,sans-serif;color:${C.ink}}
 .art{position:absolute;inset:0}
 .pad{position:absolute;inset:92px}
 .eyebrow{font-size:21px;letter-spacing:7px;font-weight:700;color:${C.teal};text-transform:uppercase}
 .brand{position:absolute;top:-2px;right:0;font-size:24px;letter-spacing:.5px;font-weight:700;color:#5A6472;font-family:'Liberation Serif',Georgia,serif}
 h1{position:absolute;top:138px;left:0;right:150px;font-family:'Liberation Serif',Georgia,'Times New Roman',serif;font-size:98px;line-height:1.04;font-weight:700;letter-spacing:-1px;color:${C.ink}}
 .rule{position:absolute;top:430px;left:0;width:84px;height:3px;background:${C.teal}}
 .body{position:absolute;top:462px;left:0;right:560px;font-size:28px;line-height:1.5;color:#3C4654}
 .idx{position:absolute;top:462px;right:8px;width:150px;text-align:right;font-family:'Liberation Serif',Georgia,serif;color:#8A94A0;font-size:18px;line-height:1.9}
 .idx b{color:${C.teal};font-weight:700}
 .cta{position:absolute;bottom:0;left:0;font-size:27px;font-weight:700;color:${C.teal};border-bottom:3px solid ${C.teal};padding-bottom:6px}
</style></head><body><div class="stage">
 <div class="art">${edSvg()}</div>
 <div class="pad">
   <div class="eyebrow">${COPY.eyebrowEd}</div>
   <div class="brand">Strateloq</div>
   <h1>Turn market signals into action</h1>
   <div class="rule"></div>
   <div class="body">${COPY.body}</div>
   <div class="cta">${COPY.cta} &#8594;</div>
 </div></div></body></html>`;

const OUT='./out_creatives_v2'; mkdirSync(OUT,{recursive:true});
async function render(label, html){
  const b=await pw.chromium.launch({headless:true,executablePath:'/opt/pw-browsers/chromium',args:['--no-sandbox','--disable-dev-shm-usage','--force-color-profile=srgb']});
  try{ const ctx=await b.newContext({viewport:{width:1080,height:1080},deviceScaleFactor:1}); const pg=await ctx.newPage();
    await pg.setContent(html,{waitUntil:'load'}); await pg.waitForTimeout(250);
    const buf=await pg.screenshot({type:'png'}); writeFileSync(`${OUT}/${label}.png`,buf);
    console.log(JSON.stringify({label,bytes:buf.length})); } finally { await b.close(); }
}
await render('BOLD_SIGNAL', boldHTML);
await render('EDITORIAL_INTELLIGENCE', edHTML);
