# Smart parts finder: marketplace feasibility

Pull Up is a driving app first, a community second and a parts-discovery
tool third. This document records what eBay allows, what Pull Up can build
before any eBay approval, and what has to wait. Researched 2026-10-16 from
eBay's public developer documentation (sources at the end). Nothing here has
been tested against eBay's live API: Pull Up has no eBay developer keys, no
Buy API approval and no eBay Partner Network (EPN) campaign.

## Summary

| Question | Answer |
| --- | --- |
| Can we search eBay listings by API today? | Not in production without approval. The Browse API is part of eBay's Buy APIs, which are "intended for certain approved eBay partners", granted on the proposed business model and a formal agreement. Sandbox keys work immediately but return mock data. |
| Can we filter by the user's vehicle? | Yes, once approved: Browse `search` takes a `compatibility_filter`, and `checkCompatibility` confirms one item. Supported only for cars, trucks (Year/Make/Model/Trim/Engine) and motorcycles (Year/Make/Model/Submodel). |
| Can we show delivered price? | Partly. Item price and shipping cost are returned; calculated shipping needs the buyer's postcode (`contextualLocation`). US sales tax is generally not returned, so delivered price must be labelled "before tax" where tax is missing. |
| Can we compute our own seller-trust score? | Not without eBay's written permission. The API License Agreement restricts use of "data relating to the performance of sellers, either individually or in aggregate". We show eBay's own seller fields (feedback %, feedback score) verbatim and do not rate sellers. |
| Can we flag "great deals" or model fair prices? | No. The licence prohibits using eBay content to "suggest or model prices". We sort by price; we never say a price is good, fair or the lowest. |
| Can we earn a commission? | Yes, through EPN: an affiliate campaign ID in the `X-EBAY-C-ENDUSERCTX` header makes the API return `itemAffiliateWebUrl`. Search links can carry the same campaign parameters. A clear disclosure must sit next to the links, above the fold. |
| What ships without approval? | Vehicle-aware eBay search links (no listings shown in the app), garage-driven search terms, and the full UI built against labelled sample data in tests only. |

## What eBay allows

### Access

* **Browse API** (`buy/browse/v1`): `item_summary/search`, `item/{id}`,
  `item/{id}/check_compatibility`. Not "Limited Release", but all Buy APIs
  require eBay's approval for production and an additional licence.
  Approval depends on the business model; affiliates are an accepted model.
* **Call limits**: 5,000 Browse calls per day by default, raisable through
  eBay's Application Growth Check. With a server-side cache this supports a
  modest user base; it does not support querying eBay on every keystroke.
* **Sandbox**: available immediately with a developer account. Compatibility
  results in sandbox are mock data, so sandbox can test our parsing and UI,
  not the quality of matches.

### Content rules from the API License Agreement that shape the design

| Clause | Rule | Design consequence |
| --- | --- | --- |
| §8.1(c) | Listing data may be at most 6 hours old, other content 24 hours, and staleness must be disclosed | Server cache TTL of 6 h for listings; each result shows "Checked 2 h ago"; expired items are dropped |
| §8.1(b)(1) | Remove content that is no longer publicly available | Results whose `itemEndDate` has passed are never shown; cache refresh drops ended items |
| §8.1(b)(2) | Don't co-mingle eBay content with non-eBay content | eBay results live in their own clearly labelled "From eBay" section, never mixed with posts or other sources |
| §8.1(d)(ii) | Seller-performance data, individually or aggregated, needs eBay's prior written permission | No derived seller rating. We show eBay's own feedback % and score as returned, labelled as eBay's |
| §9.5 | Don't use eBay content to suggest or model prices | No "good deal", "below market", price history or price prediction |
| §9.6 | No seller arbitrage | Not applicable to our use; no resale features |
| §9.10 | Don't train algorithms on eBay content | Grouping and ranking are deterministic rules, not trained models; no eBay data enters any training set |
| §3.1(c) | Content may be reorganised for display | Grouping duplicates and sorting is allowed |
| §8.2 | Limits on personal information | We store no seller personal data beyond the username eBay returns with the listing, and only in the 6 h cache |

### Affiliate (EPN) rules

* The API returns `itemAffiliateWebUrl` when the request carries
  `X-EBAY-C-ENDUSERCTX: affiliateCampaignId=<10 digits>[,affiliateReferenceId=…]`.
* Disclosure must be clear and conspicuous, as close to the links as
  possible and, in an app, above the fold. A link to a separate disclosure
  page is not enough. Pull Up's wording (`AffiliateCampaign.disclosure` in
  `Parts.swift`), shown above the eBay search button whenever a campaign
  ID is set: "Links to eBay are affiliate links. Pull Up may earn a
  commission when you buy, at no extra cost to you. It never changes what
  you see."
* Commission never influences ranking: ranking code will receive no
  affiliate data at all (to be enforced by type once Stage B adds a
  result type; no `PartResult` exists yet).

## What Pull Up builds

### Stage A: ships without eBay approval (M4)

1. **Vehicle identity from the garage.** Year, make, model, trim or
   submodel, engine, and any OEM part numbers the user saved on a mod. The
   user can edit what's sent; nothing is sent until they search.
2. **Manual search** for any part, with or without a vehicle.
3. **eBay search links.** Pull Up builds an `ebay.com/sch/…` URL with the
   vehicle and part terms (and the EPN campaign parameters if configured)
   and opens it in Safari. No listing, price or seller is shown inside Pull
   Up, because without the API we have none; the UI says so.
4. **Labelled sample results** exist only in unit tests and UI-test
   screenshots, with the demo strip, to exercise the Stage B layout.

### Stage B: after Buy API approval

1. **`parts-search` edge function** holds the eBay OAuth client credentials
   (Supabase secrets; never in the app), calls Browse `search` with
   `compatibility_filter`, caches results for at most 6 hours, rate-limits
   per user, and returns normalised results. The app never talks to eBay's
   API directly.
2. **Normalised result** (fields that eBay doesn't return are `nil` and shown
   as "Not provided", never guessed):
   item price, shipping cost (or "calculated at checkout"), estimated
   delivery window, condition (`conditionId` + text), brand, MPN, ePID,
   compatibility match (`EXACT`, `POSSIBLE`), seller username, eBay feedback
   % and score, item location, end date, image, `itemWebUrl` /
   `itemAffiliateWebUrl`, fetched-at time.
3. **Delivered price** = item + shipping where both are known; tax and
   import fees added only when eBay returns them, otherwise the figure is
   labelled "before tax". Free shipping is shown only when eBay says so.
4. **Grouping duplicates.** Listings are grouped only when they share an
   ePID or the same brand + normalised MPN **and** the same condition class
   (new / used / for parts) **and** the same OEM vs aftermarket status **and**
   the same compatibility certainty. Anything differing in revision suffix,
   included components (kit vs single part), or with uncertain fitment stays
   separate. Groups expand to show every listing.
5. **Sorts**: lowest delivered price, fastest delivery, OEM only, new only,
   used only, best match. "Best value" from the brief is replaced by "best
   match" (compatibility certainty, then condition, then delivered price),
   because a value score would model prices (§9.5). "Seller confidence"
   becomes a sort by eBay's own feedback % with a minimum feedback count,
   pending eBay's written permission for anything derived.
6. **Explainable match card.** Each result shows separate, plain-language
   lines: fitment ("eBay lists this as fitting your 2008 GSX-R750"), condition
   (eBay's text), seller (eBay's feedback figures, unrated by us), price
   (delivered, with what's missing). No overall trust score; never
   "guaranteed", never "lowest price".

## Remaining actions for the account holder

1. Create an eBay developer account and a production keyset.
2. Apply for Buy API (Browse) access, describing Pull Up's affiliate model.
3. Join EPN and create a campaign. The campaign ID is a build setting,
   not a server setting: set `PULLUP_EPN_CAMPAIGN_ID` as the GitHub
   environment variable the TestFlight workflow writes into
   `Secrets.xcconfig` (or in your own `Secrets.xcconfig`). It reaches the
   app as `PullUpEPNCampaignID` in `Info.plist`. Only the future
   `parts-search` function (Stage B) would need it on the server too.
4. If a derived seller-confidence signal is wanted, request eBay's written
   permission under §8.1(d)(ii).
5. Store `EBAY_CLIENT_ID` / `EBAY_CLIENT_SECRET` as Supabase function secrets
   and deploy `parts-search`.

## Sources

* Browse API overview: https://developer.ebay.com/api-docs/buy/static/api-browse.html
* Buy APIs and approval: https://developer.ebay.com/products/buy
* Call limits and Application Growth Check: https://developer.ebay.com/develop/get-started/api-call-limits
* API License Agreement: https://edp.ebay.com/join/api-license-agreement
* Affiliate program: https://developer.ebay.com/grow/affiliate-program
* EPN disclosure FAQ: https://epnmarketing.ebay.com/resources/affiliate-disclosure-faq
