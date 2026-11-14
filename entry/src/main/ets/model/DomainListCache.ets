import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { isDomainListName, sanitizeListName } from './DomainRules';

const CACHE_DIRECTORY: string = '/domain-lists';
const MANIFEST: string = '/active.json';
const BATCHES: string = '/batches';
const BATCH_ID: RegExp = /^[0-9a-fA-F-]{36}$/;

export class DomainListContent {
  name: string;
  content: string;
  constructor(name: string, content: string) { this.name = name; this.content = content; }
}

interface CacheEntry { name: string; batch: string; }
interface CacheManifest { version: number; entries: CacheEntry[]; }

function readText(path: string): string | undefined {
  try { return fileIo.readTextSync(path); } catch (_) { return undefined; }
}

function manifest(directory: string): CacheManifest {
  const path = directory + CACHE_DIRECTORY + MANIFEST;
  if (!fileIo.accessSync(path)) { return { version: 1, entries: [] }; }
  const raw = readText(path);
  if (raw === undefined) { throw new Error('无法读取域名缓存清单。'); }
  const parsed = JSON.parse(raw) as CacheManifest;
  if (parsed.version !== 1 || !Array.isArray(parsed.entries)) { throw new Error('域名缓存清单格式无效。'); }
  const seen = new Set<string>();
  for (const entry of parsed.entries) {
    if (!entry || typeof entry.name !== 'string' || !isDomainListName(entry.name) ||
      typeof entry.batch !== 'string' || !BATCH_ID.test(entry.batch) || seen.has(entry.name)) {
      throw new Error('域名缓存清单条目无效。');
    }
    seen.add(entry.name);
  }
  return parsed;
}

function atomicWrite(path: string, content: string): void {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    const bytes = util.TextEncoder.create().encodeInto(content);
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('域名缓存写入不完整。'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (e) {
    try { fileIo.unlinkSync(temporary); } catch (_) {}
    throw e as Error;
  }
}

export function readCachedDomainList(directory: string, name: string): string | undefined {
  sanitizeListName(name);
  try {
    const current = manifest(directory);
    const entry = current.entries.find((item: CacheEntry): boolean => item.name === name);
    if (entry !== undefined) {
      // A missing active file must not silently fall back to stale legacy content.
      return readText(directory + CACHE_DIRECTORY + BATCHES + '/' + entry.batch + '/' + name + '.txt');
    }
    return readText(directory + CACHE_DIRECTORY + '/' + name + '.txt');
  } catch (_) { return undefined; }
}

function pruneBatches(directory: string, current: CacheManifest, previous: CacheManifest): void {
  try {
    // Keep the immediately previous batches for readers that loaded the prior manifest.
    const keep = new Set<string>();
    for (const entry of current.entries.concat(previous.entries)) { keep.add(entry.batch); }
    const root = directory + CACHE_DIRECTORY + BATCHES;
    for (const name of fileIo.listFileSync(root)) {
      if (BATCH_ID.test(name) && !keep.has(name)) {
        try { fileIo.rmdirSync(root + '/' + name); } catch (_) {}
      }
    }
  } catch (_) {}
}

export function writeCachedDomainLists(directory: string, contents: DomainListContent[]): void {
  if (contents.length === 0) { return; }
  const names = new Set<string>();
  for (const item of contents) {
    sanitizeListName(item.name);
    if (names.has(item.name)) { throw new Error('域名缓存批次包含重复列表。'); }
    names.add(item.name);
  }
  const previous = manifest(directory);
  const batch = util.generateRandomUUID();
  const batchPath = directory + CACHE_DIRECTORY + BATCHES + '/' + batch;
  fileIo.mkdirSync(batchPath, true);
  const entries = previous.entries.filter((entry: CacheEntry): boolean => !names.has(entry.name));
  for (const item of contents) { entries.push({ name: item.name, batch: batch }); }
  const next: CacheManifest = { version: 1, entries: entries };
  try {
    for (const item of contents) { atomicWrite(batchPath + '/' + item.name + '.txt', item.content); }
    // This is the only visibility boundary: readers see the old or the complete new batch.
    atomicWrite(directory + CACHE_DIRECTORY + MANIFEST, JSON.stringify(next));
  } catch (e) {
    try { fileIo.rmdirSync(batchPath); } catch (_) {}
    throw e as Error;
  }
  pruneBatches(directory, next, previous);
}
