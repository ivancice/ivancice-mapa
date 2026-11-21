'use client';
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { adminApi, type ModerationQueue } from '@/lib/adminApi';
import { errorMessage } from '@/lib/api';
import { Button, Spinner, toast } from '@/components/ui';
import { photoUrl } from '@/lib/env';
import { formatDate } from '@/lib/geo';
import { deleteStoragePhotos } from '@/lib/photos';

const REASON: Record<string, string> = {
  spam: 'Spam', offensive: 'Nevhodný obsah', personal_data: 'Osobní údaje', duplicate: 'Duplicita', wrong_location: 'Špatné umístění', other: 'Jiné'
};

export default function Moderation() {
  const [q, setQ] = useState<ModerationQueue | null>(null);
  const [tab, setTab] = useState<'flags' | 'comments' | 'photos'>('flags');
  const load = useCallback(() => adminApi.moderation().then(setQ).catch((e) => toast(errorMessage(e), 'error')), []);
  useEffect(() => { load(); }, [load]);

  const act = async (fn: () => Promise<unknown>, msg: string) => {
    try { await fn(); toast(msg); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  if (!q) return <div className="flex justify-center p-10"><Spinner /></div>;
  return (
    <div className="space-y-3">
      <h1 className="text-xl font-extrabold">Moderace obsahu</h1>
      <div className="flex gap-1 rounded-2xl bg-white p-1 shadow-sm">
        {([['flags', `Nahlášení (${q.flags.length})`], ['comments', 'Komentáře'], ['photos', 'Fotografie']] as const).map(([k, l]) => (
          <button key={k} onClick={() => setTab(k)} className={clsx('flex-1 rounded-xl py-2 text-sm font-semibold', tab === k ? 'bg-brand-50 text-brand-800' : 'text-ink-soft')}>{l}</button>
        ))}
      </div>

      {tab === 'flags' && (
        <ul className="space-y-2">
          {q.flags.length === 0 && <li className="rounded-2xl bg-white p-4 text-sm text-ink-soft shadow-sm">Žádná otevřená nahlášení. 🎉</li>}
          {q.flags.map((f) => (
            <li key={f.id} className="rounded-2xl bg-white p-4 text-sm shadow-sm">
              <div className="flex flex-wrap items-center gap-2">
                <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-bold text-red-800">{REASON[f.reason] ?? f.reason}</span>
                <span className="text-xs text-ink-faint">{formatDate(f.created_at)}</span>
                {f.report_id && <Link href={`/?p=${f.report_id}`} target="_blank" className="font-semibold hover:underline">{f.report_title}</Link>}
              </div>
              {f.note && <p className="mt-1 text-ink-soft">„{f.note}“</p>}
              {f.comment_body && <p className={clsx('mt-2 rounded-xl bg-slate-50 p-2', f.comment_hidden && 'opacity-50')}>Komentář: {f.comment_body}</p>}
              {f.photo_path && (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={photoUrl(f.photo_path)} alt="" className={clsx('mt-2 h-32 rounded-xl object-cover', f.photo_hidden && 'opacity-40')} />
              )}
              <div className="mt-3 flex flex-wrap gap-2">
                {f.comment_id && <Button variant="outline" className="py-1.5" onClick={() => act(() => adminApi.setCommentHidden(f.comment_id!, true).then(() => adminApi.resolveFlag(f.id, 'comment_hidden')), 'Komentář skryt')}>Skrýt komentář</Button>}
                {f.photo_id && <Button variant="outline" className="py-1.5" onClick={() => act(() => adminApi.setPhotoHidden(f.photo_id!, true).then(() => adminApi.resolveFlag(f.id, 'photo_hidden')), 'Fotografie skryta')}>Skrýt fotografii</Button>}
                {!f.comment_id && !f.photo_id && f.report_id && <Button variant="outline" className="py-1.5" onClick={() => act(() => adminApi.updateReport(f.report_id!, { is_hidden: true, hidden_reason: `nahlášeno: ${f.reason}` }).then(() => adminApi.resolveFlag(f.id, 'report_hidden')), 'Podnět skryt')}>Skrýt podnět</Button>}
                <Button variant="ghost" className="py-1.5" onClick={() => act(() => adminApi.resolveFlag(f.id, 'dismissed'), 'Nahlášení zamítnuto')}>V pořádku – zamítnout</Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {tab === 'comments' && (
        <ul className="space-y-2">
          {q.comments.map((c) => (
            <li key={c.id} className={clsx('rounded-2xl bg-white p-3 text-sm shadow-sm', c.is_hidden && 'opacity-60')}>
              <div className="text-xs text-ink-soft"><b className="text-ink">{c.author_name}</b> · {formatDate(c.created_at)} · <Link href={`/?p=${c.report_id}`} target="_blank" className="hover:underline">{c.report_title}</Link></div>
              <p className="mt-1">{c.body}</p>
              <Button variant="outline" className="mt-2 py-1" onClick={() => act(() => adminApi.setCommentHidden(c.id, !c.is_hidden), c.is_hidden ? 'Zobrazeno' : 'Skryto')}>{c.is_hidden ? 'Znovu zobrazit' : 'Skrýt'}</Button>
            </li>
          ))}
        </ul>
      )}

      {tab === 'photos' && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          {q.photos.map((p) => (
            <div key={p.id} className={clsx('overflow-hidden rounded-2xl bg-white shadow-sm', p.is_hidden && 'opacity-50')}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={photoUrl(p.path)} alt="" className="h-36 w-full object-cover" loading="lazy" />
              <div className="p-2 text-xs">
                <Link href={`/?p=${p.report_id}`} target="_blank" className="line-clamp-1 font-semibold hover:underline">{p.report_title}</Link>
                <div className="mt-1 flex gap-1">
                  <Button variant="outline" className="px-2 py-1 text-xs" onClick={() => act(() => adminApi.setPhotoHidden(p.id, !p.is_hidden), p.is_hidden ? 'Zobrazeno' : 'Skryto')}>{p.is_hidden ? 'Zobrazit' : 'Skrýt'}</Button>
                  <Button variant="ghost" className="px-2 py-1 text-xs text-red-600" onClick={() => confirm('Trvale smazat fotografii?') && act(async () => { const r = await adminApi.deletePhoto(p.id); if (r.path) await deleteStoragePhotos([r.path]); }, 'Smazáno')}>Smazat</Button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
