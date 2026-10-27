import "jsr:@supabase/functions-js/edge-runtime.d.ts";
// Retired diagnostic. Always 404.
Deno.serve(() => new Response(JSON.stringify({ status: "GONE" }), { status: 404, headers: { "Content-Type": "application/json" } }));
