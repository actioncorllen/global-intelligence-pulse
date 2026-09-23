// STRATELOQ-016C — Meta Facebook ORGANIC OAuth · Graph API client
// ----------------------------------------------------------------------------
// Thin, injectable wrapper over the Meta Graph API used by the OAuth flow.
// `fetchImpl` is injectable so callback/select-page logic can be exercised with
// deterministic mock responses (016C §10) without any live Meta call.
//
// This module NEVER logs tokens and NEVER returns a token to the browser. Tokens
// only ever flow: Meta → this module (in-memory) → Vault (via a SECURITY DEFINER
// RPC). Callers must keep them server-side.

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface DiscoveredPage {
  id: string;
  name: string;
  tasks: string[];
}

export interface GraphResult<T> {
  ok: boolean;
  status: number;
  data?: T;
  error?: { code?: number; type?: string; message: string; subcode?: number };
}

export class MetaGraph {
  private readonly host: string;
  private readonly version: string;
  private readonly fetchImpl: FetchLike;

  constructor(opts: { version?: string; host?: string; fetchImpl?: FetchLike } = {}) {
    this.version = opts.version || "v21.0";
    this.host = (opts.host || "https://graph.facebook.com").replace(/\/+$/, "");
    this.fetchImpl = opts.fetchImpl || ((i, init) => fetch(i, init));
  }

  private url(path: string): string {
    const p = path.startsWith("/") ? path : `/${path}`;
    return `${this.host}/${this.version}${p}`;
  }

  private async call<T>(path: string, params: Record<string, string>): Promise<GraphResult<T>> {
    const qs = new URLSearchParams(params).toString();
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.url(path)}?${qs}`, { method: "GET" });
    } catch (e) {
      return { ok: false, status: 0, error: { message: `network_error: ${(e as Error).message}` } };
    }
    let body: unknown = null;
    try {
      body = await res.json();
    } catch {
      body = null;
    }
    const err = (body as { error?: { code?: number; type?: string; message?: string; error_subcode?: number } })?.error;
    if (!res.ok || err) {
      return {
        ok: false,
        status: res.status,
        error: {
          code: err?.code,
          type: err?.type,
          subcode: err?.error_subcode,
          message: err?.message || `http_${res.status}`,
        },
      };
    }
    return { ok: true, status: res.status, data: body as T };
  }

  /** Exchange an authorization code for a (short-lived) user access token. */
  async exchangeCode(args: {
    appId: string;
    appSecret: string;
    redirectUri: string;
    code: string;
  }): Promise<GraphResult<{ access_token: string; expires_in?: number; token_type?: string }>> {
    return this.call("/oauth/access_token", {
      client_id: args.appId,
      client_secret: args.appSecret,
      redirect_uri: args.redirectUri,
      code: args.code,
    });
  }

  /** Exchange a short-lived user token for a long-lived (~60d) user token. */
  async exchangeLongLived(args: {
    appId: string;
    appSecret: string;
    shortToken: string;
  }): Promise<GraphResult<{ access_token: string; expires_in?: number; token_type?: string }>> {
    return this.call("/oauth/access_token", {
      grant_type: "fb_exchange_token",
      client_id: args.appId,
      client_secret: args.appSecret,
      fb_exchange_token: args.shortToken,
    });
  }

  /** List /me/permissions and return the granted scope names. */
  async grantedScopes(userToken: string): Promise<GraphResult<string[]>> {
    const r = await this.call<{ data: { permission: string; status: string }[] }>(
      "/me/permissions",
      { access_token: userToken },
    );
    if (!r.ok) return { ok: false, status: r.status, error: r.error };
    const granted = (r.data?.data || [])
      .filter((p) => String(p.status).toLowerCase() === "granted")
      .map((p) => p.permission);
    return { ok: true, status: r.status, data: granted };
  }

  /**
   * Discover Pages the user manages. Returns SAFE metadata only (id, name,
   * tasks) — the per-Page access_token in the response is intentionally NOT
   * surfaced here; obtain it explicitly via pageAccessToken() at finalize time.
   */
  async discoverPages(userToken: string): Promise<GraphResult<DiscoveredPage[]>> {
    const r = await this.call<{ data: { id: string; name: string; tasks?: string[] }[] }>(
      "/me/accounts",
      { fields: "id,name,tasks", access_token: userToken },
    );
    if (!r.ok) return { ok: false, status: r.status, error: r.error };
    const pages = (r.data?.data || []).map((p) => ({
      id: String(p.id),
      name: String(p.name ?? ""),
      tasks: Array.isArray(p.tasks) ? p.tasks.map(String) : [],
    }));
    return { ok: true, status: r.status, data: pages };
  }

  /** Fetch the Page access token + tasks for a specific Page (via the user token). */
  async pageAccessToken(
    userToken: string,
    pageId: string,
  ): Promise<GraphResult<{ id: string; name: string; access_token: string; tasks: string[] }>> {
    return this.call("/" + encodeURIComponent(pageId), {
      fields: "id,name,access_token,tasks",
      access_token: userToken,
    }) as Promise<GraphResult<{ id: string; name: string; access_token: string; tasks: string[] }>>;
  }

  /**
   * NON-PUBLISHING verification (016C §6): read-only GET on the Page using the
   * Page token. Confirms the Page exists and the token can access it. Creates,
   * edits or deletes NOTHING.
   */
  async verifyPageReadOnly(
    pageToken: string,
    pageId: string,
  ): Promise<GraphResult<{ id: string; name: string; fan_count?: number }>> {
    return this.call("/" + encodeURIComponent(pageId), {
      fields: "id,name,fan_count",
      access_token: pageToken,
    });
  }

  /** Inspect a token to learn its expiry (0 == non-expiring, common for Page tokens). */
  async debugToken(
    appId: string,
    appSecret: string,
    token: string,
  ): Promise<GraphResult<{ data: { expires_at?: number; data_access_expires_at?: number; is_valid?: boolean } }>> {
    return this.call("/debug_token", {
      input_token: token,
      access_token: `${appId}|${appSecret}`,
    });
  }

  /** Best-effort Meta-side revocation of the app's permissions for the user. */
  async revokePermissions(userToken: string): Promise<GraphResult<{ success: boolean }>> {
    const qs = new URLSearchParams({ access_token: userToken }).toString();
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.url("/me/permissions")}?${qs}`, { method: "DELETE" });
    } catch (e) {
      return { ok: false, status: 0, error: { message: `network_error: ${(e as Error).message}` } };
    }
    let body: unknown = null;
    try {
      body = await res.json();
    } catch {
      body = null;
    }
    const success = Boolean((body as { success?: boolean })?.success) && res.ok;
    return success
      ? { ok: true, status: res.status, data: { success: true } }
      : { ok: false, status: res.status, error: { message: "revoke_not_confirmed" } };
  }
}

/** Convert a token expiry epoch (seconds) to an ISO string, or null when non-expiring. */
export function expiryToIso(expiresAtEpoch?: number): string | null {
  if (!expiresAtEpoch || expiresAtEpoch <= 0) return null; // 0 == non-expiring
  return new Date(expiresAtEpoch * 1000).toISOString();
}
