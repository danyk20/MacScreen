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
  tagline: 'Give your old iMac a second life as a display.',
  description:
    'MacScreen streams a virtual display from your Mac to any other Mac over Wi-Fi or cable. Up to 4K at 60 fps. Free and open source.',
} as const;

/** Prefix a path with the deployment base ("/MacScreen/" on GitHub Pages). */
export function withBase(path = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  return `${base}/${path.replace(/^\//, '')}`;
}
