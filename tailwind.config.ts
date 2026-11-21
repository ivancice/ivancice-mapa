import type { Config } from 'tailwindcss';

export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          50: '#eef8f4', 100: '#d5efe4', 200: '#addfca', 300: '#7cc8aa', 400: '#4aad88',
          500: '#2a916e', 600: '#1d7559', 700: '#185e49', 800: '#154b3b', 900: '#123e32'
        },
        ink: { DEFAULT: '#1f2933', soft: '#52606d', faint: '#9aa5b1' }
      },
      fontFamily: {
        sans: ['var(--font-sans)', 'system-ui', 'Segoe UI', 'Roboto', 'sans-serif']
      },
      boxShadow: { panel: '0 8px 30px rgba(15, 23, 42, 0.18)' }
    }
  },
  plugins: []
} satisfies Config;
