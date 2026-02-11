// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://donut-software.com',
  integrations: [sitemap()],
  server: {
    host: '0.0.0.0', // すべてのネットワークインターフェースでリッスン
    proxy: {
      // Netlify Identity プロキシ
      '/.netlify/identity': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
        rewrite: (path) => path,
      },
      // Netlify Functions プロキシ
      '/.netlify/functions': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
        rewrite: (path) => path,
      },
      // Git Gateway API プロキシ
      '/.netlify/git': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
        rewrite: (path) => path,
      },
    }
  }
});
