/*
 * PULSE-ECOM-P13-META-CONVERSION-TRACKING-001
 * Browser Meta Pixel adapter TEMPLATE for Pulse-hosted storefronts.
 *
 * Install status: ADAPTER_READY — real emission is pending a connected
 * storefront (currently 0 store connections). No storefront should load this
 * until the tenant's Pixel config reports load_pixel_allowed === true AND the
 * page has captured per-visitor consent.
 *
 * DEDUPLICATION CONTRACT (critical):
 *   - Generate ONE canonical event_id per business event: `pulse_<uuid>`.
 *   - Fire the browser Pixel with that value as eventID.
 *   - Send the SAME value to the server CAPI (edge: meta-capi-adapter, mode=emit).
 *   - Meta deduplicates the Pixel + CAPI pair by (event_name, event_id).
 *
 * SECURITY: this file runs in the browser. It NEVER contains or receives the
 * CAPI access token. Only the non-secret pixel/dataset id is used here.
 * PURCHASE must never be emitted from the browser as source of truth — the
 * server derives Purchase from a verified order/payment source only.
 */

// config is the object returned by public.fn_meta_pixel_config(tenant) — non-secret.
export function initPulseMetaPixel(config, { consentGranted }) {
  if (!config || config.configured !== true) return null;
  if (config.load_pixel_allowed !== true || consentGranted !== true) {
    // Consent master switch off or per-visitor consent not granted: do not load.
    return null;
  }
  /* eslint-disable */
  !(function (f, b, e, v, n, t, s) {
    if (f.fbq) return; n = f.fbq = function () {
      n.callMethod ? n.callMethod.apply(n, arguments) : n.queue.push(arguments);
    };
    if (!f._fbq) f._fbq = n; n.push = n; n.loaded = !0; n.version = "2.0"; n.queue = [];
    t = b.createElement(e); t.async = !0; t.src = v;
    s = b.getElementsByTagName(e)[0]; s.parentNode.insertBefore(t, s);
  })(window, document, "script", "https://connect.facebook.net/en_US/fbevents.js");
  /* eslint-enable */
  window.fbq("init", String(config.pixel_id));
  return window.fbq;
}

// Generate one canonical id shared by Pixel + CAPI.
export function newPulseEventId() {
  const uuid = (crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : "xxxxxxxxxxxx".replace(/x/g, () => ((Math.random() * 16) | 0).toString(16));
  return `pulse_${uuid}`;
}

// Track a non-purchase funnel event on the browser + hand the same id to the server.
// `emitToServer` should POST to the meta-capi-adapter emit endpoint with the same event_id.
export async function trackPulseEvent(fbq, metaEventName, { eventId, customData, emitToServer }) {
  if (metaEventName === "Purchase") {
    // Never treat a browser signal as a purchase source of truth.
    throw new Error("Purchase must be emitted server-side from a verified order source");
  }
  const id = eventId || newPulseEventId();
  if (fbq) fbq("track", metaEventName, customData || {}, { eventID: id });
  if (typeof emitToServer === "function") {
    await emitToServer({ event_id: id, event_name: metaEventName, custom_data: customData || {} });
  }
  return id;
}
