// Turns the bytes of an export into a header and rows of cells.
//
// Deliberately makes no judgement about the data: no trimming, no type
// conversion, no dropping of odd rows. Everything that decides what is valid
// happens server-side in the import RPCs, so the same rules apply whether a
// file comes from this browser, a script, or a hand-crafted API call.
// Runs in the browser and in Node (scripts/seed.ts).
import Papa from 'papaparse';

export type Encoding = 'utf-8' | 'windows-1252';
export type Delimiter = ',' | ';' | '\t' | '|';

export interface ParsedRow {
  /** 1-based line number in the file where this record starts (header is line 1). */
  n: number;
  /** Raw cell strings, exactly as in the file. */
  c: string[];
}

export interface ParsedFile {
  encoding: Encoding;
  delimiter: Delimiter;
  header: string[];
  rows: ParsedRow[];
  sha256: string;
  sizeBytes: number;
}

const DELIMITERS: Delimiter[] = [',', ';', '\t', '|'];

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** UTF-8 if the bytes are valid UTF-8, otherwise Windows-1252 (Excel's default on Windows). */
export function decode(bytes: Uint8Array): { text: string; encoding: Encoding } {
  try {
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes);
    return { text, encoding: 'utf-8' };
  } catch {
    return { text: new TextDecoder('windows-1252').decode(bytes), encoding: 'windows-1252' };
  }
}

/** Picks the candidate delimiter that splits the header line into the most columns (quotes respected). */
export function detectDelimiter(text: string): Delimiter {
  const firstLine = text.slice(0, Math.max(text.indexOf('\n'), 0) || text.length);
  let best: Delimiter = ',';
  let bestCount = 0;
  for (const d of DELIMITERS) {
    const cols = Papa.parse<string[]>(firstLine, { delimiter: d }).data[0]?.length ?? 0;
    if (cols > bestCount) {
      best = d;
      bestCount = cols;
    }
  }
  return best;
}

export async function readFile(bytes: Uint8Array): Promise<ParsedFile> {
  const { text, encoding } = decode(bytes);
  const delimiter = detectDelimiter(text);

  const records: ParsedRow[] = [];
  let line = 1;          // line where the next record starts
  let consumed = 0;      // characters consumed so far
  Papa.parse<string[]>(text, {
    delimiter,
    skipEmptyLines: false,
    step: (result) => {
      // NUL cannot travel in JSON to Postgres. Mark it with U+FFFD so the
      // server sees it and rejects the row, instead of this reader dropping it.
      records.push({ n: line, c: result.data.map((cell) => cell.replaceAll('\u0000', '\uFFFD')) });
      const cursor = result.meta.cursor;
      for (let i = consumed; i < cursor; i++) if (text.charCodeAt(i) === 10) line++;
      consumed = cursor;
    },
  });

  // A trailing newline at end of file is not a blank row.
  while (records.length > 0) {
    const last = records[records.length - 1];
    if (last.c.length === 1 && last.c[0] === '') records.pop();
    else break;
  }

  const [headerRecord, ...rows] = records;
  return {
    encoding,
    delimiter,
    header: (headerRecord?.c ?? []).map((h) => h.replace(/^﻿/, '')),
    rows,
    sha256: await sha256Hex(bytes),
    sizeBytes: bytes.byteLength,
  };
}

export type ImportKind = 'contacts' | 'campaigns' | 'events' | 'send_log';

/** Best guess from the header, for pre-selecting the kind in the UI. The server re-checks. */
export function guessKind(header: string[]): ImportKind | null {
  const h = new Set(header.map((x) => x.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')));
  if (h.has('event_id') || h.has('event_type')) return 'events';
  if (h.has('batch_key')) return 'send_log';
  if (h.has('campaign_name') || h.has('reported_sent')) return 'campaigns';
  if (h.has('email') || h.has('e_mail') || h.has('phone') || h.has('mobile')) return 'contacts';
  return null;
}

/** Export date from a name like "kilele-contacts-delta-2026-09-01.csv", if present. */
export function exportDateFromName(name: string): string | null {
  const m = name.match(/(20\d{2})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}
