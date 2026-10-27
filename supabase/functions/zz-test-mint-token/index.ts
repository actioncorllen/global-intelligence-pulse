// Disabled test helper. Token-minting logic removed. Always refuses.
Deno.serve(() => new Response(JSON.stringify({ status: "DISABLED" }), { status: 410, headers: { "content-type": "application/json" } }));
