import fallback from './release.fallback.json';
import { site } from './site';

export interface ReleaseInfo {
  version: string;
  tag: string;
  prerelease: boolean;
  date: string;
  pageUrl: string;
  dmgUrl: string;
  notes: string;
}

interface GitHubAsset { name: string; browser_download_url: string }
interface GitHubRelease {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
  published_at: string | null;
  body: string | null;
  assets: GitHubAsset[];
}

let cache: Promise<ReleaseInfo[]> | undefined;

/** Releases from GitHub at build time (newest first). Falls back to a checked-in snapshot if the API is unavailable. */
export function getReleases(): Promise<ReleaseInfo[]> {
  cache ??= load();
  return cache;
}

export async function getLatestRelease(): Promise<ReleaseInfo> {
  const [latest] = await getReleases();
  if (!latest) throw new Error('No release data available');
  return latest;
}

async function load(): Promise<ReleaseInfo[]> {
  try {
    const headers: Record<string, string> = { Accept: 'application/vnd.github+json', 'User-Agent': 'macscreen-site-build' };
    const token = process.env.GITHUB_TOKEN;
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`https://api.github.com/repos/${site.repo}/releases?per_page=20`, { headers });
    if (!res.ok) throw new Error(`GitHub API ${res.status}`);
    const raw = (await res.json()) as GitHubRelease[];
    const parsed = raw.filter((r) => !r.draft).flatMap(toInfo);
    if (parsed.length === 0) throw new Error('no usable releases');
    return parsed;
  } catch (error) {
    console.warn(`[release] using fallback snapshot: ${String(error)}`);
    return fallback.releases;
  }
}

function toInfo(r: GitHubRelease): ReleaseInfo[] {
  const dmg = r.assets.find((a) => a.name === `MacScreen-${r.tag_name}.dmg`);
  if (!dmg) return [];
  return [{
    version: r.tag_name.replace(/^v/, ''),
    tag: r.tag_name,
    prerelease: r.prerelease,
    date: (r.published_at ?? '').slice(0, 10),
    pageUrl: r.html_url,
    dmgUrl: dmg.browser_download_url,
    notes: r.body ?? '',
  }];
}
