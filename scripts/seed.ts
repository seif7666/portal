// Loads the provided exports through the same import pipeline the Imports
// page uses, signed in as each brand's owner. Safe to re-run: a second run
// reports every row as unchanged.
//
//   npm run seed                      # all brands
//   npm run seed -- marrakech karoo   # some brands
//
// Data directory: SEED_DATA_DIR, default: the folder containing this repo.
import { readFileSync, statSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { readFile, exportDateFromName, type ImportKind } from '../web/src/lib/import/readFile.ts';
import { runImport } from '../web/src/lib/import/runImport.ts';
import { account, type BrandSlug } from './accounts.ts';

const dataDir = resolve(process.env.SEED_DATA_DIR ?? join(import.meta.dirname, '..', '..'));

// Order matters: events and the send log reference contacts and campaigns.
const PLAN: Record<BrandSlug, { file: string; kind: ImportKind }[]> = {
  kilele: [
    { file: 'kilele-contacts.csv', kind: 'contacts' },
    { file: 'kilele-contacts-delta-2026-09-01.csv', kind: 'contacts' },
    { file: 'kilele-campaigns.csv', kind: 'campaigns' },
    { file: 'kilele-events.csv', kind: 'events' },
    { file: 'kilele-send-log.csv', kind: 'send_log' },
  ],
  karoo: [
    { file: 'karoo-contacts.csv', kind: 'contacts' },
    { file: 'karoo-campaigns.csv', kind: 'campaigns' },
    { file: 'karoo-events.csv', kind: 'events' },
  ],
  marrakech: [
    { file: 'marrakech-contacts.csv', kind: 'contacts' },
    { file: 'marrakech-campaigns.csv', kind: 'campaigns' },
    { file: 'marrakech-events.csv', kind: 'events' },
  ],
};

const requested = process.argv.slice(2) as BrandSlug[];
const brands = requested.length ? requested : (Object.keys(PLAN) as BrandSlug[]);

for (const brand of brands) {
  if (!PLAN[brand]) throw new Error(`unknown brand ${brand}`);
  const owner = account(brand, 'owner');
  const supabase = createClient(process.env.VITE_SUPABASE_URL!, process.env.VITE_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false },
  });
  const { error: authError } = await supabase.auth.signInWithPassword({ email: owner.email, password: owner.password });
  if (authError) throw new Error(`${brand} owner sign-in: ${authError.message}`);
  const { data: me } = await supabase.rpc('my_membership');
  const brandId: string = me[0].brand_id;

  for (const step of PLAN[brand]) {
    const path = join(dataDir, step.file);
    if (!existsSync(path)) {
      console.warn(`skip ${step.file}: not found in ${dataDir}`);
      continue;
    }
    const bytes = new Uint8Array(readFileSync(path));
    const parsed = await readFile(bytes);
    // Export date: from the file name if it carries one, else the file's modified date.
    const exportedAt = exportDateFromName(step.file) ?? statSync(path).mtime.toISOString().slice(0, 10);
    const t0 = Date.now();
    let lastPct = -1;
    const { runId } = await runImport(supabase, {
      brandId,
      kind: step.kind,
      fileName: step.file,
      file: parsed,
      exportedAt,
      onProgress: (p) => {
        const pct = p.rowsTotal ? Math.floor((p.rowsSent / p.rowsTotal) * 10) * 10 : 100;
        if (p.phase === 'loading' && pct !== lastPct) {
          lastPct = pct;
          process.stdout.write(`\r${step.file}: ${pct}%   `);
        }
      },
    });
    const { data: run } = await supabase.from('import_runs').select('*').eq('id', runId).single();
    console.log(
      `\r${step.file.padEnd(40)} ${parsed.encoding}/${JSON.stringify(parsed.delimiter)} ` +
        `rows=${run.rows_total} +${run.rows_inserted} ~${run.rows_updated} =${run.rows_unchanged} ` +
        `superseded=${run.rows_superseded} rejected=${run.rows_rejected} warned=${run.rows_warned} ` +
        `blank=${run.blank_lines} status=${run.status} (${((Date.now() - t0) / 1000).toFixed(1)}s)`,
    );
  }
  await supabase.auth.signOut();
}
