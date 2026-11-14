export interface TunnelStatus {
  sentBytes: number;
  receivedBytes: number;
  lastHandshake: number;
  selectedDNS: number;
  selectedFlows: number;
  directFlows: number;
  running: boolean;
}

export const openSocket: (listenPort: number) => number;
export const closeSocket: (fd: number) => void;
export const start: (tunFd: number, udpFd: number, config: string, mtu: number) => number;
export const startMany: (tunFd: number, udpFds: number[], configs: string[], mtu: number) => number;
export const startRouted: (tunFd: number, udpFds: number[], configs: string[], mtu: number,
  routing: string) => number;
export const updateRoutedDNS: (handle: number, dns: string) => void;
// Originals remain caller-owned; close all supplied descriptors after success or failure.
// Endpoint updates contain only existing public_key + numeric endpoint pairs (or empty strings).
export const rebindTransport: (handle: number, protectedUdpFds: number[], endpointUpdates: string[]) => void;
export const stop: (handle: number) => void;
export const status: (handle: number) => TunnelStatus;

export const detailStatus: (handle: number) => string;

/** Numeric-only process and Go runtime diagnostic JSON. No connection IDs,
 * domains, descriptor targets, or configuration. Each process/go counter has
 * { value: number, valid: boolean }; unavailable counters are not measured zero.
 * Go counters cover this native archive only; process counters cover the PID.
 * Recommended interval: 60 seconds. No network I/O or forced GC.
 */
export const resourceUsage: () => string;

/** Read-only current-session routing explanation. DNS runs on a native worker;
 * selected-network domains never leak to physical DNS. No business connection probe.
 * request JSON: {Target:string, ResolveDNS:boolean}; result is structured JSON.
 */
export const checkRoute: (handle: number, request: string) => Promise<string>;

/** Atomically updates physical DNS and on-link LAN prefixes after a network change. */
export const updateRoutedNetwork: (handle: number, network: string) => void;
