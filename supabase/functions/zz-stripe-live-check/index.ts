// zz-stripe-live-check — RETIRED. Re-deployed on demand for live preflight, then retired again.
Deno.serve((): Response => new Response(JSON.stringify({ error: "gone" }), { status: 410, headers: { "content-type": "application/json" } }));
