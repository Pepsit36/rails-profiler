export function getGemVersion(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="profiler-version"]')?.content ?? ''
}

export function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

export function formatMemoryMB(bytes: number | undefined): string {
  if (!bytes) return '0';
  return (bytes / (1024 * 1024)).toFixed(2);
}

// Objects allocated while the profile ran. Profiles saved by earlier versions only carry
// `memory`, which was that count times 40 and never a measured byte figure.
export function allocatedObjects(profile: { allocated_objects?: number | null; memory?: number | null }): number | null {
  if (profile.allocated_objects != null) return profile.allocated_objects
  return profile.memory != null ? Math.round(profile.memory / 40) : null
}

export function formatAllocations(count: number | null | undefined): string {
  return count == null ? '-' : `${count.toLocaleString('en')} objects`
}

export const ALLOCATIONS_HINT =
  'Objects allocated by the whole process while this ran: on a multi-threaded server, it includes what other threads allocated meanwhile.'
