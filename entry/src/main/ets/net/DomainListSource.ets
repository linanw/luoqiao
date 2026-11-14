import { http } from '@kit.NetworkKit';
import { isDomainListName } from '../model/DomainRules';

const USER_AGENT: string = 'harmony-wireguard/1.0';
const GITHUB_CATALOG: string = 'https://api.github.com/repos/v2fly/domain-list-community/git/trees/master?recursive=1';
const JSDELIVR_CATALOG: string =
  'https://data.jsdelivr.com/v1/packages/gh/v2fly/domain-list-community@master?structure=flat';
const RAW_BASE: string = 'https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/';
const JSDELIVR_BASE: string = 'https://fastly.jsdelivr.net/gh/v2fly/domain-list-community@master/data/';

interface GithubContentEntry {
  path?: string;
  type?: string;
}

interface GithubTree { tree: GithubContentEntry[]; truncated: boolean; }

interface JsdelivrFlatEntry {
  name?: string;
}

interface JsdelivrFlatResponse {
  files?: JsdelivrFlatEntry[];
}

async function httpGet(url: string, timeoutMs: number, maxSize: number): Promise<string> {
  const client = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': USER_AGENT },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: timeoutMs,
    };
    const response = await client.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error('HTTP ' + response.responseCode.toString());
    }
    const text = typeof response.result === 'string' ? response.result : '';
    if (text.length === 0 || text.length > maxSize) {
      throw new Error('响应为空或超过大小限制。');
    }
    return text;
  } finally {
    client.destroy();
  }
}

function parseGithubCatalog(text: string): string[] {
  const tree = JSON.parse(text) as GithubTree;
  if (tree.truncated) { throw new Error('目录被截断'); }
  const entries = tree.tree;
  if (!Array.isArray(entries)) {
    throw new Error('目录格式无效。');
  }
  const names: string[] = [];
  for (const entry of entries) {
    if (entry.type === 'blob' && typeof entry.path === 'string' && entry.path.startsWith('data/') && isDomainListName(entry.path.slice(5)) &&
      !names.includes(entry.path.slice(5))) {
      names.push(entry.path!.slice(5));
    }
  }
  if (names.length === 0) {
    throw new Error('目录为空。');
  }
  names.sort();
  return names;
}

function parseJsdelivrCatalog(text: string): string[] {
  const response = JSON.parse(text) as JsdelivrFlatResponse;
  const files = response.files;
  if (!Array.isArray(files)) {
    throw new Error('目录格式无效。');
  }
  const prefix = '/data/';
  const names: string[] = [];
  for (const file of files) {
    if (typeof file.name === 'string' && file.name.startsWith(prefix)) {
      const short = file.name.slice(prefix.length);
      if (isDomainListName(short) && !names.includes(short)) {
        names.push(short);
      }
    }
  }
  if (names.length === 0) {
    throw new Error('目录为空。');
  }
  names.sort();
  return names;
}

export async function fetchCatalog(): Promise<string[]> {
  try {
    return parseGithubCatalog(await httpGet(GITHUB_CATALOG, 15000, 4 * 1024 * 1024));
  } catch (_) {
    return parseJsdelivrCatalog(await httpGet(JSDELIVR_CATALOG, 20000, 8 * 1024 * 1024));
  }
}

export async function fetchDomainList(name: string): Promise<string> {
  if (!isDomainListName(name)) {
    throw new Error('无效的列表名称。');
  }
  try {
    return await httpGet(RAW_BASE + encodeURIComponent(name), 15000, 2 * 1024 * 1024);
  } catch (_) {
    return await httpGet(JSDELIVR_BASE + encodeURIComponent(name), 20000, 2 * 1024 * 1024);
  }
}
