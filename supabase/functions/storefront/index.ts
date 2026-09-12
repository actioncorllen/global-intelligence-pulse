// PULSE-ECOM-P8-PULSE-HOSTED-PUBLIC-ENDPOINT-DEPLOY-001
// Thin, read-only public storefront HTTP endpoint. It does exactly:
//   HTTP request -> validate slug -> invoke public-safe renderer -> render -> respond.
// It exposes ONLY PUBLISHED storefronts via fn_public_storefront_render(slug), which
// is itself allowlist-only and secret-stripped. The service-role key is used ONLY
// server-side to call the RPC and is NEVER returned to the browser. No directory/list
// endpoint, no enumeration, no checkout. Unknown/unpublished/invalid slug -> 404.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SECURITY_HEADERS: Record<string, string> = {
  "X-Robots-Tag": "noindex, nofollow",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "public, max-age=60",
};

function esc(s: unknown): string {
  return String(s ?? "")
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function notFound(): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="robots" content="noindex, nofollow">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>Not found</title></head><body style="font-family:system-ui;padding:2rem">` +
    `<h1>404 — Not found</h1><p>No published storefront exists at this address.</p></body></html>`,
    { status: 404, headers: { ...SECURITY_HEADERS, "Content-Type": "text/html; charset=utf-8" } },
  );
}

function renderHtml(sf: any): string {
  const cur = esc(sf?.offer?.currency ?? sf?.currency?.display ?? "");
  const price = sf?.offer?.price != null ? `${cur} ${esc(sf.offer.price)}` : "";
  const gallery: string[] = Array.isArray(sf?.assets?.gallery) ? sf.assets.gallery : [];
  const primary = sf?.assets?.primary_image ?? gallery[0] ?? null;
  const benefits: string[] = Array.isArray(sf?.copy?.benefits) ? sf.copy.benefits : [];
  const how: string[] = Array.isArray(sf?.copy?.how_it_works) ? sf.copy.how_it_works : [];
  const faq: any[] = Array.isArray(sf?.copy?.faq) ? sf.copy.faq : [];
  const disclaimers: string[] = Array.isArray(sf?.copy?.trust?.disclaimers) ? sf.copy.trust.disclaimers : [];
  const title = esc(sf?.copy?.product_title ?? sf?.hero?.headline ?? "Product");

  return `<!doctype html><html lang="en"><head>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(sf?.copy?.seo?.title ?? title)}</title>
<meta name="description" content="${esc(sf?.copy?.seo?.meta_description ?? "")}">
<style>
  :root{--fg:#111827;--muted:#4b5563;--line:#e5e7eb;--accent:#2563eb;--bg:#ffffff}
  *{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:var(--fg);background:var(--bg);line-height:1.5}
  .wrap{max-width:960px;margin:0 auto;padding:16px}
  .draftbar{background:#fef3c7;color:#92400e;font-size:13px;padding:8px 16px;text-align:center}
  h1{font-size:1.6rem;margin:.4em 0} h2{font-size:1.15rem;margin:1.4em 0 .5em}
  .hero-sub{color:var(--muted)} .grid{display:grid;gap:16px;grid-template-columns:1fr}
  @media(min-width:760px){.grid{grid-template-columns:1fr 1fr}}
  .gallery img{width:100%;border:1px solid var(--line);border-radius:10px;margin-bottom:10px;aspect-ratio:1/1;object-fit:cover}
  .price{font-size:1.5rem;font-weight:700}
  ul{padding-left:1.1em} .muted{color:var(--muted);font-size:.9rem}
  .cta{display:inline-block;margin-top:12px;padding:12px 18px;border-radius:10px;background:#9ca3af;color:#fff;font-weight:600;border:0;cursor:not-allowed}
  .note{background:#f3f4f6;border:1px solid var(--line);border-radius:10px;padding:12px;margin-top:12px;font-size:.9rem;color:var(--muted)}
  table{border-collapse:collapse;width:100%} td{border-bottom:1px solid var(--line);padding:6px 4px;vertical-align:top}
  footer{margin:28px 0;color:var(--muted);font-size:.8rem;border-top:1px solid var(--line);padding-top:12px}
</style></head>
<body>
<div class="draftbar">Preview storefront — not indexed. This is a test listing (not a live customer store).</div>
<div class="wrap">
  <h1>${esc(sf?.hero?.headline ?? title)}</h1>
  ${sf?.hero?.subheadline ? `<p class="hero-sub">${esc(sf.hero.subheadline)}</p>` : ""}
  <div class="grid">
    <div class="gallery">
      ${primary ? `<img src="${esc(primary)}" alt="${title}" loading="lazy">` : `<div class="note">No product image available.</div>`}
      ${gallery.slice(1, 5).map((g) => `<img src="${esc(g)}" alt="${title}" loading="lazy">`).join("")}
    </div>
    <div>
      ${price ? `<div class="price">${price}</div>` : ""}
      ${sf?.copy?.short_description ? `<p>${esc(sf.copy.short_description)}</p>` : ""}
      ${benefits.length ? `<h2>Highlights</h2><ul>${benefits.map((b) => `<li>${esc(b)}</li>`).join("")}</ul>` : ""}
      <button class="cta" disabled aria-disabled="true">Checkout not available</button>
      <div class="note">Checkout is not configured for this preview storefront (no payment provider connected). No purchase can be made.</div>
    </div>
  </div>
  ${how.length ? `<h2>How it works</h2><ol>${how.map((h) => `<li>${esc(h)}</li>`).join("")}</ol>` : ""}
  ${sf?.copy?.shipping?.copy ? `<h2>Shipping</h2><p>${esc(sf.copy.shipping.copy)}</p>` : ""}
  ${sf?.copy?.trust?.copy ? `<h2>About this listing</h2><p>${esc(sf.copy.trust.copy)}</p>` : ""}
  ${disclaimers.length ? `<ul class="muted">${disclaimers.map((d) => `<li>${esc(d)}</li>`).join("")}</ul>` : ""}
  ${faq.length ? `<h2>FAQ</h2>${faq.map((f) => `<p><strong>${esc(f?.q)}</strong><br>${esc(f?.a)}</p>`).join("")}` : ""}
  <footer>
    Market: ${esc(sf?.market ?? "")} · Currency: ${esc(sf?.currency?.display ?? "")} ·
    Template: ${esc(sf?.template_family ?? "")} ${esc(sf?.template_version ?? "")}<br>
    New condition. Delivery times are estimates, not guarantees. No reviews, ratings, or sales figures are shown (none verified).
  </footer>
</div></body></html>`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: SECURITY_HEADERS });
  }
  const url = new URL(req.url);
  // Last non-empty path segment after .../storefront/
  const parts = url.pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf("storefront");
  const slug = idx >= 0 && parts.length > idx + 1 ? parts[idx + 1] : "";
  // Validate + sanitize slug: no directory listing, no enumeration payloads.
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
    return new Response("Service unavailable", { status: 503, headers: SECURITY_HEADERS });
  }

  if (!body || body.status !== "OK" || !body.storefront) return notFound();

  const wantsJson = url.searchParams.get("format") === "json" ||
    (req.headers.get("accept") ?? "").includes("application/json");
  if (wantsJson) {
    // Return only the already-public-safe renderer payload.
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { ...SECURITY_HEADERS, "Content-Type": "application/json; charset=utf-8" },
    });
  }
  return new Response(renderHtml(body.storefront), {
    status: 200,
    headers: { ...SECURITY_HEADERS, "Content-Type": "text/html; charset=utf-8" },
  });
});
