/** Competitor facts, verified against each vendor's own pages on 2026-11-19. Software-only tools (no dongle). Cells that could not be verified are
 *  omitted or say "Not confirmed" rather than guessing. Re-verify before changing anything here. */
export const verifiedOn = 'November 2026';

export interface Product { id: string; name: string; us?: boolean; source: string }

export const products: Product[] = [
  { id: 'macscreen', name: 'MacScreen', us: true, source: 'https://github.com/danyk20/MacScreen' },
  { id: 'opendisplay', name: 'OpenDisplay', source: 'https://github.com/peetzweg/opendisplay' },
  { id: 'sidecar', name: 'Sidecar', source: 'https://support.apple.com/en-us/102597' },
  { id: 'duet', name: 'Duet Display', source: 'https://www.duetdisplay.com/use-imac-as-a-monitor' },
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
      opendisplay: y('Yes'),
      sidecar: n('No, iPad only'),
      duet: y('Yes'),
      deskreen: o('Through a web browser'),
      spacedesk: o('Not confirmed'),
    },
  },
  {
    label: 'Extra hardware needed',
    cells: {
      macscreen: y('None'),
      opendisplay: y('None'),
      sidecar: y('None'),
      duet: y('None'),
      deskreen: y('None for mirroring'),
      spacedesk: y('None'),
    },
  },
  {
    label: 'Price',
    cells: {
      macscreen: y('Free'),
      opendisplay: y('Free'),
      sidecar: y('Built into macOS'),
      duet: o('Paid subscription'),
      deskreen: o('Free edition, paid Pro'),
      spacedesk: o('Free for private use'),
    },
  },
  {
    label: 'Connection',
    cells: {
      macscreen: o('Wi-Fi, Ethernet, Thunderbolt Bridge'),
      opendisplay: o('Wi-Fi or cable'),
      sidecar: o('Wireless or USB'),
      duet: o('Wireless or Thunderbolt'),
      deskreen: o('Local network'),
      spacedesk: o('Wi-Fi, LAN or USB'),
    },
  },
  {
    label: 'Minimum macOS on the sending Mac',
    cells: {
      macscreen: y('macOS 12.3'),
      opendisplay: o('macOS 14'),
      sidecar: o('macOS 10.15'),
      duet: o('macOS 11 (Apple Silicon)'),
      deskreen: o('Not stated'),
      spacedesk: o('macOS 14.4 (beta)'),
    },
  },
  {
    label: 'Open source',
    cells: {
      macscreen: y('Yes, MIT'),
      opendisplay: y('Yes, GPL-3.0'),
      sidecar: n('No'),
      duet: o('Not stated'),
      deskreen: y('Yes, AGPL-3.0'),
      spacedesk: o('Not stated'),
    },
  },
];

export const sources = [
  { name: 'Sidecar', url: 'https://support.apple.com/en-us/102597' },
  { name: 'Duet Display', url: 'https://www.duetdisplay.com/use-imac-as-a-monitor' },
  { name: 'OpenDisplay', url: 'https://github.com/peetzweg/opendisplay' },
  { name: 'Deskreen', url: 'https://github.com/pavlobu/deskreen' },
  { name: 'spacedesk', url: 'https://spacedesk.net/' },
];
