/** Hand-written release summaries, keyed by version. Dates and links come from GitHub at build time; a release that
 *  is not listed here is shown with a link to its notes. */
export const summaries: Record<string, string[]> = {
  '0.1.0-beta.3': [
    'Connect to a Display by IP address when automatic discovery is blocked',
    'Rename your Mac in Settings; the new name shows on the other Mac',
    'Check for Updates and install from inside the app',
    'New app icon and a cleaner menu',
  ],
  '0.1.0-beta.2': [
    'Disk image (DMG) download and Homebrew install',
    'Cleaner menu: everyday actions on top, the rest under Testing and Debugging',
  ],
  '0.1.0-beta.1': ['First public pre-release: Host and Display, pairing, 4K streaming, sound and cursor overlay'],
};

export const roadmap = {
  next: [
    { t: 'Apple notarization', d: 'No first-launch warning and no Screen Recording re-prompt after updates.' },
    { t: 'Wired-link measurements', d: 'Latency and frame-rate numbers over Ethernet and Thunderbolt Bridge.' },
    { t: 'Stable 1.0', d: 'A release without the beta label once the remaining checks are done.' },
    { t: 'Official Homebrew cask', d: 'Install without adding a tap, once the app is notarized.' },
  ],
  notPlanned: [
    { t: 'HDR and 10-bit colour', d: 'Tested and set aside for now: the 2015 iMac decodes 10-bit video in software, which would hurt smoothness.' },
    { t: 'Several Displays at once', d: 'One Display per Host for now.' },
  ],
};
