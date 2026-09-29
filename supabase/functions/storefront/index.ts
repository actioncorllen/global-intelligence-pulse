// PULSE-ECOM-P8-PULSE-HOSTED-PUBLIC-ENDPOINT-DEPLOY-001 + HTML-RENDER-FIX-001 + STOREFRONT-FINAL-ACCEPTANCE-001 + CORS-ACTIVATION-008 + PUBLISHED-PARITY-009 + HTML-CONTENT-TYPE-FIX-010
// HTML-CONTENT-TYPE-FIX-010: the deployed GET response served Content-Type: text/plain
// (with X-Content-Type-Options: nosniff), so Chrome showed the HTML as raw source instead of
// rendering it. Cause: headers passed as a plain object let the edge relay keep the string
// body's default text/plain. Fixed by building an explicit Headers instance (buildHeaders) and
// hard-setting Content-Type: text/html; charset=utf-8 on the GET/HTML response.
// Thin, read-only public storefront HTTP endpoint:
//   HTTP request -> validate slug -> invoke public-safe renderer -> render -> respond.
// Exposes ONLY PUBLISHED storefronts via fn_public_storefront_render(slug) (allowlist-only,
// secret-stripped). Service-role key is used ONLY server-side and NEVER returned to the browser.
// No directory/list endpoint, no enumeration, no checkout. Unknown/unpublished/invalid slug -> 404.
// v5 (008): CORS + OPTIONS added so a frontend host (Strateloq/Lovable app) can fetch the public
// JSON contract cross-origin. This is a PUBLIC read-only endpoint returning only published,
// secret-stripped data (no credentials/cookies); publish/unpublish stay authenticated RPCs.
// PUBLISHED-PARITY-009: a genuinely PUBLISHED customer page no longer shows an internal
// "test listing / preview storefront" banner (noindex is enforced via HTTP headers + meta only).
// Removed the hardcoded "New condition / delivery estimates" footer claim; the page shows only
// claim-safe copy present in the approved published snapshot (fn_product_page_strategy v3 parity),
// plus the approved Overview (problem/solution) and Product details sections. Checkout stays a safe
// disabled "coming soon" state.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SECURITY_HEADERS: Record<string, string> = {
  "X-Robots-Tag": "noindex, nofollow",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "public, max-age=60",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, accept",
  "Access-Control-Max-Age": "86400",
};
const HTML_CT = "text/html; charset=utf-8";
const JSON_CT = "application/json; charset=utf-8";

// Build response headers as an explicit Headers instance and set Content-Type LAST.
// Passing a plain object to `new Response(body, { headers })` let the edge relay serve the
// string body as text/plain (browser then refuses to render HTML under X-Content-Type-Options:
// nosniff and shows raw source). An explicit Headers object with a hard-set Content-Type is
// preserved end-to-end.
function buildHeaders(contentType?: string): Headers {
  const h = new Headers();
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) h.set(k, v);
  if (contentType) h.set("Content-Type", contentType);
  return h;
}

function x(s: unknown): string {
  const str = String(s ?? "");
  let out = "";
  for (const ch of str) {
    const c = ch.codePointAt(0)!;
    if (ch === "&") out += "&amp;";
    else if (ch === "<") out += "&lt;";
    else if (ch === ">") out += "&gt;";
    else if (ch === '"') out += "&quot;";
    else if (ch === "'") out += "&#39;";
    else if (c > 126) out += "&#" + c + ";";
    else out += ch;
  }
  return out;
}

function htmlResponse(bodyInner: string, status: number, title: string): Response {
  const doc =
    `<!DOCTYPE html>\n` +
    `<html lang="en">\n<head>\n` +
    `<meta charset="utf-8" />\n` +
    `<meta name="robots" content="noindex,nofollow" />\n` +
    `<meta name="viewport" content="width=device-width, initial-scale=1" />\n` +
    `<title>${title}</title>\n` +
    STYLE +
    `</head>\n<body>\n${bodyInner}\n</body>\n</html>\n`;
  return new Response(doc, {
    status,
    headers: buildHeaders(HTML_CT),
  });
}

const STYLE =
  `<style>/*<![CDATA[*/\n` +
  `:root{--fg:#111827;--muted:#4b5563;--line:#e5e7eb;--bg:#ffffff}\n` +
  `*{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:var(--fg);background:var(--bg);line-height:1.5}\n` +
  `.wrap{max-width:960px;margin:0 auto;padding:16px}\n` +
  `.draftbar{background:#fef3c7;color:#92400e;font-size:13px;padding:8px 16px;text-align:center}\n` +
  `h1{font-size:1.6rem;margin:.4em 0} h2{font-size:1.15rem;margin:1.4em 0 .5em}\n` +
  `.hero-sub{color:var(--muted)} .grid{display:grid;gap:16px;grid-template-columns:1fr}\n` +
  `@media(min-width:760px){.grid{grid-template-columns:1fr 1fr}}\n` +
  `.gallery img{width:100%;border:1px solid var(--line);border-radius:10px;margin-bottom:10px;aspect-ratio:1/1;object-fit:cover}\n` +
  `.videowrap{margin:12px 0} .videowrap video{width:100%;max-width:100%;border:1px solid var(--line);border-radius:10px;background:#000;display:block}\n` +
  `.price{font-size:1.5rem;font-weight:700}\n` +
  `ul{padding-left:1.1em} .muted{color:var(--muted);font-size:.9rem}\n` +
  `.cta{display:inline-block;margin-top:12px;padding:12px 18px;border-radius:10px;background:#9ca3af;color:#fff;font-weight:600;border:0;cursor:not-allowed}\n` +
  `.note{background:#f3f4f6;border:1px solid var(--line);border-radius:10px;padding:12px;margin-top:12px;font-size:.9rem;color:var(--muted)}\n` +
  `table.details{border-collapse:collapse;width:100%;margin-top:6px} table.details th,table.details td{text-align:left;vertical-align:top;padding:6px 10px;border-bottom:1px solid var(--line);font-size:.92rem} table.details th{color:var(--muted);font-weight:600;width:40%}\n` +
  `footer{margin:28px 0;color:var(--muted);font-size:.8rem;border-top:1px solid var(--line);padding-top:12px}\n` +
  `/*]]>*/</style>\n`;

function notFound(): Response {
  return htmlResponse(
    `<div class="wrap"><h1>404 &#8212; Not found</h1><p>No published storefront exists at this address.</p></div>`,
    404, "Not found",
  );
}

function renderHtml(sf: any): string {
  const cur = x(sf?.offer?.currency ?? sf?.currency?.display ?? "");
  const price = sf?.offer?.price != null ? `${cur} ${x(sf.offer.price)}` : "";
  const gallery: string[] = Array.isArray(sf?.assets?.gallery) ? sf.assets.gallery : [];
  const primary = sf?.assets?.primary_image ?? gallery[0] ?? null;
  const benefits: string[] = Array.isArray(sf?.copy?.benefits) ? sf.copy.benefits : [];
  const how: string[] = Array.isArray(sf?.copy?.how_it_works) ? sf.copy.how_it_works : [];
  const faq: any[] = Array.isArray(sf?.copy?.faq) ? sf.copy.faq : [];
  const disclaimers: string[] = Array.isArray(sf?.copy?.trust?.disclaimers) ? sf.copy.trust.disclaimers : [];
  const title = x(sf?.copy?.product_title ?? sf?.hero?.headline ?? "Product");
  const psProblem = typeof sf?.copy?.problem_solution?.problem === "string" ? sf.copy.problem_solution.problem : "";
  const psSolution = typeof sf?.copy?.problem_solution?.solution === "string" ? sf.copy.problem_solution.solution : "";
  const details: any[] = Array.isArray(sf?.copy?.details) ? sf.copy.details : [];

  let galleryHtml = primary
    ? `<img src="${x(primary)}" alt="${title}" loading="lazy" />`
    : `<div class="note">No product image available.</div>`;
  for (const g of gallery.slice(1, 5)) galleryHtml += `<img src="${x(g)}" alt="${title}" loading="lazy" />`;

  // PRODUCT_VIDEO: only rendered when a real, rights-clear video exists (state VIDEO_AVAILABLE).
  let videoHtml = "";
  if (sf?.video?.state === "VIDEO_AVAILABLE" && sf?.video?.url) {
    const posterAttr = primary ? ` poster="${x(primary)}"` : "";
    const originKind = sf?.video?.origin_kind === "GENERATED" ? "Generated creative" : "Supplier-provided";
    videoHtml =
      `<div class="videowrap">` +
      `<video controls muted playsinline preload="metadata"${posterAttr}>` +
      `<source src="${x(sf.video.url)}" />` +
      `Your browser does not support embedded video.` +
      `</video>` +
      `<p class="muted">Product video &#183; ${x(originKind)}. Autoplay off; press play to watch.</p>` +
      `</div>`;
  }

  let benefitsHtml = "";
  if (benefits.length) {
    let li = "";
    for (const b of benefits) li += `<li>${x(b)}</li>`;
    benefitsHtml = `<h2>Highlights</h2><ul>${li}</ul>`;
  }
  let howHtml = "";
  if (how.length) {
    let li = "";
    for (const h of how) li += `<li>${x(h)}</li>`;
    howHtml = `<h2>How it works</h2><ol>${li}</ol>`;
  }
  let faqHtml = "";
  if (faq.length) {
    let ps = "";
    for (const f of faq) ps += `<p><strong>${x(f?.q)}</strong><br />${x(f?.a)}</p>`;
    faqHtml = `<h2>FAQ</h2>${ps}`;
  }
  let discHtml = "";
  if (disclaimers.length) {
    let li = "";
    for (const d of disclaimers) li += `<li>${x(d)}</li>`;
    discHtml = `<ul class="muted">${li}</ul>`;
  }
  // Overview (problem/solution) — factual, from the approved snapshot only.
  let overviewHtml = "";
  if (psProblem || psSolution) {
    overviewHtml = `<h2>Overview</h2>` +
      (psProblem ? `<p>${x(psProblem)}</p>` : "") +
      (psSolution ? `<p>${x(psSolution)}</p>` : "");
  }
  // Product details table — label/value pairs from the approved snapshot only.
  let detailsHtml = "";
  if (details.length) {
    let rows = "";
    for (const d of details) {
      if (d?.label == null && d?.value == null) continue;
      rows += `<tr><th>${x(d?.label)}</th><td>${x(d?.value)}</td></tr>`;
    }
    if (rows) detailsHtml = `<h2>Product details</h2><table class="details">${rows}</table>`;
  }

  return `<div class="wrap">
  <h1>${x(sf?.hero?.headline ?? title)}</h1>
  ${sf?.hero?.subheadline ? `<p class="hero-sub">${x(sf.hero.subheadline)}</p>` : ""}
  <div class="grid">
    <div class="gallery">${galleryHtml}${videoHtml}</div>
    <div>
      ${price ? `<div class="price">${price}</div>` : ""}
      ${sf?.copy?.short_description ? `<p>${x(sf.copy.short_description)}</p>` : ""}
      ${benefitsHtml}
      <button class="cta" disabled="disabled" aria-disabled="true">Checkout coming soon</button>
      <div class="note">Checkout is not yet available for this store (no payment provider connected). No purchase can be made.</div>
    </div>
  </div>
  ${overviewHtml}
  ${detailsHtml}
  ${howHtml}
  ${sf?.copy?.shipping?.copy ? `<h2>Shipping</h2><p>${x(sf.copy.shipping.copy)}</p>` : ""}
  ${sf?.copy?.trust?.copy ? `<h2>About this listing</h2><p>${x(sf.copy.trust.copy)}</p>` : ""}
  ${discHtml}
  ${faqHtml}
  <footer>Market: ${x(sf?.market ?? "")} &#183; Currency: ${x(sf?.currency?.display ?? "")} &#183; Template: ${x(sf?.template_family ?? "")} ${x(sf?.template_version ?? "")}</footer>
</div>`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: buildHeaders() });
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: buildHeaders("text/plain; charset=utf-8") });
  }
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf("storefront");
  const slug = idx >= 0 && parts.length > idx + 1 ? parts[idx + 1] : "";
  if (!slug || !/^[A-Za-z0-9_-]{4,64}$/.test(slug)) return notFound();

  let body: any;
  try {
    const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_public_storefront_render`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": SERVICE_ROLE,
        "Authorization": `Bearer ${SERVICE_ROLE}`,
      },
      body: JSON.stringify({ p_slug: slug }),
    });
    if (!resp.ok) return notFound();
    body = await resp.json();
  } catch (_e) {
    return new Response("Service unavailable", { status: 503, headers: buildHeaders("text/plain; charset=utf-8") });
  }

  if (!body || body.status !== "OK" || !body.storefront) return notFound();

  const wantsJson = url.searchParams.get("format") === "json" ||
    (req.headers.get("accept") ?? "").includes("application/json");
  if (wantsJson) {
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: buildHeaders(JSON_CT),
    });
  }
  return htmlResponse(
    renderHtml(body.storefront),
    200,
    x(body.storefront?.copy?.seo?.title ?? body.storefront?.copy?.product_title ?? "Storefront"),
  );
});
