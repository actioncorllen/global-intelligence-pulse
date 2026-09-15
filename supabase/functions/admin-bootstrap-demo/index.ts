// NEUTRALIZED after one-time use (PULSE-INTERNAL-BRAND-DEMO-002B).
// Previously performed a single guarded auth consolidation. Permanently disabled.
Deno.serve(() =>
  new Response(JSON.stringify({ error: "gone", message: "admin-bootstrap-demo is permanently disabled" }), {
    status: 410,
    headers: { "Content-Type": "application/json" },
  }),
);
