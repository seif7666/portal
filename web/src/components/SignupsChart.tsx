// Signups per day: one series, so one hue, no legend (the card title names it),
// thin bars with rounded data-ends on the baseline, recessive grid, and a
// per-bar hover tooltip. A table view sits behind a toggle for screen readers.
import { useState } from 'react';
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import type { SignupsPerDay } from '../lib/queries';
import { fmtInt } from '../lib/format';

const BAR = '#4f46e5';

function label(day: string, opts: Intl.DateTimeFormatOptions) {
  // days are calendar dates in the brand timezone; format them as dates, not instants
  const [y, m, d] = day.split('-').map(Number);
  return new Intl.DateTimeFormat('en-GB', { ...opts, timeZone: 'UTC' }).format(new Date(Date.UTC(y, m - 1, d)));
}

export function SignupsChart({ data }: { data: SignupsPerDay }) {
  const [asTable, setAsTable] = useState(false);
  const rows = data.days.map((d) => ({ ...d, short: label(d.day, { day: 'numeric', month: 'short' }) }));

  return (
    <div>
      <div className="mb-3 flex justify-end">
        <button onClick={() => setAsTable((t) => !t)} className="text-xs font-medium text-brand-700 hover:underline">
          {asTable ? 'Show chart' : 'Show as table'}
        </button>
      </div>
      {asTable ? (
        <div className="max-h-72 overflow-y-auto">
          <table className="min-w-full text-sm">
            <thead><tr className="text-left text-xs text-slate-500"><th className="py-1">Day ({data.timezone})</th><th className="py-1 text-right">Signups</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.day}><td className="py-1">{label(r.day, { weekday: 'short', day: 'numeric', month: 'short' })}</td><td className="tabular py-1 text-right">{fmtInt(r.signups)}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="h-64 w-full" role="img" aria-label={`Signups per day from ${data.from} to ${data.to}, ${data.total_in_window} in total`}>
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={rows} margin={{ top: 4, right: 4, left: -16, bottom: 0 }} barCategoryGap={2}>
              <CartesianGrid vertical={false} stroke="#e2e8f0" strokeDasharray="0" />
              <XAxis dataKey="short" tickLine={false} axisLine={{ stroke: '#cbd5e1' }} tick={{ fontSize: 11, fill: '#64748b' }} interval="preserveStartEnd" minTickGap={16} />
              <YAxis allowDecimals={false} tickLine={false} axisLine={false} tick={{ fontSize: 11, fill: '#64748b' }} width={44} />
              <Tooltip
                cursor={{ fill: '#eef2ff' }}
                content={({ active, payload }) => {
                  if (!active || !payload?.length) return null;
                  const p = payload[0].payload as (typeof rows)[number];
                  return (
                    <div className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs shadow-md">
                      <p className="text-slate-500">{label(p.day, { weekday: 'long', day: 'numeric', month: 'long' })}</p>
                      <p className="tabular mt-0.5 text-sm font-semibold text-slate-900">{fmtInt(p.signups)} signups</p>
                    </div>
                  );
                }}
              />
              <Bar dataKey="signups" fill={BAR} radius={[4, 4, 0, 0]} maxBarSize={28} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}
