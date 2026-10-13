import { workflow, trigger, node, expr } from '@n8n/workflow-sdk';

const webhookTrigger = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'Stage-2 Search Request',
    parameters: {
      httpMethod: 'POST',
      path: 'stage2-cj-supplier-search',
      responseMode: 'lastNode',
      options: {}
    }
  }
});

const validateInput = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Input',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const inraw = $input.first().json || {};
const b = (inraw.body && typeof inraw.body === "object") ? inraw.body : inraw;
const s = (v) => (typeof v === "string" ? v.trim() : (v == null ? "" : String(v)));
const tenant_id = s(b.tenant_id);
const product_id = s(b.product_id);
const market = s(b.market).toUpperCase();
const search_query = s(b.search_query);
const request_id = s(b.request_id);
const persist = (b.persist === true || b.persist === "true");
const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const errs = [];
if (!uuidRe.test(tenant_id)) errs.push("tenant_id_missing_or_malformed");
if (!uuidRe.test(product_id)) errs.push("product_id_missing_or_malformed");
if (!market) errs.push("market_required");
if (!search_query) errs.push("search_query_required");
if (errs.length) { throw new Error("STAGE2_INPUT_INVALID: " + errs.join(",")); }
return [{ json: { tenant_id, product_id, market, search_query, request_id: request_id || null, persist, page_num: 1, page_size: 20 } }];`
    }
  }
});

const verifyOwner = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Verify Owner',
    alwaysOutputData: true,
    parameters: {
      method: 'GET',
      url: expr("{{ 'https://nxaunmyihhjixxxljcqt.supabase.co/rest/v1/commerce_products?select=id&id=eq.' + $json.product_id + '&user_id=eq.' + $json.tenant_id }}"),
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [{ name: 'Accept', value: 'application/vnd.pgrst.object+json' }] },
      options: { timeout: 30000, response: { response: { neverError: true, responseFormat: 'json' } } }
    },
    credentials: { supabaseApi: { id: 'jMhzgwaHX9jwZ7rA', name: 'Supabase account' } }
  }
});

const assertOwned = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Assert Owned',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const ctx = $("Validate Input").first().json;
const r = $input.first().json || {};
const ownedId = (r && typeof r === "object") ? (r.id || (r.body && r.body.id) || null) : null;
if (!ownedId || String(ownedId) !== String(ctx.product_id)) {
  throw new Error("STAGE2_TENANT_PRODUCT_NOT_OWNED");
}
return [{ json: ctx }];`
    }
  }
});

const cjAuth = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'CJ Auth',
    parameters: {
      method: 'POST',
      url: 'https://developers.cjdropshipping.com/api2.0/v1/authentication/getAccessToken',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpCustomAuth',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [{ name: 'Content-Type', value: 'application/json' }] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: '{}',
      options: { timeout: 30000, response: { response: { neverError: true, responseFormat: 'json' } } }
    },
    credentials: { httpCustomAuth: { id: '2IV5tXPu9jAItjKh', name: 'CJ Dropshipping API' } }
  }
});

const cjSearch = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'CJ Search',
    parameters: {
      method: 'GET',
      url: 'https://developers.cjdropshipping.com/api2.0/v1/product/list',
      sendQuery: true,
      specifyQuery: 'keypair',
      queryParameters: {
        parameters: [
          { name: 'pageNum', value: expr("{{ $('Assert Owned').first().json.page_num }}") },
          { name: 'pageSize', value: expr("{{ $('Assert Owned').first().json.page_size }}") },
          { name: 'productNameEn', value: expr("{{ $('Assert Owned').first().json.search_query }}") }
        ]
      },
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [{ name: 'CJ-Access-Token', value: expr("{{ $('CJ Auth').first().json.data.accessToken }}") }] },
      options: { timeout: 30000, response: { response: { neverError: true, responseFormat: 'json' } } }
    }
  }
});

const buildCandidates = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Candidates',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const ctx = $("Assert Owned").first().json;
const resp = $input.first().json || {};
const rows = (resp && resp.data && Array.isArray(resp.data.list)) ? resp.data.list : [];
const items = [];
for (const r of rows) {
  if (r.pid == null) continue;
  const sku = r.productSku || null;
  items.push({
    supplier: "CJ",
    supplier_product_id: String(r.pid),
    sku: sku,
    title: r.productNameEn || null,
    category: r.categoryName || null,
    variant: null,
    supplier_reference: sku || String(r.pid)
  });
}
return [{ json: { candidate_count: items.length, rpc_body: {
  p_tenant: ctx.tenant_id,
  p_product_id: ctx.product_id,
  p_market: ctx.market,
  p_candidates: items,
  p_persist: ctx.persist
} } }];`
    }
  }
});

const resolveIdentity = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Resolve Identity',
    parameters: {
      method: 'POST',
      url: 'https://nxaunmyihhjixxxljcqt.supabase.co/rest/v1/rpc/fn_resolve_concrete_supplier_identity',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'supabaseApi',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [{ name: 'Content-Type', value: 'application/json' }] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr("{{ $json.rpc_body }}"),
      options: { timeout: 60000, response: { response: { neverError: true, responseFormat: 'json' } } }
    },
    credentials: { supabaseApi: { id: 'jMhzgwaHX9jwZ7rA', name: 'Supabase account' } }
  }
});

const buildResponse = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Response',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `const ctx = $("Assert Owned").first().json;
const norm = $("Build Candidates").first().json;
const verdict = $input.first().json || {};
return [{ json: {
  ok: true,
  stage: "STAGE2_CJ_SUPPLIER_SEARCH",
  request_id: ctx.request_id || null,
  tenant_id: ctx.tenant_id,
  product_id: ctx.product_id,
  market: ctx.market,
  persist: ctx.persist,
  candidate_count: norm.candidate_count,
  identity_result: verdict.identity_result || null,
  qualifying_count: (verdict.qualifying_count == null ? null : verdict.qualifying_count),
  selected_supplier_product_id: verdict.selected_supplier_product_id || null,
  bound: (verdict.bound === true),
  resolver: verdict
} }];`
    }
  }
});

export default workflow('stage2-cj-supplier-search', 'Pulse — Stage-2 CJ Supplier Search (search-only)')
  .add(webhookTrigger)
  .to(validateInput)
  .to(verifyOwner)
  .to(assertOwned)
  .to(cjAuth)
  .to(cjSearch)
  .to(buildCandidates)
  .to(resolveIdentity)
  .to(buildResponse);
