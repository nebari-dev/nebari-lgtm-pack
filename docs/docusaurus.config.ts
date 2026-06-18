import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';

const config: Config = {
  title: 'Nebari LGTM Pack',
  tagline: 'Observability stack for Nebari',
  favicon: 'img/favicon.ico',

  url: 'https://nebari-dev.github.io',
  baseUrl: '/nebari-lgtm-pack/',

  organizationName: 'nebari-dev',
  projectName: 'nebari-lgtm-pack',

  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  markdown: {
    mermaid: true,
  },
  themes: ['@docusaurus/theme-mermaid'],

  plugins: [
    [
      'docusaurus-lunr-search',
      {
        languages: ['en'],
      },
    ],
  ],

  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          sidebarCollapsible: true,
          showLastUpdateTime: true,
          editUrl:
            'https://github.com/nebari-dev/nebari-lgtm-pack/edit/main/docs/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: 'light',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },
    docs: {
      sidebar: {
        hideable: true,
        autoCollapseCategories: true,
      },
    },
    navbar: {
      title: 'Nebari LGTM Pack',
      logo: {
        alt: 'Nebari logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          href: 'https://github.com/nebari-dev/nebari-lgtm-pack',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Source',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/nebari-dev/nebari-lgtm-pack',
            },
            {
              label: 'Nebari',
              href: 'https://nebari.dev',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Nebari contributors.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'yaml', 'toml', 'python'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
