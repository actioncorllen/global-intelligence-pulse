// Deterministic tests against the LITERAL v24 kalodata-discovery source (pure-function section).
// No network. No credits. Fake keys only.
const fakeEnv: Record<string, string | undefined> = {};
(globalThis as any).Deno = { env: { get: (k: string) => fakeEnv[k] } };

const m = await import("./kalodata-logic.v24.ts");

let pass = 0, fail = 0;
function check(name: string, cond: boolean, extra?: string) {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${extra ? " — " + extra : ""}`); }
}

const FAKE_CURRENT = "TESTCURRENTKEY1234567890FAKE"; // fake, deterministic
const FAKE_OLD = "TESTOLDGENKEY0987654321FAKE";

// ---- T1: Valid X-API-Key authentication (header construction + key selection) ----
fakeEnv["KALODATA_SECRET_KEY"] = FAKE_CURRENT;
delete fakeEnv["KALODATA_API_KEY"];
let sel = m.kalodataKey();
check("T1a key selected from KALODATA_SECRET_KEY when no override", sel.key === FAKE_CURRENT && sel.source === "KALODATA_SECRET_KEY");
let h = m.kalodataAuthHeaders(sel.key);
check("T1b exactly one auth header", Object.keys(h).length === 1);
check("T1c header name is X-API-Key", Object.keys(h)[0] === "X-API-Key" && m.AUTH_HEADER === "X-API-Key");
check("T1d header carries the selected key", h["X-API-Key"] === FAKE_CURRENT);
fakeEnv["KALODATA_API_KEY"] = "  " + FAKE_CURRENT + "  "; // whitespace-padded current key in preferred slot
sel = m.kalodataKey();
check("T1e KALODATA_API_KEY preferred over KALODATA_SECRET_KEY, trimmed", sel.key === FAKE_CURRENT && sel.source === "KALODATA_API_KEY");
delete fakeEnv["KALODATA_API_KEY"];

// ---- T2: Conflicting secret-key header prevention ----
fakeEnv["KALODATA_SECRET_HEADER"] = "secret-key"; // legacy env present — must be IGNORED
h = m.kalodataAuthHeaders(m.kalodataKey().key);
const names = Object.keys(h).map((k) => k.toLowerCase());
check("T2a no secret-key header even when KALODATA_SECRET_HEADER env is set", !names.includes("secret-key"));
check("T2b no extra auth headers at all (only x-api-key)", names.length === 1 && names[0] === "x-api-key");
// Source-level guarantee: the deployed file never reads KALODATA_SECRET_HEADER to build a header.
import { readFileSync } from "node:fs";
const src = readFileSync(new URL("./kalodata-discovery.v24.index.ts", import.meta.url), "utf8");
check("T2c source never constructs a dynamic [secretHeader] header", !src.includes("[secretHeader]"));
check("T2d source never defaults to 'secret-key' header", !src.includes('|| "secret-key"'));

// ---- T3: Previous-generation key rejection (provider 501 envelope) is classified as an error ----
const body501 = { success: false, data: null, message: "The key is not allowed", cached: false, code: "501", errorCategory: "AUTH" };
check("T3a providerCode extracts 501", String(m.providerCode(body501)) === "501");
check("T3b looksLikeProviderError true for 501 envelope", m.looksLikeProviderError(body501) === true);
// handler classification expression (identical to v24 balance_probe): ok = httpOk && !logicalError
const okBalance501 = true && !m.looksLikeProviderError(body501);
check("T3c balance_probe with 501-in-200 => not ok (PROVIDER_LOGICAL_ERROR)", okBalance501 === false);
check("T3d discovery zero-product 501-in-200 => PROVIDER_LOGICAL_ERROR branch", m.extractProducts(body501).length === 0 && m.looksLikeProviderError(body501));

// ---- T4: HTTP 200 provider-level SUCCESS is not misclassified ----
for (const good of [
  { success: true, code: "200", message: "ok", data: { balance: 14.1 } },
  { code: 0, data: { balance: 14.1 } },
  { code: "0000", data: { credit: 14.1 } },
  { success: true, data: { credits: 14.1 } },
]) {
  check("T4 success envelope accepted: " + JSON.stringify({ code: (good as any).code, success: (good as any).success }), m.looksLikeProviderError(good) === false);
}
check("T4e extractBalance data.balance", m.extractBalance({ success: true, data: { balance: 14.1 } }) === 14.1);
check("T4f extractBalance data.credit", m.extractBalance({ data: { credit: 14.1 } }) === 14.1);
check("T4g extractBalance numeric data", m.extractBalance({ data: 14.1 }) === 14.1);
check("T4h extractBalance absent => null", m.extractBalance({ success: true, data: {} }) === null);

// ---- T5: Existing product response parsing preserved (v23 shapes) ----
const prod = { product_id: "123", title: "x" };
const shapes: Array<[string, any, number]> = [
  ["top-level array", [prod, prod], 2],
  ["data array", { data: [prod] }, 1],
  ["data.list", { data: { list: [prod, prod, prod] } }, 3],
  ["data.rows", { data: { rows: [prod] } }, 1],
  ["data.products", { data: { products: [prod] } }, 1],
  ["data.data", { data: { data: [prod] } }, 1],
  ["data.items", { data: { items: [prod] } }, 1],
  ["data.records", { data: { records: [prod] } }, 1],
  ["data.pageData", { data: { pageData: [prod] } }, 1],
  ["result.list", { result: { list: [prod] } }, 1],
  ["result.data", { result: { data: [prod] } }, 1],
  ["empty object", {}, 0],
];
for (const [name, b, n] of shapes) check(`T5 extractProducts ${name} => ${n}`, m.extractProducts(b).length === n);
check("T5m extractUsage picks credit fields", JSON.stringify(m.extractUsage({ data: { credit: 0.1 } })) === JSON.stringify({ credit: 0.1 }));

// ---- T9: No secret leakage ----
fakeEnv["KALODATA_API_KEY"] = FAKE_CURRENT;
fakeEnv["KALODATA_SECRET_KEY"] = FAKE_OLD;
let red = m.redact(`error for key ${FAKE_CURRENT} and old ${FAKE_OLD}`);
check("T9a redact removes KALODATA_API_KEY value", !red.includes(FAKE_CURRENT));
check("T9b redact removes KALODATA_SECRET_KEY value", !red.includes(FAKE_OLD));
red = m.redact('{"secret-key": "abc123", "x-api-key": "def456", "authorization": "Bearer zzz"}');
check("T9c redact masks key-shaped fields", !red.includes("abc123") && !red.includes("def456") && !red.includes("zzz"));
const mask = m.keyMask(FAKE_CURRENT);
check("T9d keyMask is first4...last4 only", mask === FAKE_CURRENT.slice(0, 4) + "..." + FAKE_CURRENT.slice(-4) && mask!.length === 11);
check("T9e keyMask null for short keys", m.keyMask("short") === null);
check("T9f balance endpoint is the FREE endpoint", m.DEFAULT_BALANCE_ENDPOINT === "https://www.kalodata.com/openapi/v1/credit/balance");

// ---- T10 (static): no paid call in probe/balance paths ----
const serveBody = src.slice(src.indexOf("Deno.serve"));
const balanceBlock = serveBody.slice(serveBody.indexOf("balance_probe"), serveBody.indexOf("const market"));
check("T10a balance_probe block uses GET only", balanceBlock.includes('method: "GET"') && !balanceBlock.includes('method: "POST"'));
check("T10b balance_probe block never touches product/rank endpoint", !balanceBlock.includes("product/rank") && !balanceBlock.includes("DEFAULT_ENDPOINT"));
check("T10c probe path returns before any provider fetch", serveBody.indexOf('mode: "probe"') < serveBody.indexOf("await fetch"));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
