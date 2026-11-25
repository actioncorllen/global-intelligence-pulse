# DataForSEO — "Quick Answers to Frequently Asked Legal Questions" (CAPTURE)

**Source URL:** https://dataforseo.com/help-center/quick-answers-to-frequently-asked-legal-questions
**Page date:** "Updated 05.11.2026" (5 November 2026) — the FAQ the founder referenced.
**Retrieved:** 2026-11-25, via an authorised n8n HTTP workflow (zero-cost, read-only; this execution environment's direct web access is blocked by the permission-mode classifier). Raw HTML → tag-stripped text. **This is a verbatim extract of the public page for the GPD.01 counsel package; it is provider documentation, not legal clearance.**
**FAQ's own stated basis:** "based on the current Terms of Service (12 June 2026), Privacy Policy (29 October 2026), and DPA (12 June 2026)."

## Table of contents (as published)
1. Can you confirm our product / use case complies with Section 7.1?
2. How long may we keep the data we retrieved?
3. Can we resell, redistribute, sublicense, or give our customers raw API access?
4. Are there attribution, branding or display requirements?
5. Who is responsible for complying with Google's, Bing's, other search engines own terms?
6. Can we use the data commercially, in a paid product, shown to our own customers?
7. Does Section 7.1 apply to data that isn't SERP data?
8. Can we feed the data into AI – inference, RAG, model training?
9. What are the GDPR arrangements?
10. Can our customers export or download their own records?
11. Do we need an additional license, license tier, or enterprise agreement?
12. We're based in a certain country – are we eligible?
13. Can we run many unrelated end clients through one account?
14. What happens to data we already hold if we cancel?
15. Can you delete our data on request / do you offer zero data retention?
16. Who are your sub-processors, and how are changes notified?
17. What law governs, and where are disputes heard?
18. Useful links

## Verbatim answers retrieved (§§1–5)

**§1 — Can you confirm our product / use case complies with Section 7.1?**
> "Unfortunately, we are unable to confirm whether a particular product or implementation complies with our Terms of Service … Section 7.1 of the Terms of Service establishes restrictions on the use of SERP … data … such data must not be used to compete with the search engines from which it originates or to harm their legitimate business interests. … The key consideration is not necessarily whether a product uses service data, but how that data is used, what the product does, and whether its use conflicts with the interests of the originating search engine provider. For example, this could include: **Direct competition** … build a competing search engine …; **Commercial exploitation** … create a commercial database or competing service that substitutes for the original search engine's offering; **Harm to business interests** … divert users, advertising revenue, customers …; **Unfair competitive advantage** …."

**§2 — How long may we keep the data we retrieved?**
> "The Terms of Service set **no limit on how long a client keeps its own copies**, and do not require deletion when service ends. The published retention figures describe DataForSEO's own storage, not the client's: Privacy Policy §5.a – API task data stored for 365 days; §6.c – data stored more than 365 days is permanently deleted from our system. DPA Annex I.B(7), for personal data under GDPR – 31 days for SERP API output, 7 days for HTML, 6 months for pingback/postback, 12 months for client tasks/results/payload."

**§3 — Can we resell, redistribute, sublicense, or give our customers raw API access?**
> "**No, not under the standard Terms.** The Terms of Service grant no resale, sublicensing or redistribution right, so any onward distribution of our datasets **as an untransformed standalone feed, database dump, public endpoint, or raw API service** requires a separate written agreement. This includes white-label API access, MCP endpoints, marketplace actors, open datasets, and per-query wallet resale models."

**§4 — Are there attribution, branding or display requirements?**
> "**None.** Neither the Terms of Service nor the Privacy Policy imposes attribution, branding, citation, interface or format requirements on data obtained through the Service. **The Terms also prescribe no transformation threshold.** Any attribution owed in respect of the originating provider's own content is a matter under that search engine's terms, not ours."

**§5 — Who is responsible for complying with Google's, Bing's, other search engines' own terms?**
> "**The client is responsible** for ensuring compliance with the applicable terms and conditions of Google, Bing, and any other relevant search engine providers. **Our Terms of Service do not grant any licenses from, or confer any rights under, the terms and conditions of, any upstream provider.** Furthermore, **Section 7.2** … requires the client to indemnify, defend, and hold DataForSEO harmless against claims … arising from violations of Section 7.1 … Section 8.1 further clarifies that DataForSEO assumes no responsibility for the use of client accounts."

**§§6–18:** not captured in this pass (the extract was length-trimmed after §5). §6 ("commercial use in a paid product shown to our own customers") and §7 ("does §7.1 apply to non-SERP data") should be captured in a follow-up fetch before counsel sign-off; from §§3–5 the expected thrust of §6 is that commercial use of **derived/transformed** data in a paid product shown to customers is permitted (only **raw** redistribution is restricted, §3), with upstream-provider compliance remaining the client's (§5).

## What this changes for GPD.01 (analysis, not clearance)
- **Confirms the derived-display model is NOT the restricted activity.** §3 restricts only redistribution of **raw/untransformed** data (feeds, dumps, public endpoints, raw API). Strateloq displays **derived, aggregated analytics** — not a raw feed — so §3's prohibition is not engaged; §4 confirms **no attribution/transformation-threshold** requirement from DataForSEO.
- **Confirms DataForSEO ≠ Google permission.** §5 states the client bears Google-upstream compliance and the §7.2 indemnity, and that DataForSEO conveys no upstream rights. This is exactly the residual the two-leg counsel question (BE307) isolates.
- **Confirms retention/caching is permitted** (§2: no limit on the client's own copies).
- **§7.1 risk for our use looks low but is for counsel:** §1's examples are building/ substituting a search engine or diverting Google's users/ad revenue — Strateloq's product-research tool does none of these, but DataForSEO explicitly will not confirm compliance, so the §7.1/upstream assessment remains a counsel/founder matter.
