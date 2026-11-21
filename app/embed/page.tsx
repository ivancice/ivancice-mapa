import ClientMap from '@/components/pages/ClientMap';

export const metadata = { title: 'Ivančice očima pěších a cyklistů – mapa', robots: { index: false } };

// Verze pro vložení do webu pomocí <iframe>
export default function Embed() {
  return <ClientMap embed />;
}
