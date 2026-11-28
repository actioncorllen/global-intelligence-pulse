# BE351 P1 — Exact frontend source-level patches (Lovable project `12db6c84`)

**Purpose:** founder-only access for the Ad Creative Studio, My Campaigns and My Store surfaces, enforced in the frontend as **defense-in-depth** over the authoritative server-side gates (BE346 `mig_382` + BE350 `mig_383`). **Prepared, not built** — the frontend lives only in Lovable and no Lovable credit is authorised, so these are exact source-level patches to apply + regression-run when credits are available and authorised (expected 7 Dec). Nothing here deploys. Route guards use the **server-authoritative** founder check (`useIsFounder`, which calls the founder-only `list-issuable-applications` edge; fails closed). Product Discovery, Compare Countries, Research, Save and Monitoring are untouched.

Each patch is an exact `OLD` → `NEW` block (unique in its file) or a full new file. Server-side controls are unchanged (not weakened).

---

## Patch 1 — `src/components/layout/app-sidebar.tsx` (hide My Store + My Campaigns nav for non-founders)

`isFounder` is already computed in this component (via `useIsFounder()`).

**OLD**
```tsx
        .flatMap((item) =>
          item.view === "opportunities"
            ? [
                item,
                recommendationsItem,
                ...(withStore ? [myStoreItem] : []),
                myCampaignsItem,
                problemsItem,
              ]
            : [item],
        )
```
**NEW**
```tsx
        .flatMap((item) =>
          item.view === "opportunities"
            ? [
                item,
                recommendationsItem,
                // BE351: My Store + My Campaigns are founder-only (website/advertising = future scope).
                ...(isFounder && withStore ? [myStoreItem] : []),
                ...(isFounder ? [myCampaignsItem] : []),
                problemsItem,
              ]
            : [item],
        )
```

---

## Patch 2 — `src/components/layout/mobile-nav.tsx` (same, mobile)

`isFounder` is already computed in `MobileNav` (via `useIsFounder()`).

**OLD**
```tsx
        .flatMap((item) =>
          item.view === "opportunities"
            ? [
                item,
                recommendationsItem,
                ...(withStore ? [myStoreItem] : []),
                myCampaignsItem,
                problemsItem,
              ]
            : [item],
        )
```
**NEW**
```tsx
        .flatMap((item) =>
          item.view === "opportunities"
            ? [
                item,
                recommendationsItem,
                // BE351: My Store + My Campaigns are founder-only (website/advertising = future scope).
                ...(isFounder && withStore ? [myStoreItem] : []),
                ...(isFounder ? [myCampaignsItem] : []),
                problemsItem,
              ]
            : [item],
        )
```

---

## Patch 3 — `src/components/commerce/product-commerce-actions.tsx` (hide Create Ad + store + creative entry points for non-founders)

This component renders only the Create Ad | Create Free Store | Add to My Store trio (→ `/workspace/creative`, store flows) and, in founder detail views, the creative generator/import. It is entirely an advertising/store/creative surface, so a non-founder must see none of it. A single founder early-return is correct because it is placed **after every hook** (so React hook order is preserved) and before the first conditional return.

**3a. Add the import** (with the other `@/` imports near the top):

**OLD**
```tsx
import { commercialAssetLabel } from "@/lib/commerce/store-website-api";
```
**NEW**
```tsx
import { commercialAssetLabel } from "@/lib/commerce/store-website-api";
import { useIsFounder } from "@/hooks/use-founder-status";
```

**3b. Add the hook** — immediately after the opening of the `ProductCommerceActions` function body, with the existing hooks (place it right before `const { data: identityData } = useQuery(...)`):

**OLD**
```tsx
  const { data: identityData } = useQuery({
    queryKey: ["product-identity-resolution", productId],
    queryFn: () => fetchProductIdentityResolution(productId),
    enabled: allowCommercialGeneration,
  });
```
**NEW**
```tsx
  // BE351: the Ad Creative Studio + store surfaces are founder-only. Hook called
  // unconditionally (React rules); the early return below sits after every hook.
  const isFounder = useIsFounder();
  const { data: identityData } = useQuery({
    queryKey: ["product-identity-resolution", productId],
    queryFn: () => fetchProductIdentityResolution(productId),
    enabled: allowCommercialGeneration,
  });
```

**3c. Add the early return** — immediately after the `useEffect` that calls `refresh` (all hooks are above this line; `run`, `createAdLink` and the other early returns follow it):

**OLD**
```tsx
  React.useEffect(() => {
    void refresh();
  }, [refresh]);

  const run = async (
```
**NEW**
```tsx
  React.useEffect(() => {
    void refresh();
  }, [refresh]);

  // BE351: non-founders never see Create Ad / Create Free Store / Add to My Store
  // or the creative generator. Server-side gates (BE346/BE350) remain authoritative.
  if (!isFounder) return null;

  const run = async (
```

---

## Patch 4 — NEW FILE `src/components/onboarding/founder-guard.tsx`

Mirrors `OnboardingGuard`'s shape and loading UX. Reuses the server-authoritative founder query (the same `FOUNDER_STATUS_QUERY_KEY` + `listIssuableApplications` that `useIsFounder` uses) so no new auth path is introduced. Fails closed: only a settled `ok` renders the page; a non-founder is sent to `/workspace`, an unauthenticated visitor to `/auth`; while unresolved it shows the skeleton (so a founder is never briefly redirected).

```tsx
"use client";

import * as React from "react";
import { useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { DashboardShell } from "@/components/layout/dashboard-shell";
import { Skeleton } from "@/components/foundation/loading";
import { useSession } from "@/hooks/use-session";
import { listIssuableApplications } from "@/lib/invitation/founder-invitation-api";
import { FOUNDER_STATUS_QUERY_KEY } from "@/hooks/use-founder-status";

/**
 * Founder-only route guard (defense-in-depth). Reuses the server-authoritative
 * founder check — the founder-only `list-issuable-applications` edge, via the same
 * query key `useIsFounder` uses: a non-founder receives `unauthorized` with NO data,
 * so `ok` is the sole signal that renders the page. Fails closed — any non-`ok`
 * status blocks the route. Every server read/mutation behind these routes is
 * independently founder-gated server-side (BE346 `mig_382`, BE350 `mig_383`), so this
 * is presentation enforcement, never the authority.
 */
export function FounderGuard({ children }: { children: React.ReactNode }) {
  const navigate = useNavigate();
  const { session, loading } = useSession();
  const authed = !loading && Boolean(session?.user);
  const { data, isPending, fetchStatus } = useQuery({
    queryKey: FOUNDER_STATUS_QUERY_KEY,
    queryFn: listIssuableApplications,
    enabled: authed,
    retry: false,
    staleTime: 5 * 60 * 1000,
    gcTime: 10 * 60 * 1000,
  });
  const isFounder = data?.status === "ok";
  // Unresolved while the session is loading, or the founder query is in flight.
  const resolving = loading || (authed && isPending && fetchStatus !== "idle");

  React.useEffect(() => {
    if (resolving) return;
    if (!authed) navigate({ to: "/auth", search: { next: "/workspace" } as never });
    else if (!isFounder) navigate({ to: "/workspace", replace: true });
  }, [resolving, authed, isFounder, navigate]);

  if (resolving || !authed || !isFounder) {
    return (
      <DashboardShell>
        <div className="space-y-3" aria-busy="true">
          <Skeleton className="h-3 w-40" />
          <Skeleton className="h-8 w-3/4 max-w-2xl" />
          <Skeleton className="h-4 w-2/3 max-w-xl" />
        </div>
      </DashboardShell>
    );
  }
  return <>{children}</>;
}
```

---

## Patch 5 — `src/routes/workspace_.creative.tsx` (founder route guard)

**5a. Import**

**OLD**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
```
**NEW**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
import { FounderGuard } from "@/components/onboarding/founder-guard";
```

**5b. Wrap**

**OLD**
```tsx
  component: function GuardedCreativeStudioPage() {
    return (
      <OnboardingGuard>
        <CreativeStudioPage />
      </OnboardingGuard>
    );
  },
```
**NEW**
```tsx
  component: function GuardedCreativeStudioPage() {
    return (
      <OnboardingGuard>
        <FounderGuard>
          <CreativeStudioPage />
        </FounderGuard>
      </OnboardingGuard>
    );
  },
```

---

## Patch 6 — `src/routes/workspace_.my-campaigns.tsx` (founder route guard)

**6a. Import**

**OLD**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
```
**NEW**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
import { FounderGuard } from "@/components/onboarding/founder-guard";
```

**6b. Wrap**

**OLD**
```tsx
  component: function GuardedMyCampaignsPage() {
    return (
      <OnboardingGuard>
        <MyCampaignsPage />
      </OnboardingGuard>
    );
  },
```
**NEW**
```tsx
  component: function GuardedMyCampaignsPage() {
    return (
      <OnboardingGuard>
        <FounderGuard>
          <MyCampaignsPage />
        </FounderGuard>
      </OnboardingGuard>
    );
  },
```

---

## Patch 7 — `src/routes/workspace_.store.tsx` (founder route guard)

**7a. Import**

**OLD**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
```
**NEW**
```tsx
import { OnboardingGuard } from "@/components/onboarding/onboarding-guard";
import { FounderGuard } from "@/components/onboarding/founder-guard";
```

**7b. Wrap**

**OLD**
```tsx
  component: function GuardedMyStorePage() {
    return (
      <OnboardingGuard>
        <MyStorePage />
      </OnboardingGuard>
    );
  },
```
**NEW**
```tsx
  component: function GuardedMyStorePage() {
    return (
      <OnboardingGuard>
        <FounderGuard>
          <MyStorePage />
        </FounderGuard>
      </OnboardingGuard>
    );
  },
```

---

## No change needed — `src/components/market-explorer/product-country-explorer.tsx`

The "Create ads for / Create ads" and "Build store for / Build product page" buttons live in `HandoffCards`, rendered only when `showNextSteps` is true. The only production caller — `src/routes/workspace_.product-markets.$productId.tsx:74` (the subscriber Compare-Countries route) — already passes `showNextSteps={false}`, so subscribers never see them (and the buttons are inert placeholders with no navigation). Only the internal `dev.market-explorer.tsx` route renders them. **No launch change required.** (Optional future hardening: founder-gate `HandoffCards` directly.)

---

## Patch 8 — NEW TEST FILE `src/components/onboarding/founder-guard.test.tsx` (access matrix: founder / subscriber / anonymous)

```tsx
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as React from "react";

import { FounderGuard } from "./founder-guard";

const navigate = vi.fn();
vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => navigate,
}));

let sessionState: { session: unknown; loading: boolean };
vi.mock("@/hooks/use-session", () => ({ useSession: () => sessionState }));

let founderResult: { status: string };
vi.mock("@/lib/invitation/founder-invitation-api", () => ({
  listIssuableApplications: () => Promise.resolve(founderResult),
}));

vi.mock("@/hooks/use-founder-status", () => ({
  FOUNDER_STATUS_QUERY_KEY: ["invitation", "founder-status"],
}));

// Light stubs for the loading shell.
vi.mock("@/components/layout/dashboard-shell", () => ({
  DashboardShell: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("@/components/foundation/loading", () => ({
  Skeleton: (p: Record<string, unknown>) => <div data-testid="skeleton" {...p} />,
}));

function renderGuard() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <FounderGuard>
        <div data-testid="protected">FOUNDER CONTENT</div>
      </FounderGuard>
    </QueryClientProvider>,
  );
}

describe("FounderGuard", () => {
  beforeEach(() => navigate.mockReset());

  it("renders children for a founder (query ok)", async () => {
    sessionState = { session: { user: { id: "f" } }, loading: false };
    founderResult = { status: "ok" };
    renderGuard();
    expect(await screen.findByTestId("protected")).toBeTruthy();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("redirects a subscriber to /workspace (query unauthorized)", async () => {
    sessionState = { session: { user: { id: "s" } }, loading: false };
    founderResult = { status: "unauthorized" };
    renderGuard();
    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith({ to: "/workspace", replace: true }),
    );
    expect(screen.queryByTestId("protected")).toBeNull();
  });

  it("redirects an anonymous visitor to /auth", async () => {
    sessionState = { session: null, loading: false };
    founderResult = { status: "auth_required" };
    renderGuard();
    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith({ to: "/auth", search: { next: "/workspace" } }),
    );
    expect(screen.queryByTestId("protected")).toBeNull();
  });
});
```

**Additional nav assertions** (add to the existing `src/components/layout/my-products-nav.test.tsx` / `problems-nav.test.tsx` pattern, which already mocks `useIsFounder: () => false`): with `useIsFounder() === false`, assert the e-commerce sidebar/mobile nav render **no** "My Store" and **no** "My Campaigns" item, while Overview/Products/Competitors/Suppliers/Recommendations/Problem to Product remain; with `useIsFounder() === true`, assert "My Campaigns" renders (and "My Store" when `hasHostedStore`). **ProductCommerceActions**: with `useIsFounder() === false`, assert the component renders nothing (no "Create Ad" / "Create Free Store" / "Add to My Store"); with `true`, the trio renders per the backend action list.

---

## Apply + verify (when credits are authorised, 7 Dec)
1. Apply Patches 1–8 verbatim in the Lovable project.
2. Run the Creative-Studio / nav / commerce suites + the new `founder-guard.test.tsx` + the full suite + typecheck + build.
3. Signed-in sighting: founder sees My Store/My Campaigns/Create Ad and can open `/workspace/creative`; a subscriber sees none and is redirected from the three routes; Discovery/Compare/Research/Save/Monitoring work for both; mobile at 375px.
4. Do **not** deploy without founder authorisation.

**Server-side is unchanged and authoritative** (BE346 `mig_382` + BE350 `mig_383`): even without these frontend patches a subscriber cannot create or read any creative/campaign/store object. These patches remove the surfaces from view and guard the routes.
