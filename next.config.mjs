/** @type {import('next').NextConfig} */

// Aplikace se sestavuje jako čistě statický web (složka `out/`), který lze vystavit
// na libovolném webhostingu nebo zdarma na GitHub Pages – bez vlastního serveru.
// Pokud web neběží v kořeni domény (např. https://spolek.github.io/ivancice-mapa/),
// nastavte NEXT_PUBLIC_BASE_PATH="/ivancice-mapa".
const basePath = (process.env.NEXT_PUBLIC_BASE_PATH || '').replace(/\/$/, '');

const nextConfig = {
  output: 'export',
  trailingSlash: true,
  basePath: basePath || undefined,
  reactStrictMode: true,
  poweredByHeader: false,
  images: { unoptimized: true }
};

export default nextConfig;
