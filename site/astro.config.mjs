import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Project page on GitHub Pages. With a custom domain later: change `site`, set `base: '/'`.
export default defineConfig({
  site: 'https://danyk20.github.io',
  base: '/MacScreen',
  trailingSlash: 'always',
  output: 'static',
  compressHTML: true,
  integrations: [sitemap()],
  build: { inlineStylesheets: 'auto' },
  devToolbar: { enabled: false },
});
