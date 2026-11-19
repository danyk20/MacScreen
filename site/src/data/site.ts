/** Single source of truth for names and links used across the site. */
export const site = {
  name: 'MacScreen',
  repo: 'danyk20/MacScreen',
  repoUrl: 'https://github.com/danyk20/MacScreen',
  issuesUrl: 'https://github.com/danyk20/MacScreen/issues',
  newIssueBug: 'https://github.com/danyk20/MacScreen/issues/new?template=bug_report.yml',
  newIssueFeature: 'https://github.com/danyk20/MacScreen/issues/new?template=feature_request.yml',
  releasesUrl: 'https://github.com/danyk20/MacScreen/releases',
  docsUrl: 'https://github.com/danyk20/MacScreen/blob/main/docs/USAGE.md',
  licenseUrl: 'https://github.com/danyk20/MacScreen/blob/main/LICENSE',
  brewTap: 'brew tap danyk20/macscreen https://github.com/danyk20/MacScreen',
  brewInstall: 'brew install --cask macscreen',
  tagline: 'Any Mac’s screen, as if it were plugged into yours.',
  /** Hero subhead. */
  heroSub:
    'MacScreen turns any Mac into an extra display for another Mac over Wi-Fi or cable. Windows, Mission Control and the Dock treat it like a real monitor. Up to 5K, free and open source.',
  /** Meta description (kept short for search results). */
  description:
    'Use any Mac’s screen as if it were plugged into yours. MacScreen turns another Mac into an extra display over Wi-Fi or cable. Free and open source.',
} as const;

/** Prefix a path with the deployment base ("/MacScreen/" on GitHub Pages). */
export function withBase(path = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  return `${base}/${path.replace(/^\//, '')}`;
}
