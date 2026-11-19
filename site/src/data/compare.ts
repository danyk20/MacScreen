/** Competitor facts, verified against each vendor's own pages on 2026-11-19. Cells that could not be verified are
 *  omitted or say "Not confirmed" rather than guessing. Re-verify before changing anything here. */
export const verifiedOn = 'November 2026';

export interface Product { id: string; name: string; us?: boolean; source: string }

export const products: Product[] = [
  { id: 'macscreen', name: 'MacScreen', us: true, source: 'https://github.com/danyk20/MacScreen' },
  { id: 'sidecar', name: 'Sidecar', source: 'https://support.apple.com/en-us/102597' },
  { id: 'duet', name: 'Duet Display', source: 'https://www.duetdisplay.com/use-imac-as-a-monitor' },
  { id: 'luna', name: 'Luna Display', source: 'https://astropad.com/product/lunadisplay/' },
  { id: 'deskreen', name: 'Deskreen', source: 'https://github.com/pavlobu/deskreen' },
  { id: 'spacedesk', name: 'spacedesk', source: 'https://spacedesk.net/' },
];

export type Tone = 'yes' | 'no' | 'neutral';
export interface Cell { text: string; tone: Tone }
const y = (text: string): Cell => ({ text, tone: 'yes' });
const n = (text: string): Cell => ({ text, tone: 'no' });
const o = (text: string): Cell => ({ text, tone: 'neutral' });

export const rows: { label: string; cells: Record<string, Cell> }[] = [
  {
    label: 'Another Mac can be the screen',
    cells: {
      macscreen: y('Yes'),
      sidecar: n('No, iPad only'),
      duet: y('Yes'),
      luna: y('Yes'),
      deskreen: o('Through a web browser'),
      spacedesk: o('Not confirmed'),
    },
  },
  {
    label: 'Extra hardware needed',
    cells: {
      macscreen: y('None'),
      sidecar: y('None'),
      duet: y('None'),
      luna: n('USB-C dongle on the host'),
      deskreen: y('None for mirroring'),
      spacedesk: y('None'),
    },
  },
  {
    label: 'Price',
    cells: {
      macscreen: y('Free'),
      sidecar: y('Built into macOS'),
      duet: o('Paid subscription'),
      luna: o('$89.99 one-time'),
      deskreen: o('Free edition, paid Pro'),
      spacedesk: o('Free for private use'),
    },
  },
  {
    label: 'Connection',
    cells: {
      macscreen: o('Wi-Fi, Ethernet, Thunderbolt Bridge'),
      sidecar: o('Wireless or USB'),
      duet: o('Wireless or Thunderbolt'),
      luna: o('Wi-Fi or wired'),
      deskreen: o('Local network'),
      spacedesk: o('Wi-Fi, LAN or USB'),
    },
  },
  {
    label: 'Open source',
    cells: {
      macscreen: y('Yes, MIT'),
      sidecar: n('No'),
      duet: o('Not stated'),
      luna: o('Not stated'),
      deskreen: y('Yes, AGPL-3.0'),
      spacedesk: o('Not stated'),
    },
  },
];

export const sources = [
  { name: 'Sidecar', url: 'https://support.apple.com/en-us/102597' },
  { name: 'Duet Display', url: 'https://www.duetdisplay.com/use-imac-as-a-monitor' },
  { name: 'Luna Display', url: 'https://astropad.com/product/lunadisplay/' },
  { name: 'Deskreen', url: 'https://github.com/pavlobu/deskreen' },
  { name: 'spacedesk', url: 'https://spacedesk.net/' },
];
