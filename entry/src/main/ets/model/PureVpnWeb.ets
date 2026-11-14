import { url } from '@kit.ArkTS';

export const PUREVPN_MEMBER_URL: string = 'https://my.purevpn.com/v2/dashboard/manual-config';

export interface PureVpnWebCommand { action: string; location: string; runId?: string; }
export interface PureVpnWebResult { status: string; locations: string[]; selected: string; config: string; }

export function isPureVpnPage(address: string, manualOnly: boolean = false): boolean {
  try {
    const parsed = url.URL.parseURL(address);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || (parsed.port && parsed.port !== '443')) { return false; }
    if (manualOnly) {
      return parsed.hostname === 'my.purevpn.com' && /^\/v2\/dashboard\/manual-config\/?$/.test(parsed.pathname);
    }
    return parsed.hostname === 'purevpn.com' || parsed.hostname.endsWith('.purevpn.com');
  } catch (_) { return false; }
}

export function parsePureVpnWebResult(raw: string): PureVpnWebResult {
  if (raw.length > 300000) { throw new Error('网页返回内容过大。'); }
  // ArkWeb serializes a JS string on some SDK revisions; support exactly one such wrapper.
  const outer = JSON.parse(raw) as Object;
  const result = (typeof outer === 'string' ? JSON.parse(outer) : outer) as PureVpnWebResult;
  if (!result || typeof result.status !== 'string' || !Array.isArray(result.locations) ||
    result.locations.length > 300 || result.locations.some((item: string): boolean => typeof item !== 'string' || item.length > 100) ||
    typeof result.selected !== 'string' || result.selected.length > 100 || typeof result.config !== 'string' || result.config.length > 131072) {
    throw new Error('暂时无法识别此版本的会员网页。');
  }
  return result;
}
