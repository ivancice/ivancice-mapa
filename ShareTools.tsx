'use client';
import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { Copy, Download } from 'lucide-react';
import { siteUrl } from '@/lib/env';
import { Button, inputCls } from '@/components/ui';

export default function ShareTools() {
  const [url, setUrl] = useState('');
  const [qr, setQr] = useState('');
  const [copied, setCopied] = useState<string | null>(null);
  useEffect(() => {
    const u = siteUrl();
    setUrl(u);
    QRCode.toDataURL(u, { width: 640, margin: 2, color: { dark: '#123e32', light: '#ffffff' } }).then(setQr);
  }, []);
  const iframe = `<iframe src="${url}/embed/" width="100%" height="640" style="border:0;border-radius:12px" loading="lazy" allow="geolocation; camera" title="Ivančice očima pěších a cyklistů"></iframe>`;
  const copy = async (t: string, k: string) => {
    await navigator.clipboard.writeText(t);
    setCopied(k);
    setTimeout(() => setCopied(null), 2000);
  };
  return (
    <div className="mt-4 grid gap-6 md:grid-cols-[1fr_220px]">
      <div className="space-y-4">
        <div>
          <div className="mb-1 text-sm font-semibold">Odkaz na mapu</div>
          <div className="flex gap-2">
            <input readOnly value={url} className={inputCls} onFocus={(e) => e.target.select()} />
            <Button variant="outline" onClick={() => copy(url, 'url')}><Copy className="h-4 w-4" />{copied === 'url' ? 'Zkopírováno' : 'Kopírovat'}</Button>
          </div>
        </div>
        <div>
          <div className="mb-1 text-sm font-semibold">Vložení do webových stránek (iframe)</div>
          <textarea readOnly value={iframe} className={`${inputCls} h-28 font-mono text-xs`} onFocus={(e) => e.target.select()} />
          <Button variant="outline" className="mt-2" onClick={() => copy(iframe, 'iframe')}><Copy className="h-4 w-4" />{copied === 'iframe' ? 'Zkopírováno' : 'Kopírovat kód'}</Button>
        </div>
      </div>
      <div className="text-center">
        <div className="mb-1 text-sm font-semibold">QR kód (plakáty, letáky)</div>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        {qr && <img src={qr} alt="QR kód s odkazem na mapu" className="mx-auto w-48 rounded-xl border" />}
        {qr && <a href={qr} download="ivancice-mapa-qr.png" className="mt-2 inline-flex items-center gap-1 text-sm font-semibold text-brand-700"><Download className="h-4 w-4" /> Stáhnout PNG</a>}
      </div>
    </div>
  );
}
