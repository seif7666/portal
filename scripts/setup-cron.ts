// One-off (idempotent) wiring for the scheduler, kept out of migrations because
// the values are per-project secrets and the repo is public:
//   * Vault: project_url + cron_secret, read by private.invoke_edge_function()
//   * Edge function secrets: CRON_SECRET, DISPATCHER_API_KEY, DISPATCHER_BASE_URL
//
//   npm run setup-cron
import pg from 'pg';
import { execFileSync } from 'node:child_process';
import 'dotenv/config';

const need = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} missing in .env`);
  return v;
};

const db = new pg.Client({ connectionString: need('SUPABASE_DB_URL'), ssl: { rejectUnauthorized: false } });
await db.connect();
for (const [name, value] of [['project_url', need('VITE_SUPABASE_URL')], ['cron_secret', need('CRON_SECRET')]]) {
  const { rows } = await db.query('select id from vault.secrets where name = $1', [name]);
  if (rows.length) await db.query('select vault.update_secret($1, $2)', [rows[0].id, value]);
  else await db.query('select vault.create_secret($1, $2)', [value, name]);
  console.log(`vault secret ${name}: set`);
}
await db.end();

execFileSync(
  'npx',
  ['--yes', 'supabase@latest', 'secrets', 'set', '--project-ref', need('SUPABASE_PROJECT_REF'),
    `CRON_SECRET=${need('CRON_SECRET')}`, `DISPATCHER_API_KEY=${need('DISPATCHER_API_KEY')}`, `DISPATCHER_BASE_URL=${need('DISPATCHER_BASE_URL')}`],
  { stdio: ['ignore', 'inherit', 'inherit'], env: process.env, shell: process.platform === 'win32' },
);
console.log('edge function secrets: set');
