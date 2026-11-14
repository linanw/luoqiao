import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util, url } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { MAX_CONFIG_BYTES, readConfigDocument } from './ProfileStore';
import { parseWireGuardConfig } from './WireGuardConfig';

const CACHE_FOLDER: string = '/purevpn-downloads';
const OWN_FILE: RegExp = /^purevpn-config-[0-9a-fA-F-]{36}\.tmp$/;
const activePaths: Set<string> = new Set<string>();

function ensureCacheDirectory(directory: string): void {
  if (!fileIo.accessSync(directory)) {
    try { fileIo.mkdirSync(directory, true); }
    catch (error) {
      // Another page may have created the directory after the existence check.
      if ((error as BusinessError).code !== 13900015) { throw error as Error; }
    }
  }
  if (!fileIo.statSync(directory).isDirectory()) { throw new Error('PureVPN 临时目录不可用。'); }
}

export function isPureVpnConfigDownload(address: string, filename: string): boolean {
  if (typeof filename !== 'string' || filename.length > 160 ||
    !/^[^/\\\u0000-\u001f\u007f]+\.conf$/i.test(filename)) { return false; }
  try {
    const blob = address.startsWith('blob:');
    const parsed = url.URL.parseURL(blob ? address.slice(5) : address);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      (parsed.port && parsed.port !== '443')) { return false; }
    if (blob) { return parsed.hostname === 'my.purevpn.com' && parsed.pathname.length > 1 && !parsed.search && !parsed.hash; }
    return parsed.hostname === 'purevpn.com' || parsed.hostname.endsWith('.purevpn.com');
  } catch (_) { return false; }
}

class PendingDownload {
  guid: string;
  path: string;
  item: webview.WebDownloadItem;
  finishing: boolean = false;
  constructor(guid: string, path: string, item: webview.WebDownloadItem) {
    this.guid = guid; this.path = path; this.item = item;
  }
}

export class PureVpnDownloadCapture {
  readonly delegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();
  private directory: string;
  private currentPage: () => boolean;
  private onConfig: (text: string) => void;
  private onError: (message: string) => void;
  private pending: Map<string, PendingDownload> = new Map<string, PendingDownload>();
  private retired: Map<string, string> = new Map<string, string>();
  private disposed: boolean = false;

  constructor(context: common.UIAbilityContext, isCurrentMemberPage: () => boolean,
    onConfig: (text: string) => void, onError: (message: string) => void) {
    this.currentPage = isCurrentMemberPage; this.onConfig = onConfig; this.onError = onError;
    if (!context.cacheDir.startsWith('/') || /[\u0000\r\n]/.test(context.cacheDir)) {
      throw new Error('PureVPN 临时目录无效。');
    }
    this.directory = context.cacheDir + CACHE_FOLDER;
    ensureCacheDirectory(this.directory);
    // Only files created by this helper are eligible; another live capture keeps ownership.
    for (const name of fileIo.listFileSync(this.directory)) {
      const path = this.directory + '/' + name;
      if (OWN_FILE.test(name) && !activePaths.has(path) && fileIo.statSync(path).isFile()) { fileIo.unlinkSync(path); }
    }
    this.delegate.onBeforeDownload((item: webview.WebDownloadItem): void => this.before(item));
    this.delegate.onDownloadUpdated((item: webview.WebDownloadItem): void => this.updated(item));
    this.delegate.onDownloadFinish((item: webview.WebDownloadItem): void => {
      this.finished(item).catch((): void => {
        if (!this.disposed) { this.onError('无法完成配置下载，请在官网重新生成。'); }
      });
    });
    this.delegate.onDownloadFailed((item: webview.WebDownloadItem): void => this.failed(item));
  }

  private allowed(item: webview.WebDownloadItem): boolean {
    try {
      return !this.disposed && this.currentPage() &&
        isPureVpnConfigDownload(item.getUrl(), item.getSuggestedFileName());
    } catch (_) { return false; }
  }

  private cleanup(path: string): void {
    if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
  }

  private cancel(item: webview.WebDownloadItem): void { try { item.cancel(); } catch (_) {} }

  private reject(item: webview.WebDownloadItem, message: string): void {
    const guid = item.getGuid();
    const record = this.pending.get(guid);
    if (record) {
      this.pending.delete(guid); activePaths.delete(record.path);
      this.retired.set(guid, record.path);
    }
    this.cancel(item);
    try { if (record) { this.cleanup(record.path); } }
    catch (_) { message = '无法清理下载的临时配置，请关闭并重新打开配置助手后重试。'; }
    if (!this.disposed) { this.onError(message); }
  }

  private before(item: webview.WebDownloadItem): void {
    if (!this.allowed(item)) { this.reject(item, '只接收 PureVPN 官方手动配置页的 .conf 下载。'); return; }
    if (item.getTotalBytes() > MAX_CONFIG_BYTES || item.getReceivedBytes() > MAX_CONFIG_BYTES) {
      this.reject(item, 'WireGuard 配置不能超过 128 KB。'); return;
    }
    if (this.pending.size > 0) { this.reject(item, '已有配置正在下载，请等待完成后再试。'); return; }
    const guid = item.getGuid();
    if (!guid || guid.length > 128) { this.reject(item, '无法识别此配置下载。'); return; }
    const path = this.directory + '/purevpn-config-' + util.generateRandomUUID() + '.tmp';
    const record = new PendingDownload(guid, path, item);
    this.pending.set(guid, record); activePaths.add(path);
    try { item.start(path); }
    catch (_) { this.reject(item, '无法接收配置文件，请重新下载。'); }
  }

  private updated(item: webview.WebDownloadItem): void {
    const record = this.pending.get(item.getGuid());
    if (!record || record.finishing) { return; }
    if (!this.allowed(item)) { this.reject(item, '已取消配置下载，请留在官网手动配置页。'); return; }
    if (item.getReceivedBytes() > MAX_CONFIG_BYTES || item.getTotalBytes() > MAX_CONFIG_BYTES) {
      this.reject(item, 'WireGuard 配置不能超过 128 KB。');
    }
  }

  private async finished(item: webview.WebDownloadItem): Promise<void> {
    const guid = item.getGuid();
    const record = this.pending.get(guid);
    if (!record || record.finishing) { this.cleanRetired(guid); return; }
    record.finishing = true;
    let text = '';
    let message = '';
    try {
      if (!this.allowed(item)) { throw new Error('navigation'); }
      const info = fileIo.statSync(record.path);
      if (!info.isFile() || info.size < 1 || info.size > MAX_CONFIG_BYTES ||
        item.getReceivedBytes() > MAX_CONFIG_BYTES || item.getTotalBytes() > MAX_CONFIG_BYTES) {
        message = '下载的 WireGuard 配置为空或超过 128 KB。';
        throw new Error('size');
      }
      // Never use item.getFullPath(): only our private, randomly named path is trusted.
      text = await readConfigDocument(record.path);
      parseWireGuardConfig(text);
    } catch (_) { if (!message) { message = '无法读取有效的 WireGuard 配置，请在官网重新生成。'; } }
    try { this.cleanup(record.path); }
    catch (_) { message = '无法清理下载的临时配置，请关闭并重新打开配置助手后重试。'; }
    const owned = this.pending.get(guid) === record;
    this.pending.delete(guid); activePaths.delete(record.path);
    if (!owned || this.disposed) { return; }
    // A navigation/disposal while the asynchronous file read ran cancels delivery as well.
    if (!this.allowed(item)) { this.onError('配置下载已取消，请留在官网手动配置页重试。'); return; }
    if (message) { this.onError(message); return; }
    this.onConfig(text);
  }

  private cleanRetired(guid: string): void {
    const path = this.retired.get(guid);
    if (path) {
      try { this.cleanup(path); this.retired.delete(guid); } catch (_) {}
    }
  }

  private failed(item: webview.WebDownloadItem): void {
    if (this.pending.has(item.getGuid())) { this.reject(item, '官网配置下载未完成，请重试。'); }
    this.cleanRetired(item.getGuid());
  }

  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    for (const record of Array.from(this.pending.values())) { this.reject(record.item, ''); }
    for (const guid of Array.from(this.retired.keys())) { this.cleanRetired(guid); }
  }
}

export function createPureVpnDownloadDelegate(context: common.UIAbilityContext,
  isCurrentMemberPage: () => boolean, onConfig: (text: string) => void,
  onError: (message: string) => void): PureVpnDownloadCapture {
  return new PureVpnDownloadCapture(context, isCurrentMemberPage, onConfig, onError);
}
