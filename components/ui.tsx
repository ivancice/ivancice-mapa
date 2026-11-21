'use client';
import { useEffect, useState, type ReactNode } from 'react';
import clsx from 'clsx';
import {
  Accessibility, Armchair, Baby, Bike, Building2, Bus, Car, Construction, Droplets, Footprints, Landmark, Lightbulb,
  LoaderCircle, MapPin, MessageCircle, Route, ShieldAlert, Signpost, SquareParking, TrafficCone, TreePine, Trees, X,
  type LucideIcon
} from 'lucide-react';

export const ICONS: Record<string, LucideIcon> = {
  footprints: Footprints, bike: Bike, car: Car, accessibility: Accessibility, trees: Trees, route: Route,
  'message-circle': MessageCircle, 'map-pin': MapPin, bus: Bus, lightbulb: Lightbulb, 'tree-pine': TreePine,
  shield: ShieldAlert, baby: Baby, parking: SquareParking, construction: Construction, droplets: Droplets,
  building: Building2, landmark: Landmark, bench: Armchair, signpost: Signpost, 'traffic-cone': TrafficCone
};

export const ICON_NAMES = Object.keys(ICONS);

export function CategoryIcon({ icon, className }: { icon: string; className?: string }) {
  const I = ICONS[icon] ?? MapPin;
  return <I className={className} aria-hidden />;
}

export function CategoryBadge({ color, icon, size = 'md' }: { color: string; icon: string; size?: 'sm' | 'md' | 'lg' }) {
  const s = size === 'sm' ? 'h-6 w-6' : size === 'lg' ? 'h-11 w-11' : 'h-8 w-8';
  const i = size === 'sm' ? 'h-3.5 w-3.5' : size === 'lg' ? 'h-6 w-6' : 'h-[18px] w-[18px]';
  return (
    <span className={clsx('inline-flex shrink-0 items-center justify-center rounded-full text-white', s)} style={{ backgroundColor: color }}>
      <CategoryIcon icon={icon} className={i} />
    </span>
  );
}

export function Spinner({ className }: { className?: string }) {
  return <LoaderCircle className={clsx('animate-spin', className ?? 'h-5 w-5')} aria-label="Načítání" />;
}

type BtnVariant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'outline';
export function Button({
  children, variant = 'secondary', className, loading, ...rest
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: BtnVariant; loading?: boolean }) {
  return (
    <button
      {...rest}
      disabled={rest.disabled || loading}
      className={clsx(
        'inline-flex items-center justify-center gap-2 rounded-xl px-4 py-2.5 text-sm font-semibold transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-50',
        variant === 'primary' && 'bg-brand-600 text-white shadow-sm hover:bg-brand-700',
        variant === 'secondary' && 'bg-slate-100 text-ink hover:bg-slate-200',
        variant === 'outline' && 'border border-slate-300 bg-white text-ink hover:bg-slate-50',
        variant === 'ghost' && 'text-ink-soft hover:bg-slate-100',
        variant === 'danger' && 'bg-red-600 text-white hover:bg-red-700',
        className
      )}
    >
      {loading && <Spinner className="h-4 w-4" />}
      {children}
    </button>
  );
}

/** Panel: na mobilu spodní vysouvací list, na počítači boční panel vpravo */
export function Sheet({
  open, onClose, title, children, wide, footer, z = 30
}: { open: boolean; onClose?: () => void; title?: ReactNode; children: ReactNode; wide?: boolean; footer?: ReactNode; z?: number }) {
  if (!open) return null;
  return (
    <section
      className={clsx(
        'fixed inset-x-0 bottom-0 flex max-h-[82dvh] flex-col rounded-t-3xl bg-white shadow-panel animate-sheet-up',
        'md:inset-y-3 md:bottom-3 md:left-auto md:right-3 md:max-h-none md:rounded-3xl',
        wide ? 'md:w-[520px]' : 'md:w-[420px]'
      )}
      style={{ zIndex: z }}
      role="dialog"
      aria-modal="false"
    >
      <div className="mx-auto mt-2 h-1.5 w-10 rounded-full bg-slate-300 md:hidden" />
      {(title || onClose) && (
        <header className="flex items-start gap-3 px-5 pb-2 pt-3 md:pt-5">
          <div className="min-w-0 flex-1 text-lg font-bold leading-tight text-ink">{title}</div>
          {onClose && (
            <button onClick={onClose} className="-mr-1 rounded-full p-1.5 text-ink-soft hover:bg-slate-100" aria-label="Zavřít">
              <X className="h-5 w-5" />
            </button>
          )}
        </header>
      )}
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pb-5">{children}</div>
      {footer && <footer className="border-t border-slate-100 px-5 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">{footer}</footer>}
    </section>
  );
}

export function Modal({ open, onClose, title, children, footer }: { open: boolean; onClose?: () => void; title?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  useEffect(() => {
    if (!open) return;
    const h = (e: KeyboardEvent) => e.key === 'Escape' && onClose?.();
    window.addEventListener('keydown', h);
    return () => window.removeEventListener('keydown', h);
  }, [open, onClose]);
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-slate-900/40 p-0 sm:items-center sm:p-4" onClick={onClose}>
      <div
        className="flex max-h-[90dvh] w-full max-w-lg flex-col rounded-t-3xl bg-white shadow-panel sm:rounded-3xl"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
      >
        <header className="flex items-start gap-3 px-6 pb-2 pt-5">
          <div className="min-w-0 flex-1 text-lg font-bold text-ink">{title}</div>
          {onClose && (
            <button onClick={onClose} className="rounded-full p-1.5 text-ink-soft hover:bg-slate-100" aria-label="Zavřít">
              <X className="h-5 w-5" />
            </button>
          )}
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-5">{children}</div>
        {footer && <footer className="flex flex-wrap justify-end gap-2 border-t border-slate-100 px-6 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">{footer}</footer>}
      </div>
    </div>
  );
}

export function Field({ label, required, hint, children, error }: { label: ReactNode; required?: boolean; hint?: ReactNode; children: ReactNode; error?: string | null }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-semibold text-ink">
        {label} {required ? <span className="text-red-600">*</span> : <span className="font-normal text-ink-faint">(nepovinné)</span>}
      </span>
      {children}
      {hint && <span className="mt-1 block text-xs text-ink-soft">{hint}</span>}
      {error && <span className="mt-1 block text-xs font-medium text-red-600">{error}</span>}
    </label>
  );
}

export const inputCls =
  'block w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-[15px] text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-200';

// --- toasty -------------------------------------------------------------------
type ToastMsg = { id: number; text: string; kind: 'ok' | 'error' | 'info' };
let pushToast: ((t: Omit<ToastMsg, 'id'>) => void) | null = null;
export function toast(text: string, kind: ToastMsg['kind'] = 'ok') {
  pushToast?.({ text, kind });
}

export function Toaster() {
  const [items, setItems] = useState<ToastMsg[]>([]);
  useEffect(() => {
    let id = 0;
    pushToast = (t) => {
      const m = { ...t, id: ++id };
      setItems((x) => [...x.slice(-1), m]);
      setTimeout(() => setItems((x) => x.filter((y) => y.id !== m.id)), t.kind === 'error' ? 7000 : 4000);
    };
    return () => {
      pushToast = null;
    };
  }, []);
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-24 z-[60] flex flex-col items-center gap-2 px-3 md:bottom-auto md:top-3" aria-live="polite">
      {items.map((t) => (
        <div
          key={t.id}
          className={clsx(
            'pointer-events-auto max-w-md rounded-2xl px-4 py-3 text-sm font-medium shadow-panel',
            t.kind === 'ok' && 'bg-brand-700 text-white',
            t.kind === 'error' && 'bg-red-600 text-white',
            t.kind === 'info' && 'bg-slate-800 text-white'
          )}
        >
          {t.text}
        </div>
      ))}
    </div>
  );
}
