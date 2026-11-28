// Deterministic tests for the minimum video executor core.
// Run: `deno test supabase/functions/commercial-video-generate/video-executor-core.test.ts`
// Self-contained: mocked lifecycle RPCs + mocked provider. NO network, NO paid call, NO
// deploy. Proves the executor reuses dispatch -> complete_video_real -> retry, is
// fail-closed on spend, produces ACTUAL moving video (one generation call, not a
// slideshow), and never auto-clears / publishes.
import {
  executeVideoScene,
  type VideoDispatchSpec,
  type VideoExecutorDeps,
} from "./video-executor-core.ts";

function ok(c: unknown, m: string): asserts c {
  if (!c) throw new Error("ASSERT FAILED: " + m);
}
function eq<T>(a: T, b: T, m: string) {
  if (a !== b) throw new Error(`ASSERT EQ FAILED: ${m} (got ${JSON.stringify(a)} !== ${JSON.stringify(b)})`);
}

const JOB = "11111111-1111-4111-8111-1111111111aa";
const TENANT = "7c8ddf9d-172c-4a89-a402-bb7066228b61";

type Spies = {
  providerCalls: Array<Record<string, unknown>>;
  completeCalls: Array<Record<string, unknown>>;
  retryCalls: Array<{ error: string }>;
  authzCalls: number;
};

function makeDeps(over: {
  dispatch?: Partial<VideoDispatchSpec>;
  authAllowed?: boolean;
  providerThrows?: boolean;
}): { deps: VideoExecutorDeps; spies: Spies } {
  const spies: Spies = { providerCalls: [], completeCalls: [], retryCalls: [], authzCalls: 0 };
  const spec: VideoDispatchSpec = {
    status: "GENERATING",
    job_id: JOB,
    provider: "GOOGLE_GEMINI_OMNI",
    mode: "IMAGE_TO_VIDEO",
    source_image_url: "pulse-generated-media/ref/frame.png",
    prompt: "Scene 1: person struggles ... | Scene 2: uses product ... | Scene 3: result ... | Scene 4: close-up",
    duration_s: 10,
    aspect_ratio: "9:16",
    resolution: "720p",
    ...over.dispatch,
  };
  const deps: VideoExecutorDeps = {
    dispatch: () => Promise.resolve(spec),
    authorize: (est, cap, model) => {
      spies.authzCalls++;
      return Promise.resolve({
        dispatch_allowed: over.authAllowed === true,
        state: over.authAllowed ? "AUTHORIZED" : "BLOCKED_PENDING_FOUNDER_AUTHORIZATION",
        est,
        cap,
        model,
      });
    },
    provider: {
      id: "GOOGLE_GEMINI_OMNI",
      model: "gemini-omni-1.2-flash",
      generate: (p) => {
        spies.providerCalls.push(p as unknown as Record<string, unknown>);
        if (over.providerThrows) return Promise.reject(new Error("omni_timeout"));
        return Promise.resolve({
          providerJobId: "omni-xyz",
          storageRef: "pulse-generated-media/video/out.mp4",
          mime: "video/mp4",
          width: 1080,
          height: 1920,
          durationS: p.durationS,
          actualCostUsd: 0.7,
        });
      },
    },
    complete: (a) => {
      spies.completeCalls.push(a as unknown as Record<string, unknown>);
      return Promise.resolve({ status: "GENERATED_REAL", asset_id: "asset-1", is_launch_safe: false });
    },
    retry: (_id, _t, error) => {
      spies.retryCalls.push({ error });
      return Promise.resolve({ status: "RETRY_SCHEDULED" });
    },
    now: () => "2026-11-28T00:00:00.000Z",
  };
  return { deps, spies };
}

const baseArgs = (deps: VideoExecutorDeps) => ({
  jobId: JOB,
  tenant: TENANT,
  productId: null,
  countryCode: "US",
  capUsd: 5,
  estimatedUsd: 0.7,
  deps,
});

// (A) not GENERATING -> not_dispatchable; provider + complete never called.
Deno.test("not dispatchable when the job is not GENERATING; provider/complete never called", async () => {
  const { deps, spies } = makeDeps({ dispatch: { status: "NOT_PREPARED" }, authAllowed: true });
  const r = await executeVideoScene(baseArgs(deps));
  eq(r.status, "not_dispatchable", "status");
  eq(spies.authzCalls, 0, "authz not reached");
  eq(spies.providerCalls.length, 0, "provider not called");
  eq(spies.completeCalls.length, 0, "complete not called");
});

// (B) aspect not 9:16 -> not_dispatchable.
Deno.test("refuses a non-9:16 job", async () => {
  const { deps, spies } = makeDeps({ dispatch: { aspect_ratio: "16:9" }, authAllowed: true });
  const r = await executeVideoScene(baseArgs(deps));
  eq(r.status, "not_dispatchable", "status");
  eq(spies.providerCalls.length, 0, "provider not called");
});

// (C) spend NOT authorized -> fail-closed; provider never called; retry called.
Deno.test("fail-closed when spend is not authorized; provider never called; retry invoked", async () => {
  const { deps, spies } = makeDeps({ authAllowed: false });
  const r = await executeVideoScene(baseArgs(deps));
  eq(r.status, "spend_not_authorized", "status");
  eq(spies.providerCalls.length, 0, "provider not called");
  eq(spies.completeCalls.length, 0, "complete not called");
  eq(spies.retryCalls.length, 1, "retry invoked");
});

// (D) authorized + provider success -> completed; ACTUAL moving video; review-required.
Deno.test("authorized success: one image-to-video call, private MP4, completed IN_REVIEW/not-launch-safe", async () => {
  const { deps, spies } = makeDeps({ authAllowed: true });
  const r = await executeVideoScene(baseArgs(deps));
  ok(r.status === "completed", "completed");
  // exactly one generation call (a single moving-video generation, NOT frame-by-frame slideshow assembly)
  eq(spies.providerCalls.length, 1, "exactly one provider generate call");
  eq(spies.providerCalls[0].mode, "IMAGE_TO_VIDEO", "image-to-video mode");
  eq(spies.providerCalls[0].sourceImageUrl, "pulse-generated-media/ref/frame.png", "seeded from the authorised source frame");
  eq(spies.providerCalls[0].aspectRatio, "9:16", "9:16 vertical");
  eq(spies.providerCalls[0].durationS, 10, "duration carried");
  // completion: real provider (not MOCK), video mime + duration, honest provenance, not launch-safe
  eq(spies.completeCalls.length, 1, "exactly one completion");
  const c = spies.completeCalls[0];
  ok(c.provider !== "MOCK", "real provider (fn_media_complete_video_real refuses MOCK)");
  ok(String(c.mime).startsWith("video/"), "video mime (moving video, not an image)");
  ok(Number(c.durationS) > 0, "has a duration");
  const prov = c.provenance as Record<string, unknown>;
  eq(prov.slideshow, false, "explicitly not a slideshow");
  eq(prov.real_motion_video, true, "real motion video");
  eq(prov.identity_pack_consistent, true, "identity pack consistency flagged");
  eq(prov.creative_direction, "Problem -> product use -> visible result -> product close-up", "creative direction");
  if (r.status === "completed") {
    eq(r.launchSafe, false, "never auto-launch-safe");
    eq(r.identityState, "IDENTITY_REVIEW_REQUIRED", "identity review required");
  }
});

// (E) provider failure -> provider_failed; complete never called; retry called with the error.
Deno.test("provider failure: no completion; retry invoked with the error", async () => {
  const { deps, spies } = makeDeps({ authAllowed: true, providerThrows: true });
  const r = await executeVideoScene(baseArgs(deps));
  eq(r.status, "provider_failed", "status");
  eq(spies.completeCalls.length, 0, "complete not called");
  eq(spies.retryCalls.length, 1, "retry invoked");
  ok(spies.retryCalls[0].error.includes("omni_timeout"), "retry carries the provider error");
});
