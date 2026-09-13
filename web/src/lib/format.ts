const intFmt = new Intl.NumberFormat('en-GB');
const pctFmt = new Intl.NumberFormat('en-GB', { style: 'percent', maximumFractionDigits: 1 });

export const fmtInt = (n: number | null | undefined) => (n == null ? '—' : intFmt.format(n));

/** Percentage with an explicit "—" when the denominator is zero or unknown. */
export const fmtPct = (num: number | null | undefined, den: number | null | undefined) =>
  num == null || !den ? '—' : pctFmt.format(num / den);

export const fmtMoney = (n: number | null | undefined) =>
  n == null ? '—' : new Intl.NumberFormat('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);

export function fmtDateTime(iso: string | null | undefined, timeZone?: string) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', {
    dateStyle: 'medium',
    timeStyle: 'short',
    timeZone,
  }).format(new Date(iso));
}

export function fmtDate(iso: string | null | undefined, timeZone?: string) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone }).format(new Date(iso));
}

export function fmtBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 ** 2).toFixed(1)} MB`;
}

export function timeAgo(iso: string) {
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}
