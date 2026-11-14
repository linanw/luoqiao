import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { asset } from '@kit.AssetStoreKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { migrateLegacySplitRules } from './SplitTunnel';
import { deletePureVpnProfile } from './PureVpnProvider';

export const MAX_CONFIG_BYTES: number = 128 * 1024;
export const MAX_PROFILES: number = 16;
export const LEGACY_PROFILE_ID: string = 'main';
const LEGACY_PROFILE_FILE: string = '/wireguard-profile.enc';
const LEGACY_PROFILE_NAME: string = '默认配置';
const PROFILES_DIRECTORY: string = '/profiles';
const PROFILE_INDEX_FILE: string = '/profiles.json';
const KEY_ALIAS: string = 'wireguard-profile-aes256-v1';
const FILE_VERSION: number = 1;
const IV_BYTES: number = 12;
const TAG_BYTES: number = 16;
const ENVELOPE_BYTES: number = 1 + IV_BYTES + TAG_BYTES;
const FILE_NOT_FOUND: number = 13900002;
const KEY_BYTES: number = 32;
const PROFILE_ID_PATTERN: RegExp = /^(main|[0-9a-fA-F-]{8,64})$/;

export class ProfileSaveError extends Error {}
export class ProfileIdError extends Error {}

export class ProfileMeta {
  id: string;
  name: string;

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

interface ProfileIndexDocument {
  profiles?: ProfileMeta[];
}

export function isValidProfileId(id: string): boolean {
  return typeof id === 'string' && PROFILE_ID_PATTERN.test(id);
}

function checkProfileId(id: string): void {
  if (!isValidProfileId(id)) {
    throw new ProfileIdError('配置标识无效。');
  }
}

function checkProfileName(name: string): string {
  const trimmed = name.trim();
  if (trimmed.length === 0 || trimmed.length > 64) {
    throw new ProfileSaveError('配置名称长度需在 1 到 64 个字符之间。');
  }
  for (const character of trimmed) {
    if (character.charCodeAt(0) < 32) {
      throw new ProfileSaveError('配置名称包含不可见字符。');
    }
  }
  return trimmed;
}

function keyQuery(): asset.AssetMap {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, util.TextEncoder.create().encodeInto(KEY_ALIAS));
  return query;
}

async function queryProfileKey(query: asset.AssetMap): Promise<Uint8Array> {
  const records = await asset.query(query);
  const secret = records[0]?.get(asset.Tag.SECRET);
  if (!(secret instanceof Uint8Array) || secret.length !== KEY_BYTES) {
    throw new Error('配置密钥无效。');
  }
  return secret;
}

async function createProfileKey(query: asset.AssetMap): Promise<Uint8Array> {
  const bytes = (await cryptoFramework.createRandom().generateRandom(KEY_BYTES)).data;
  try {
    const attributes = keyQuery();
    attributes.set(asset.Tag.SECRET, bytes);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
    await asset.add(attributes);
    return bytes;
  } catch (error) {
    bytes.fill(0);
    if ((error as BusinessError).code === asset.ErrorCode.DUPLICATED) {
      return queryProfileKey(query);
    }
    throw error as Error;
  }
}

async function profileKey(create: boolean): Promise<cryptoFramework.SymKey> {
  const query = keyQuery();
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  let bytes: Uint8Array;
  try {
    bytes = await queryProfileKey(query);
  } catch (error) {
    const code = (error as BusinessError).code;
    // A first query can fail because asset.add has not created the database yet.
    if (!create || (code !== asset.ErrorCode.NOT_FOUND && code !== asset.ErrorCode.DATABASE_ERROR)) {
      throw error as Error;
    }
    bytes = await createProfileKey(query);
  }
  try {
    return await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: bytes });
  } finally {
    bytes.fill(0);
  }
}

function params(iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
  return {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: new Uint8Array([FILE_VERSION]) },
    authTag: { data: tag },
  };
}

async function readBytes(path: string, limit: number): Promise<Uint8Array> {
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const info = await fileIo.stat(file.fd);
    if (!info.isFile() || info.size > limit) {
      throw new Error('文件过大或不可读取。');
    }
    const bytes = new Uint8Array(info.size);
    let offset = 0;
    while (offset < bytes.length) {
      const chunk = new ArrayBuffer(bytes.length - offset);
      const count = await fileIo.read(file.fd, chunk);
      if (count === 0) {
        throw new Error('读取时文件已变更。');
      }
      bytes.set(new Uint8Array(chunk, 0, count), offset);
      offset += count;
    }
    return bytes;
  } finally {
    await fileIo.close(file);
  }
}

export async function readConfigDocument(uri: string): Promise<string> {
  const bytes = await readBytes(uri, MAX_CONFIG_BYTES);
  try {
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
  } finally {
    bytes.fill(0);
  }
}

function checkProfileDirectory(directory: string): void {
  if (typeof directory !== 'string' || !directory.startsWith('/')) {
    throw new ProfileSaveError('系统未返回有效的模块文件目录。');
  }
}

function profilesDirectory(directory: string): string {
  return directory + PROFILES_DIRECTORY;
}

function profileFilePath(directory: string, id: string): string {
  return profilesDirectory(directory) + '/' + id + '.enc';
}

function indexPath(directory: string): string {
  return directory + PROFILE_INDEX_FILE;
}

function readIndex(directory: string): ProfileMeta[] | undefined {
  let raw: string;
  try {
    raw = fileIo.readTextSync(indexPath(directory));
  } catch (_) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(raw) as ProfileIndexDocument;
    if (!Array.isArray(parsed.profiles)) {
      return undefined;
    }
    const metas: ProfileMeta[] = [];
    const seen = new Set<string>();
    for (const entry of parsed.profiles) {
      if (entry instanceof Object && isValidProfileId(String(entry.id))) {
        const id = String(entry.id);
        const name = typeof entry.name === 'string' ? entry.name : id;
        if (!seen.has(id)) {
          seen.add(id);
          metas.push(new ProfileMeta(id, name));
        }
      }
    }
    return metas;
  } catch (_) {
    return undefined;
  }
}

function writeIndex(directory: string, metas: ProfileMeta[]): void {
  const document: ProfileIndexDocument = { profiles: metas };
  const path = indexPath(directory);
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(document));
  try {
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) {
        throw new Error('无法写入配置索引。');
      }
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try {
      fileIo.unlinkSync(temporary);
    } catch (_) {
      // The temporary file may not have been created.
    }
    throw error as Error;
  }
}

function ensureProfilesDirectory(directory: string): void {
  const path = profilesDirectory(directory);
  if (!fileIo.accessSync(path)) {
    fileIo.mkdirSync(path, true);
  }
}

function legacyProfileDirectory(context: common.Context, directory: string): string | undefined {
  try {
    const legacy = context.getApplicationContext().filesDir;
    if (typeof legacy === 'string' && legacy.startsWith('/') && legacy !== directory) {
      return legacy;
    }
  } catch (_) {
    // Some devices cannot resolve the previous application-wide directory.
  }
  return undefined;
}

function legacyProfilePaths(context: common.Context, directory: string): string[] {
  const paths: string[] = [];
  const legacyDirectory = legacyProfileDirectory(context, directory);
  if (legacyDirectory !== undefined) {
    paths.push(legacyDirectory + LEGACY_PROFILE_FILE);
  }
  paths.push(directory + LEGACY_PROFILE_FILE);
  return paths;
}

// Copies a pre-multi-profile configuration into the per-profile store once.
function migrateLegacyProfile(context: common.Context): void {
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  if (fileIo.accessSync(indexPath(directory))) {
    return;
  }
  ensureProfilesDirectory(directory);
  for (const legacy of legacyProfilePaths(context, directory)) {
    try {
      if (!fileIo.accessSync(legacy)) {
        continue;
      }
      const bytes = readBytesSync(legacy, MAX_CONFIG_BYTES + ENVELOPE_BYTES);
      const target = profileFilePath(directory, LEGACY_PROFILE_ID);
      const file = fileIo.openSync(target,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.unlinkSync(legacy);
      writeIndex(directory, [new ProfileMeta(LEGACY_PROFILE_ID, LEGACY_PROFILE_NAME)]);
      break;
    } catch (_) {
      // Keep searching for a readable legacy document.
    }
  }
  if (!fileIo.accessSync(indexPath(directory))) {
    writeIndex(directory, []);
  }
  migrateLegacySplitRules(directory);
}

function readBytesSync(path: string, limit: number): Uint8Array {
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const info = fileIo.statSync(file.fd);
    if (!info.isFile() || info.size > limit) {
      throw new Error('文件过大或不可读取。');
    }
    const bytes = new Uint8Array(info.size);
    let offset = 0;
    while (offset < bytes.length) {
      const chunk = new ArrayBuffer(bytes.length - offset);
      const count = fileIo.readSync(file.fd, chunk);
      if (count === 0) {
        throw new Error('读取时文件已变更。');
      }
      bytes.set(new Uint8Array(chunk, 0, count), offset);
      offset += count;
    }
    return bytes;
  } finally {
    fileIo.closeSync(file);
  }
}

export function listProfiles(context: common.Context): ProfileMeta[] {
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  migrateLegacyProfile(context);
  return readIndex(directory) ?? [];
}

async function decryptProfileFile(path: string): Promise<string> {
  const bytes = await readBytes(path, MAX_CONFIG_BYTES + ENVELOPE_BYTES);
  if (bytes.length <= ENVELOPE_BYTES || bytes[0] !== FILE_VERSION) {
    throw new Error('无法读取配置格式。');
  }
  const iv = bytes.subarray(1, 1 + IV_BYTES);
  const tag = bytes.subarray(bytes.length - TAG_BYTES);
  const ciphertext = bytes.subarray(1 + IV_BYTES, bytes.length - TAG_BYTES);
  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  const key = await profileKey(false);
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params(iv, tag));
  const result = await cipher.doFinal({ data: ciphertext });
  try {
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(result.data);
  } finally {
    result.data.fill(0);
  }
}

export async function loadProfileText(context: common.Context, id: string): Promise<string> {
  checkProfileId(id);
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  migrateLegacyProfile(context);
  const path = profileFilePath(directory, id);
  if (!fileIo.accessSync(path)) {
    return '';
  }
  return decryptProfileFile(path);
}

async function encryptProfileFile(directory: string, id: string, config: string): Promise<void> {
  let step = '编码配置';
  let plaintext: Uint8Array | undefined;
  let temporary: string | undefined;
  try {
    plaintext = util.TextEncoder.create().encodeInto(config);
    if (!plaintext || plaintext.length === 0 || plaintext.length > MAX_CONFIG_BYTES) {
      throw new ProfileSaveError('配置文件大小必须介于 1 字节和 128 KB 之间。');
    }
    step = '准备应用配置目录';
    ensureProfilesDirectory(directory);
    step = '读取或创建配置密钥';
    const key = await profileKey(true);
    step = '加密配置';
    const iv = (await cryptoFramework.createRandom().generateRandom(IV_BYTES)).data;
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params(iv, new Uint8Array(TAG_BYTES)));
    const result = await cipher.doFinal({ data: plaintext });
    const envelope = new Uint8Array(1 + IV_BYTES + result.data.length);
    envelope[0] = FILE_VERSION;
    envelope.set(iv, 1);
    envelope.set(result.data, 1 + IV_BYTES);
    const path = profileFilePath(directory, id);
    const stagingPath = path + '.' + util.generateRandomUUID() + '.tmp';
    step = '创建配置临时文件';
    const file = await fileIo.open(stagingPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    temporary = stagingPath;
    try {
      step = '写入配置临时文件';
      const written = await fileIo.write(file.fd, envelope.buffer);
      if (written !== envelope.length) {
        throw new ProfileSaveError('配置临时文件写入不完整。');
      }
      step = '同步配置临时文件';
      await fileIo.fsync(file.fd);
      step = '关闭配置临时文件';
    } finally {
      await fileIo.close(file);
    }
    step = '替换配置文件';
    await fileIo.rename(stagingPath, path);
    temporary = undefined;
  } catch (error) {
    if (error instanceof ProfileSaveError) {
      throw error;
    }
    const code = (error as BusinessError).code;
    if (code === asset.ErrorCode.STATUS_MISMATCH) {
      throw new ProfileSaveError('系统无法访问配置密钥。请在设备解锁后重试（24000005）。');
    }
    const suffix = typeof code === 'number' ? '（错误码 ' + code.toString() + '）' : '';
    const message = step + '失败' + suffix + '。';
    hilog.error(0x0010, 'WireGuardProfile', '%{public}s', message);
    throw new ProfileSaveError(message);
  } finally {
    plaintext?.fill(0);
    if (temporary !== undefined) {
      try {
        await fileIo.unlink(temporary);
      } catch (_) {
        // Preserve the original error if the temporary file is already gone.
      }
    }
  }
}

export async function saveProfileText(context: common.Context, id: string, config: string): Promise<void> {
  checkProfileId(id);
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  migrateLegacyProfile(context);
  const metas = readIndex(directory) ?? [];
  if (!metas.some((meta: ProfileMeta): boolean => meta.id === id)) {
    throw new ProfileIdError('配置不存在。');
  }
  await encryptProfileFile(directory, id, config);
}

export async function createProfile(context: common.Context, name: string, config: string): Promise<ProfileMeta> {
  const displayName = checkProfileName(name);
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  migrateLegacyProfile(context);
  const metas = readIndex(directory) ?? [];
  if (metas.length >= MAX_PROFILES) {
    throw new ProfileSaveError('配置数量不能超过 ' + MAX_PROFILES.toString() + ' 份。');
  }
  const meta = new ProfileMeta(util.generateRandomUUID(), displayName);
  await encryptProfileFile(directory, meta.id, config);
  metas.push(meta);
  writeIndex(directory, metas);
  return meta;
}

export async function renameProfile(context: common.Context, id: string, name: string): Promise<void> {
  checkProfileId(id);
  const displayName = checkProfileName(name);
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  migrateLegacyProfile(context);
  const metas = readIndex(directory) ?? [];
  const meta = metas.find((entry: ProfileMeta): boolean => entry.id === id);
  if (meta === undefined) {
    throw new ProfileIdError('配置不存在。');
  }
  meta.name = displayName;
  writeIndex(directory, metas);
}

export async function deleteProfile(context: common.Context, id: string): Promise<void> {
  checkProfileId(id);
  const directory = context.filesDir;
  checkProfileDirectory(directory);
  deletePureVpnProfile(directory, id);
  migrateLegacyProfile(context);
  const metas = readIndex(directory) ?? [];
  const remaining = metas.filter((meta: ProfileMeta): boolean => meta.id !== id);
  if (remaining.length === metas.length) {
    return;
  }
  try {
    fileIo.unlinkSync(profileFilePath(directory, id));
  } catch (_) {
    // The encrypted document may already be gone.
  }
  writeIndex(directory, remaining);
}
