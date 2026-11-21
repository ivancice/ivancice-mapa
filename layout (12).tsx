import type { Metadata, Viewport } from 'next';
import 'maplibre-gl/dist/maplibre-gl.css';
import './globals.css';
import { BASE_PATH, SITE_URL } from '@/lib/env';

export const metadata: Metadata = {
  metadataBase: SITE_URL ? new URL(SITE_URL) : undefined,
  title: 'Ivančice očima pěších a cyklistů',
  description: 'Společně mapujeme, jak se nám v Ivančicích chodí, jezdí na kole a žije. Participativní mapa dopravy, mobility a veřejného prostoru.',
  openGraph: {
    title: 'Ivančice očima pěších a cyklistů',
    description: 'Označte problematická místa, navrhněte zlepšení a podpořte podněty ostatních.',
    locale: 'cs_CZ',
    type: 'website'
  },
  icons: { icon: `${BASE_PATH}/icon.svg` },
  manifest: `${BASE_PATH}/manifest.webmanifest`
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,
  viewportFit: 'cover',
  themeColor: '#1d7559'
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="cs">
      <body>{children}</body>
    </html>
  );
}
