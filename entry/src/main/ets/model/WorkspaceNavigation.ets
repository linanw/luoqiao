// Only the currently open drawer owns Back; hidden pages never retain a handler.
let drawerDismiss: (() => void) | undefined = undefined;

export function registerWorkspaceDrawer(dismiss: () => void): void {
  drawerDismiss = dismiss;
}

export function releaseWorkspaceDrawer(dismiss: () => void): void {
  if (drawerDismiss === dismiss) { drawerDismiss = undefined; }
}

export function dismissWorkspaceDrawer(): boolean {
  const dismiss = drawerDismiss;
  if (!dismiss) { return false; }
  drawerDismiss = undefined;
  dismiss();
  return true;
}
