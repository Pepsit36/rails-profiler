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
