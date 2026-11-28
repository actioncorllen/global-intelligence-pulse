// Pure, dependency-injected minimum video executor for the EXISTING Strateloq
// video-job pipeline. BE344 P3 PREPARED ARTIFACT — committed, NOT deployed, NO paid
// call. Kept out of index.ts (Deno.serve + I/O) so the deterministic tests import it
// without starting a server or touching a provider.
//
// It is the glue the media-job lifecycle already specifies. fn_media_dispatch_video_job
// returns a completion_contract: "executor uploads the mp4 to the private
// pulse-generated-media bucket, then calls fn_media_complete_video_real(...)". This
// core performs exactly that, provider-agnostically, reusing (never re-implementing):
//   * the media-job lifecycle: dispatch -> complete_video_real -> retry;
//   * the prepare-time gates already enforced before dispatch returns GENERATING
//     (rights, claim, 9:16 aspect, lineage, cost estimate);
//   * an EXPLICIT pre-spend authorization gate (fn_video_generation_authorization_state)
//     that is fail-closed — no paid provider call unless dispatch_allowed === true;
//   * private storage + honest provenance via fn_media_complete_video_real, which lands
//     the asset IN_REVIEW / identity_state=IDENTITY_REVIEW_REQUIRED / is_launch_safe=false
//     (a generated clip is NEVER auto-launch-safe; human identity review is mandatory).
//
// The provider produces ACTUAL moving video (a single image-to-video generation call
// seeded from the authorised source frame), NOT a slideshow / frame assembly.
// Creative direction (Problem -> product use -> visible result -> product close-up) and
// a consistent identity pack are carried in the dispatch prompt/storyboard + provenance.

export type VideoDispatchSpec = {
  status: string; // expect "GENERATING"
  job_id: string;
  provider: string;
  mode: string; // "IMAGE_TO_VIDEO"
  source_image_url: string | null;
  prompt: string;
  duration_s: number;
  aspect_ratio: string; // must be "9:16"
  resolution?: string | null;
};

export type VideoAuthzState = {
  dispatch_allowed: boolean;
  state?: string;
  [k: string]: unknown;
};

export type VideoGenerated = {
  providerJobId: string;
  storageRef: string; // private pulse-generated-media object ref the provider uploaded
  mime: string; // e.g. "video/mp4"
  width: number;
  height: number;
  durationS: number;
  actualCostUsd: number;
};

export type VideoProvider = {
  id: string; // e.g. "GOOGLE_GEMINI_OMNI" (never "MOCK": fn_media_complete_video_real refuses MOCK)
  model: string; // e.g. "gemini-omni-1.2-flash"
  /** ONE real moving-video generation (image-to-video). Returns a private storage ref, not frames. */
  generate: (p: {
    mode: string;
    sourceImageUrl: string | null;
    prompt: string;
    durationS: number;
    aspectRatio: string;
    resolution: string;
  }) => Promise<VideoGenerated>;
};

export type VideoExecutorDeps = {
  dispatch: (jobId: string, tenant: string) => Promise<VideoDispatchSpec>;
  authorize: (estimatedUsd: number, capUsd: number, model: string) => Promise<VideoAuthzState>;
  provider: VideoProvider;
  complete: (args: {
    jobId: string;
    tenant: string;
    provider: string;
    providerJobId: string;
    storageRef: string;
    mime: string;
    width: number;
    height: number;
    durationS: number;
    actualCostUsd: number;
    costCurrency: string;
    productId: string | null;
    countryCode: string | null;
    sourceAssetRefs: unknown[];
    prompt: string;
    provenance: Record<string, unknown>;
  }) => Promise<Record<string, unknown>>;
  retry: (jobId: string, tenant: string, error: string) => Promise<unknown>;
  now?: () => string;
};

export type VideoExecutorArgs = {
  jobId: string;
  tenant: string;
  productId: string | null;
  countryCode: string | null;
  capUsd: number;
  estimatedUsd: number;
  deps: VideoExecutorDeps;
};

export type VideoExecutorResult =
  | { status: "not_dispatchable"; detail: string }
  | { status: "spend_not_authorized"; authz: VideoAuthzState }
  | { status: "provider_failed"; error: string; retried: unknown }
  | {
      status: "completed";
      assetId: unknown;
      launchSafe: false;
      identityState: "IDENTITY_REVIEW_REQUIRED";
      completion: Record<string, unknown>;
    };

const CREATIVE_DIRECTION = "Problem -> product use -> visible result -> product close-up" as const;

export async function executeVideoScene(args: VideoExecutorArgs): Promise<VideoExecutorResult> {
  const { deps } = args;

  // 1) The job must be prepared + dispatchable. dispatch returns GENERATING only after
  //    the prepare-time gates (rights, claim, 9:16, lineage, cost) have passed.
  const spec = await deps.dispatch(args.jobId, args.tenant);
  if (spec.status !== "GENERATING") {
    return { status: "not_dispatchable", detail: spec.status };
  }
  if (spec.aspect_ratio !== "9:16") {
    return { status: "not_dispatchable", detail: "aspect_not_9_16" };
  }

  // 2) EXPLICIT spend authorization BEFORE any paid call. Fail-closed: no provider call
  //    unless dispatch_allowed === true (provider enabled + founder authorization + cap).
  const authz = await deps.authorize(args.estimatedUsd, args.capUsd, deps.provider.model);
  if (authz?.dispatch_allowed !== true) {
    const retried = await deps.retry(args.jobId, args.tenant, "spend_not_authorized");
    void retried;
    return { status: "spend_not_authorized", authz };
  }

  // 3) ACTUAL moving-video generation (single image-to-video call seeded from the
  //    authorised source frame). Never a slideshow / frame assembly.
  let gen: VideoGenerated;
  try {
    gen = await deps.provider.generate({
      mode: spec.mode,
      sourceImageUrl: spec.source_image_url,
      prompt: spec.prompt,
      durationS: spec.duration_s,
      aspectRatio: spec.aspect_ratio,
      resolution: spec.resolution ?? "720p",
    });
  } catch (e) {
    const retried = await deps.retry(args.jobId, args.tenant, "provider_error:" + (e as Error).message);
    return { status: "provider_failed", error: (e as Error).message, retried };
  }

  // 4) Complete through the media-job lifecycle: private storage ref + honest provenance.
  //    fn_media_complete_video_real refuses MOCK, lands the asset IN_REVIEW /
  //    IDENTITY_REVIEW_REQUIRED / is_launch_safe=false. No auto-clear, no auto-publish.
  const completion = await deps.complete({
    jobId: args.jobId,
    tenant: args.tenant,
    provider: deps.provider.id,
    providerJobId: gen.providerJobId,
    storageRef: gen.storageRef,
    mime: gen.mime,
    width: gen.width,
    height: gen.height,
    durationS: gen.durationS,
    actualCostUsd: gen.actualCostUsd,
    costCurrency: "USD",
    productId: args.productId,
    countryCode: args.countryCode,
    sourceAssetRefs: spec.source_image_url ? [spec.source_image_url] : [],
    prompt: spec.prompt,
    provenance: {
      creative_direction: CREATIVE_DIRECTION,
      identity_pack_consistent: true,
      generation_mode: spec.mode,
      model: deps.provider.model,
      real_motion_video: true,
      slideshow: false,
      generated_at: deps.now?.() ?? new Date().toISOString(),
    },
  });

  return {
    status: "completed",
    assetId: (completion as Record<string, unknown>).asset_id,
    launchSafe: false,
    identityState: "IDENTITY_REVIEW_REQUIRED",
    completion,
  };
}
