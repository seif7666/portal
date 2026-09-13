# Velocity Campaign Portal

A multi-brand campaign portal for three client brands (Kilele Rides, Karoo Coaches, Marrakech Express) sharing one Supabase database. Marketers sign in, see only their own brand's contacts, campaigns and dashboard, load exports, send campaigns through the VG messaging provider, and publish password-protected results for clients.

**Stack:** Supabase (Postgres, RLS, Auth, Edge Functions, pg_cron, pg_net, Vault) · Vite + React + TypeScript · Tailwind · TanStack Query · Recharts.

All trusted logic lives in Postgres. The browser holds only the anon key. Every rule about who can see or change what is enforced by RLS and by checked RPCs, not in React.

---

## Where each "done" rule lives

| Rule | How | Where |
|---|---|---|
| **Six logins, own portal, owners send, analysts can't, nobody else gets in** | `memberships` is the allowlist, one brand and role per email. A `before_user_created` auth hook refuses any other email, for password and Google sign-in alike. Owner-only RPCs call `private.assert_member(brand, true)`. | `supabase/migrations/20260913000001_tenancy.sql`, `…000015_auth_allowlist_hook.sql` |
| **A brand sees only its own data, on every route, including future ones** | Every table has `brand_id NOT NULL`, RLS enabled **and forced**, and one SELECT policy `brand_id in (select private.current_brand_ids())`. `authenticated` has no direct writes. Child rows reference parents by `(brand_id, id)`. An event trigger turns on forced RLS for any new public table. | Guarantee: `private.current_brand_ids()` at `supabase/migrations/20260913000001_tenancy.sql:61`. Default-deny: `…000002_default_deny.sql` |
| **Tests fail if isolation is removed** | A structural check fails if any table loses RLS or its policy, a policy becomes `using (true)`, a table lacks `brand_id`, anon gets a grant, a view isn't `security_invoker`, or a SECURITY DEFINER RPC skips the membership check. It proves it has teeth by breaking each rule in a rolled-back transaction. A behavioural suite signs in as each user and tries to cross brands. | `supabase/tests/rls_coverage.sql`, `tests/isolation/*.test.ts` |
| **Data loads, the marketer sees what didn't, a double load leaves one set** | The browser only splits bytes into cells. Postgres validates and normalises every value. Rejected rows go to `import_issues` with a reason and the original row. Upserts are keyed on `(brand_id, external_id)`, and an older export never overwrites a newer one. Chunks are idempotent. | `…000004_import_helpers.sql`, `…000005_import_rpcs.sql`, Imports page |
| **Numbers are right, and say how they were counted** | There is one reachability definition (`contact_reachability`). The dashboard shows an exclusion waterfall that adds up, and each tile has "How this is counted". Campaigns show reported numbers (the export) next to measured ones (unique people from the event log). `scripts/reconcile.py` recounts the dashboard from the raw CSVs in Python, and all three brands match exactly. | `…000008`, `…000010`, `scripts/reconcile.py` |
| **As usable for the 90× brand** | Keyset pagination and server-side search. Suppression flags and campaign stats are precomputed on write. Audiences are built in 5k-contact steps. Every RPC stays under the 8 s API timeout for 82k contacts and 300k events. | `…000010_precomputed_metrics.sql`, `…000016_incremental_prepare.sql` |
| **Sending is safe and honest** | The audience is frozen and hashed. Approval must match the count and hash, and repeat confirms return the same send. There is one live send per campaign. Approvals are immutable (trigger). Batches are leased and posted with `Idempotency-Key = send:chunk` and a byte-identical body. Retries back off, and partial failure is shown. | `…000011_sends.sql`, `…000012_dispatch_internals.sql`, `supabase/functions/dispatch-send` |
| **Provider talks back, contactability stays correct** | pg_cron runs every minute, even with nobody signed in. Events are deduped on event id and applied as set-once facts, so arrival order doesn't matter. Only recipient ids we issued for that batch are trusted. Bounces, unsubscribes and complaints become suppressions. Late reports are caught by periodic full re-reads. | `svc_ingest_provider_events` in `…000012`, `supabase/functions/sync-provider-events` |
| **Shared link is safe for a stranger** | The link token is 256 random bits, and only its SHA-256 is stored. The password is stored as a bcrypt hash. Every failure gets one generic answer, with a dummy bcrypt compare for unknown tokens. Five wrong passwords lock the link for 15 minutes. The page shows aggregates for one campaign only: no ids and no contact data. | `…000014_shared_reports.sql`, `tests/isolation/shared-link.test.ts` |
| **Behaves when things go wrong** | CHECK constraints plus RPC validation mean bad input is rejected, not stored. Every view has explicit loading, empty and error states. | throughout |
| **Real web app** | Responsive, with a sidebar on desktop and cards and a menu on phones. Checked in headless Chrome at 390 px and 1440 px (`scripts/browser-check.ts`). | `web/` |

---

## Data: what the exports contain and what the portal does with it

| Found in the files | Handling |
|---|---|
| `;` delimiters and renamed headers (`e_mail`, `mobile`, `pays`, `Full Name`) | Delimiter sniffed. Headers mapped through an alias table, and unknown columns reported. |
| Karoo contacts are **Windows-1252**, not UTF-8 | Decoded as UTF-8 first, falling back to 1252. The encoding used is shown on the import. |
| Truncated rows (7 or 9 columns), a repeated header, blank lines, **NUL bytes** | Rejected with the line number and reason. |
| **312 Karoo rows in the Kilele file, 88 Kilele rows in Karoo** | Rejected as "belongs to brand X", and loaded into neither brand. |
| Duplicate ids: identical, or differing only by email case | Normalised first. The later row wins and the duplicate is reported. |
| 10 spellings of consent, **10k blanks** | Blank means not given, so not contactable. Stated on screen. |
| `DD/MM/YYYY` dates (748 have day > 12), date-only values | Read in the brand's timezone, with a warning. |
| Invalid emails, `7.77E+08` phones, a `0257…` phone format matching no numbering plan | The customer is kept and the bad field nulled with a warning. Numbers are not guessed. |
| Delta export (2026-09-01): 2,500 corrections + 1,680 new | Applied. Re-loading the older base file later cannot revert the corrections. |
| Duplicate campaigns, and Karoo `CMP-014` naming a **Kilele** parent | Deduped per brand. The parent is kept as text only and never resolved across brands. |
| Reported opens > delivered, clicks > opens, sent ≠ delivered + bounced | Kept and flagged per campaign. |
| 8.4k duplicate events, 633 Marrakech events for campaigns not in the export, ~40% of events dated before the campaign's send | Deduped; orphans rejected with a reason; pre-send events excluded from measured numbers and counted on screen. |
| Send log lists `BATCH-0003` three times | One send, shown once. |

## Provider: what it actually does, verified by probing

Its docs say the report stream is "clean and complete, exactly once, in order". Probing found the following:
- **Same key + same body:** same batch, not re-sent. **Same key + different body:** the *original* batch comes back silently and the new recipients are dropped. So a batch's recipient list is frozen before its first attempt and never changes.
- Empty and malformed requests are "accepted" and create batches, so all validation is ours.
- `since=<event_id>` doesn't filter. `since=<next_cursor>` does.
- Reports arrive late, duplicated and out of order, and include **forged events**: recipient ids that were never sent, stamped with another brand's `brand_code`. Those are quarantined with a reason and never applied.

---

## Where a send's progress and results are recorded

| Table | Contents |
|---|---|
| `sends` | One row per send. Includes status, the frozen `recipient_count` and `audience_hash`, and `approved_by_email`, `approved_at` and `approved_count`, which are immutable. |
| `send_chunks` | One row per provider batch. Includes `idempotency_key`, `attempts`, `provider_batch_id`, accepted and rejected counts, `last_error`, and the report cursor and completeness. |
| `send_recipients` | The frozen audience. Each row has `dispatch_status`, `skip_reason`, and delivery facts (`delivered_at`, `bounced_at`, `opened_at`, …). Its `id` is the id sent to the provider. |
| `provider_events` | Every report as received (`raw`), marked `applied` or `quarantined` with a reason. |
| `suppressions` | Bounces, unsubscribes and complaints, from both history and the provider. |

In the app, open **Campaign → Sends from this portal → Details**, at `/b/<brand>/sends/<id>`.

---

## Supabase

- **Key used by the deployed app:** the **anon** key only. The service-role key is used only by edge functions and admin scripts, never shipped to the browser.
- **Tables:** `brands`, `memberships`, `contacts`, `campaigns`, `engagement_events`, `legacy_sends`, `import_runs`, `import_run_chunks`, `import_issues`, `suppressions`, `contact_suppression_flags`, `campaign_event_stats`, `sends`, `send_chunks`, `send_recipients`, `provider_events`, `shared_reports`.
- **View:** `contact_reachability` (security invoker).
- **RPCs (authenticated):**
  - `my_membership`
  - Dashboard and lists: `dashboard_summary`, `signups_per_day`, `campaign_performance`, `list_contacts`
  - Imports: `import_start`, `import_chunk`, `import_finish`, `import_abort`, `import_issue_summary`
  - Sends: `prepare_send`, `prepare_send_step`, `approve_send`, `cancel_send`, `send_recipients_page`, `send_summary`
  - Share links: `create_share_link`, `revoke_share_link`
- **RPC (anon):** `shared_report_open`.
- **Service role only:** `svc_sends_to_dispatch`, `svc_claim_chunk`, `svc_record_chunk_result`, `svc_chunks_to_sync`, `svc_ingest_provider_events`.
- **Edge functions:** `dispatch-send`, `sync-provider-events`. Scheduled every minute by `pg_cron` via `pg_net`, with the secret held in Vault.
- **Auth hook:** `private.hook_before_user_created`.

`schema.sql` is every migration concatenated (`npm run schema`). The migrations in `supabase/migrations` are the source of truth.

---

## Running it

```bash
cp .env.example .env            # fill in: see comments in the file
npm install && (cd web && npm install)

npx supabase db push --db-url "$SUPABASE_DB_URL"   # schema, RLS, RPCs, cron
npm run provision               # the six accounts + allowlist, from .env
npm run setup-cron              # Vault + edge function secrets
npm run deploy:functions -- --project-ref "$SUPABASE_PROJECT_REF"
npm run seed                    # loads the CSVs (one folder up) through the import pipeline, as each owner

cd web && npm run dev           # http://localhost:5173
```

The seed data is not committed. Download it from the brief's URL (SHA-256 `4961a25b…35c`) and unzip it next to this folder, or set `SEED_DATA_DIR`.

### Tests and checks

```bash
npm test                         # isolation: RLS coverage, cross-brand as each user, shared link, sign-up refusal
python scripts/reconcile.py      # independent recount of dashboard numbers from the raw CSVs
npm run time-rpcs -- kilele      # API timings for the largest brand
npm run browser-check -- kilele analyst /dashboard /contacts   # real Chrome, console/page errors
npm run send-drill -- <brand> <campaign>                       # SENDS: concurrent confirms + crash recovery
```

---

## Decisions worth knowing

- **Contactable** means: not deleted, status active, consent explicitly yes, not suppressed by date, never unsubscribed or complained (sticky, across channels), and a valid, non-bounced address for the channel. Bounces suppress the *address*, so a corrected address becomes reachable again.
- **Measured campaign numbers** count people, not events, and exclude events dated before the campaign's send time.
- **Signups per day** covers the 30 calendar days ending today in the brand's timezone. Karoo's and Marrakech's latest signups are in April, so their charts are empty and say so.
- **Changes after approval:** someone who stops being contactable between approval and their batch going out is skipped, with a reason. The approved count stays as approved, with "sent X, skipped Y" beside it.

## AI tools

Built with **Claude Code** (Anthropic), used for data profiling, SQL, TypeScript and the test harness, and reviewed and driven step by step.
