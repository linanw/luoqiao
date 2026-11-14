/** 'resources' returns numeric-only process and this archive's Go runtime
 * counters. Each process/go counter is {value:number, valid:boolean}.
 */
export const call: (operation: string, ...args: (string | number)[]) => Promise<string>;
