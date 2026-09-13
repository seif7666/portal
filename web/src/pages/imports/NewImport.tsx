import { useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { useQueryClient } from '@tanstack/react-query';
import { supabase, errorMessage } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtBytes, fmtInt } from '../../lib/format';
import { exportDateFromName, guessKind, type ImportKind, type ParsedFile } from '../../lib/import/readFile';
import { runImport, type ImportProgress } from '../../lib/import/runImport';
import { Button, Card, Spinner } from '../../components/ui';
import { KIND_LABEL } from './importStatus';

const MAX_BYTES = 100 * 1024 * 1024;

type Stage =
  | { name: 'idle' }
  | { name: 'parsing'; fileName: string }
  | { name: 'ready'; fileName: string; lastModified: number; parsed: ParsedFile }
  | { name: 'importing'; fileName: string; progress: ImportProgress }
  | { name: 'error'; message: string };

function parseInWorker(buffer: ArrayBuffer): Promise<ParsedFile> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('../../lib/import/parse.worker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (e) => {
      worker.terminate();
      if (e.data.ok) resolve(e.data.parsed);
      else reject(new Error(e.data.error));
    };
    worker.onerror = (e) => {
      worker.terminate();
      reject(new Error(e.message || 'Could not read the file'));
    };
    worker.postMessage(buffer, [buffer]);
  });
}

export function NewImport() {
  const brand = useBrand();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const inputRef = useRef<HTMLInputElement>(null);
  const [stage, setStage] = useState<Stage>({ name: 'idle' });
  const [kind, setKind] = useState<ImportKind | ''>('');
  const [exportDate, setExportDate] = useState('');

  async function onFile(file: File | undefined) {
    if (!file) return;
    if (file.size > MAX_BYTES) {
      setStage({ name: 'error', message: `This file is ${fmtBytes(file.size)}; the limit is ${fmtBytes(MAX_BYTES)}.` });
      return;
    }
    if (file.size === 0) {
      setStage({ name: 'error', message: 'This file is empty.' });
      return;
    }
    setStage({ name: 'parsing', fileName: file.name });
    try {
      const parsed = await parseInWorker(await file.arrayBuffer());
      if (parsed.header.length < 2) throw new Error('This does not look like a CSV export (no header row with columns).');
      setKind(guessKind(parsed.header) ?? '');
      setExportDate(exportDateFromName(file.name) ?? new Date(file.lastModified).toISOString().slice(0, 10));
      setStage({ name: 'ready', fileName: file.name, lastModified: file.lastModified, parsed });
    } catch (e) {
      setStage({ name: 'error', message: errorMessage(e) });
    }
  }

  async function onStart() {
    if (stage.name !== 'ready' || !kind || !exportDate) return;
    const { parsed, fileName } = stage;
    let runId: string | undefined;
    try {
      const result = await runImport(supabase, {
        brandId: brand.brand_id,
        kind,
        fileName,
        file: parsed,
        exportedAt: exportDate,
        onProgress: (progress) => {
          runId = progress.runId ?? runId;
          setStage({ name: 'importing', fileName, progress });
        },
      });
      runId = result.runId;
    } catch (e) {
      if (!runId) {
        setStage({ name: 'error', message: errorMessage(e) });
        return;
      }
    }
    await queryClient.invalidateQueries();
    if (runId) navigate(runId);
  }

  function reset() {
    setStage({ name: 'idle' });
    if (inputRef.current) inputRef.current.value = '';
  }

  return (
    <Card title="Load an export">
      {stage.name === 'idle' || stage.name === 'error' ? (
        <div>
          <label className="flex cursor-pointer flex-col items-center justify-center rounded-lg border-2 border-dashed border-slate-300 px-4 py-8 text-center hover:border-brand-500 hover:bg-brand-50/40">
            <svg className="h-8 w-8 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5} aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
            </svg>
            <span className="mt-2 text-sm font-medium text-slate-700">Choose a CSV file</span>
            <span className="mt-1 text-xs text-slate-500">Contacts, campaigns, engagement events or send log. Comma or semicolon separated, any common encoding.</span>
            <input ref={inputRef} type="file" accept=".csv,.txt,text/csv" className="sr-only" onChange={(e) => onFile(e.target.files?.[0])} />
          </label>
          {stage.name === 'error' && <p role="alert" className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{stage.message}</p>}
        </div>
      ) : stage.name === 'parsing' ? (
        <div className="flex items-center gap-3 py-6 text-sm text-slate-600"><Spinner /> Reading {stage.fileName}…</div>
      ) : stage.name === 'ready' ? (
        <div className="space-y-5">
          <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Info label="File" value={stage.fileName} />
            <Info label="Rows" value={fmtInt(stage.parsed.rows.length)} />
            <Info label="Encoding" value={stage.parsed.encoding === 'utf-8' ? 'UTF-8' : 'Windows-1252'} />
            <Info label="Separator" value={stage.parsed.delimiter === ';' ? 'Semicolon' : stage.parsed.delimiter === ',' ? 'Comma' : 'Other'} />
          </dl>
          <p className="text-xs break-words text-slate-500">Columns: {stage.parsed.header.join(' · ')}</p>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="block">
              <span className="text-sm font-medium text-slate-700">What is in this file?</span>
              <select value={kind} onChange={(e) => setKind(e.target.value as ImportKind)} className="mt-1 block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="">Select…</option>
                {(Object.keys(KIND_LABEL) as ImportKind[]).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
              </select>
            </label>
            <label className="block">
              <span className="text-sm font-medium text-slate-700">Export date</span>
              <input type="date" value={exportDate} max={new Date().toISOString().slice(0, 10)} onChange={(e) => setExportDate(e.target.value)} className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              <span className="mt-1 block text-xs text-slate-500">When the file was exported. If a contact already came from a newer export, this file will not overwrite it.</span>
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button onClick={onStart} disabled={!kind || !exportDate}>Load {fmtInt(stage.parsed.rows.length)} rows</Button>
            <Button variant="secondary" onClick={reset}>Cancel</Button>
          </div>
        </div>
      ) : (
        <div className="py-2">
          <div className="flex items-center justify-between text-sm">
            <span className="font-medium text-slate-700">
              {stage.progress.phase === 'failed' ? 'Import stopped' : `Loading ${stage.fileName}…`}
            </span>
            <span className="tabular text-slate-500">{fmtInt(stage.progress.rowsSent)} / {fmtInt(stage.progress.rowsTotal)}</span>
          </div>
          <div className="mt-2 h-2 overflow-hidden rounded-full bg-slate-100">
            <div className="h-full bg-brand-600 transition-all" style={{ width: `${stage.progress.rowsTotal ? (stage.progress.rowsSent / stage.progress.rowsTotal) * 100 : 100}%` }} />
          </div>
          {stage.progress.message && <p className="mt-3 text-sm text-red-700">{stage.progress.message}</p>}
          <p className="mt-2 text-xs text-slate-500">Keep this tab open. If it is interrupted, load the same file again: rows already loaded are recognised and not duplicated.</p>
        </div>
      )}
    </Card>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0 rounded-lg bg-slate-50 px-3 py-2">
      <dt className="text-xs text-slate-500">{label}</dt>
      <dd className="truncate font-medium text-slate-800" title={value}>{value}</dd>
    </div>
  );
}
