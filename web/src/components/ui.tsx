import React from 'react';

export const Card: React.FC<React.PropsWithChildren<{ className?: string }>> = ({ className = '', children }) => (
  <section className={`rounded-2xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 ${className}`}>{children}</section>
);

export const Eyebrow: React.FC<React.PropsWithChildren> = ({ children }) => (
  <p className="text-[11px] font-mono uppercase tracking-wide text-slate-500 dark:text-slate-400">{children}</p>
);

export const Notice: React.FC<React.PropsWithChildren<{ tone?: 'info' | 'warn' | 'error' }>> = ({ tone = 'info', children }) => {
  const tones = {
    info: 'bg-blue-50 dark:bg-blue-950/30 border-blue-200 dark:border-blue-900 text-blue-800 dark:text-blue-200',
    warn: 'bg-amber-50 dark:bg-amber-950/30 border-amber-200 dark:border-amber-900 text-amber-800 dark:text-amber-200',
    error: 'bg-red-50 dark:bg-red-950/40 border-red-200 dark:border-red-900 text-red-700 dark:text-red-300',
  };
  return <p role={tone === 'error' ? 'alert' : undefined} className={`rounded-xl border px-3.5 py-2.5 text-sm ${tones[tone]}`}>{children}</p>;
};

export const primaryButton = 'inline-flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-xl bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors';
export const ghostButton = 'inline-flex items-center gap-2 px-3 py-1.5 text-xs font-medium rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 disabled:opacity-50 transition-colors';
export const inputClass = 'w-full rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950 px-3 py-2 text-sm placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500/40';
