import { NetworkNodeStatus, readNetworkStatus } from './NetworkProfiles';
import { readTailnet, TailnetPeer } from './TailnetState';
import { readTunnelState, TunnelPhase } from './TunnelState';

export class TailnetConnectionView {
  node: NetworkNodeStatus = new NetworkNodeStatus();
  active: boolean = false;
  mode: string = '';
  label: string = '未连接';
}

function normalizeNode(source: NetworkNodeStatus): NetworkNodeStatus {
  const node = new NetworkNodeStatus();
  node.ID = source.ID; node.Name = source.Name; node.BackendState = source.BackendState || '';
  node.AuthURL = source.AuthURL || ''; node.Error = source.Error || ''; node.DNSSuffix = source.DNSSuffix || '';
  node.TailscaleIPs = source.TailscaleIPs || []; node.ExitNodes = source.ExitNodes || [];
  node.PeerIPs = source.PeerIPs || []; node.PeerNames = source.PeerNames || []; node.SubnetRoutes = source.SubnetRoutes || [];
  return node;
}

function label(view: TailnetConnectionView): string {
  const node = view.node;
  if (node.BackendState === 'Stopping') { return '断开中'; }
  if (node.BackendState === 'Reconnecting') { return '重连中'; }
  if (node.AuthURL || node.BackendState === 'NeedsLogin') { return '待登录'; }
  if (node.BackendState === 'NeedsMachineAuth') { return '待管理员批准'; }
  if (node.Error) { return '连接异常'; }
  if (node.BackendState === 'Running') { return '已连接'; }
  return view.active ? '连接中' : '未连接';
}

export function readTailnetConnectionView(directory: string, id: string): TailnetConnectionView {
  const view = new TailnetConnectionView(); view.node.ID = id;
  const mixed = readTunnelState(directory);
  if (mixed?.mixed && Date.now() - mixed.updated >= -5000 && Date.now() - mixed.updated < 15000 && mixed.tailnetIds.includes(id)) {
    view.active = [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected, TunnelPhase.Stopping].includes(mixed.phase);
    if (view.active) {
      view.mode = '组合连接';
      const node = mixed.tailnetNodes.find((item: NetworkNodeStatus): boolean => item.ID === id);
      if (node) { view.node = normalizeNode(node); }
      if (mixed.networkError) { view.node.BackendState = 'Reconnecting'; view.node.Error = mixed.networkError; }
      if (mixed.phase === TunnelPhase.Stopping) { view.node.BackendState = 'Stopping'; view.node.AuthURL = ''; }
    } else if (mixed.phase === TunnelPhase.Failed) {
      view.node.Error = mixed.message;
    }
    if (view.active || mixed.phase === TunnelPhase.Failed) { view.label = label(view); return view; }
  }
  const multi = readNetworkStatus(directory);
  if (multi.active) {
    const node = multi.Nodes.find((item: NetworkNodeStatus): boolean => item.ID === id);
    if (node) { view.active = true; view.mode = '多 Tailnet 连接'; view.node = normalizeNode(node); }
  }
  if (!view.active && id === 'legacy') {
    const legacy = readTailnet(directory);
    if (legacy.BackendState !== 'Stopped') {
      view.active = legacy.BackendState !== 'Failed'; view.mode = '独立连接';
      view.node.BackendState = legacy.BackendState; view.node.AuthURL = legacy.AuthURL;
      view.node.Error = legacy.error; view.node.DNSSuffix = legacy.DNSSuffix;
      view.node.TailscaleIPs = legacy.TailscaleIPs || []; view.node.SubnetRoutes = legacy.SubnetRoutes || [];
      view.node.PeerNames = (legacy.PeerList || []).map((peer: TailnetPeer): string => peer.DNSName || peer.HostName);
    }
  }
  view.label = label(view); return view;
}
