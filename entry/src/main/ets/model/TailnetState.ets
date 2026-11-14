import { fileIo } from '@kit.CoreFileKit';
export class TailnetPeer {
  DNSName: string = '';
  HostName: string = '';
  TailscaleIPs: string[] = [];
  Online: boolean = false;
}
export class TailnetStatus {
  ReadError: string = '';
  WriteError: string = '';
  SubnetRoutes: string[] = [];
  DNSSuffix: string = '';
  SentBytes: number = 0;
  ReceivedBytes: number = 0;
  Health: string[] = [];
  PeerList: TailnetPeer[] = [];
  updated: number = 0;
  BackendState: string = 'Stopped';
  AuthURL: string = '';
  TailscaleIPs: string[] = [];
  error: string = '';
  connected: boolean = false;
}
export function readTailnet(dir: string): TailnetStatus {
  try {
    const state = JSON.parse(fileIo.readTextSync(dir + '/tailnet-status.json')) as TailnetStatus;
    if (Date.now() - state.updated > 15000) { return new TailnetStatus(); }
    return state;
  }
  catch (_) { return new TailnetStatus(); }
}
export function writeTailnet(dir: string, state: TailnetStatus): void {
  state.updated = Date.now();
  const path = dir + '/tailnet-status.json';
  const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, JSON.stringify(state)); } finally { fileIo.closeSync(file); }
  fileIo.renameSync(path + '.tmp', path);
}
