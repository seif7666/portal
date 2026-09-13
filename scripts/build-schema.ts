// schema.sql = every migration, in order. The migrations are the source of
// truth for the database; this is the single-file view of them.
//   npm run schema
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = join(import.meta.dirname, '..', 'supabase', 'migrations');
const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
const out = [
  '-- Velocity Campaign Portal: complete database schema',
  '-- Generated from supabase/migrations by `npm run schema`. Apply migrations, not this file,',
  '-- to a live project (supabase db push); this file is for reading and review.',
  '',
  ...files.flatMap((f) => [`-- ${'='.repeat(76)}`, `-- ${f}`, `-- ${'='.repeat(76)}`, readFileSync(join(dir, f), 'utf8').trim(), '']),
].join('\n');
writeFileSync(join(import.meta.dirname, '..', 'schema.sql'), out);
console.log(`schema.sql written from ${files.length} migrations`);
