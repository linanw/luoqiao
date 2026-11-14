import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import * as tailnet from 'libtailnet.so';

const BASE: string = 'https://github.com/v2fly/domain-list-community/releases/latest/download/';
const META_FILE: string = '/domain-database-info.json';
let inFlight: Promise<string[]> | undefined = undefined;
let inFlightDirectory: string = '';

export class DomainDatabaseInfo {
  available: boolean = false;
  updatedAt: number = 0;
  listCount: number = 0;
  sizeBytes: number = 0;
  catalog: string[] = [];
}

export function readDomainDatabaseInfo(dir: string): DomainDatabaseInfo {
  const info = new DomainDatabaseInfo();
  try {
    const stat = fileIo.statSync(dir + '/dlc.dat');
    info.available = stat.size > 0;
    info.updatedAt = stat.mtime * 1000;
    info.sizeBytes = stat.size;
    try {
      const saved = JSON.parse(fileIo.readTextSync(dir + META_FILE)) as DomainDatabaseInfo;
      if (saved.updatedAt === info.updatedAt && saved.sizeBytes === info.sizeBytes && Array.isArray(saved.catalog)) {
        info.catalog = saved.catalog.filter((name: string): boolean =>
          typeof name === 'string' && /^[a-z0-9][a-z0-9_.@!-]{0,99}$/.test(name));
        info.listCount = info.catalog.length;
      }
    } catch (_) {
      // Existing installations can recover their catalog from the verified database.
    }
  } catch (_) {
    // No database has been downloaded yet.
  }
  return info;
}

function saveDatabaseInfo(dir: string, names: string[]): void {
  const info = readDomainDatabaseInfo(dir);
  info.catalog = names;
  info.listCount = names.length;
  const path = dir + META_FILE + '.tmp';
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, JSON.stringify(info)); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(path, dir + META_FILE);
  } catch (_) {
    // A metadata cache failure must not hide a successfully installed database.
    try { fileIo.unlinkSync(path); } catch (_) {}
  }
}

export async function domainDatabaseCatalog(dir: string, force: boolean): Promise<string[]> {
  if (inFlight !== undefined && inFlightDirectory === dir) { return inFlight; }
  const request = loadDatabaseCatalog(dir, force);
  inFlight = request;
  inFlightDirectory = dir;
  try { return await request; }
  finally {
    if (inFlight === request) { inFlight = undefined; inFlightDirectory = ''; }
  }
}

async function loadDatabaseCatalog(dir: string, force: boolean): Promise<string[]> {
  const cached = readDomainDatabaseInfo(dir);
  if (!force && cached.catalog.length > 0) { return cached.catalog; }
  if (force || !cached.available) {
    try {
      for (const name of ['dlc.dat', 'dlc.dat.sha256sum']) {
        const client = http.createHttp();
        try {
          const response = await client.request(BASE + name, { method: http.RequestMethod.GET,
            expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 15000, readTimeout: 60000,
            maxLimit: 16 * 1024 * 1024 });
          if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
            throw new Error('下载失败（HTTP ' + response.responseCode + '），请检查网络后重试');
          }
          const path = dir + (name === 'dlc.dat' ? '/dlc.dat.download' : '/dlc.dat.sha256.download');
          const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          try { fileIo.writeSync(file.fd, response.result); } finally { fileIo.closeSync(file); }
        } finally { client.destroy(); }
      }
      // Native installation verifies SHA-256 and the database before replacing the current file.
      await tailnet.call('database', dir);
    } finally {
      for (const path of ['/dlc.dat.download', '/dlc.dat.sha256.download']) {
        try { fileIo.unlinkSync(dir + path); } catch (_) {}
      }
    }
  }
  const names = JSON.parse(await tailnet.call('catalog', dir)) as string[];
  if (!Array.isArray(names) || names.length === 0) { throw new Error('数据库无法读取，请重新下载'); }
  saveDatabaseInfo(dir, names);
  return names;
}
