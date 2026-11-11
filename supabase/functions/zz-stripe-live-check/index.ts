// zz-stripe-live-check — RETIRED after the 2026-11-11 live-readiness verification. No Stripe access.
Deno.serve((): Response => new Response(JSON.stringify({ error: "gone" }), { status: 410, headers: { "content-type": "application/json" } }));
