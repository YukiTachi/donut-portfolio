// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://donut-software.com',
  integrations: [sitemap()],
  server: {
    proxy: {
      // Netlify Identity プロキシ
      '/.netlify/identity': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
      },
      // Netlify Functions プロキシ
      '/.netlify/functions': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
      },
      // Git Gateway API プロキシ
      '/.netlify/git': {
        target: 'https://lively-alfajores-2237c7.netlify.app',
        changeOrigin: true,
        secure: true,
      },
    }
  }
});
