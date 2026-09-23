// STRATELOQ-016C — Meta Facebook ORGANIC OAuth · capability derivation (PURE)
// ----------------------------------------------------------------------------
// Derive the ORGANIC capability set from the REAL Meta Page "tasks" grant that
// Meta returns for /me/accounts. This mirrors fn_social_capabilities_from_meta_tasks
// in mig_292 so the edge layer and the DB agree.
//
// HARD RULE (016C §5 "Never infer capabilities merely from requested scopes"):
//   Capabilities are derived ONLY from the tasks Meta actually granted on the
//   Page — never from what we requested. A Page returned without CREATE_CONTENT
//   yields NO PUBLISH_* capability, even if pages_manage_posts was requested.
//
// Meta Page task → Strateloq organic capability mapping:
//   CREATE_CONTENT → PUBLISH_TEXT, PUBLISH_IMAGE, PUBLISH_VIDEO, PUBLISH_CAROUSEL
//   (any task at all) → READ_PROFILE
// MODERATE / MESSAGING / ADVERTISE / ANALYZE / MANAGE do not, by themselves,
// grant an organic PUBLISH_* capability.

const ORGANIC_PUBLISH_CAPS = [
  "PUBLISH_TEXT",
  "PUBLISH_IMAGE",
  "PUBLISH_VIDEO",
  "PUBLISH_CAROUSEL",
] as const;

export function normalizeTask(t: unknown): string {
  return String(t ?? "").trim().toUpperCase();
}

export function capabilitiesFromMetaTasks(tasks: unknown): string[] {
  const list = Array.isArray(tasks) ? tasks.map(normalizeTask).filter(Boolean) : [];
  const caps = new Set<string>();
  if (list.length > 0) caps.add("READ_PROFILE");
  if (list.includes("CREATE_CONTENT")) {
    for (const c of ORGANIC_PUBLISH_CAPS) caps.add(c);
  }
  // Deterministic order for stable comparisons/tests.
  const order = ["READ_PROFILE", ...ORGANIC_PUBLISH_CAPS];
  return order.filter((c) => caps.has(c));
}

/** True when the derived capabilities can publish the given media type. */
export function capabilitiesSupportMedia(caps: string[], mediaType: string): boolean {
  const t = String(mediaType ?? "").trim().toUpperCase();
  const need = t === "VIDEO" ? "PUBLISH_VIDEO" : t === "IMAGE" ? "PUBLISH_IMAGE" : "PUBLISH_TEXT";
  return caps.includes(need);
}
