export function escapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
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

export function renderKeyValue(obj: Record<string, any>): string {
  if (Object.keys(obj).length === 0) {
    return '<div style="color: #999; font-size: 12px;">No data</div>';
  }

  return `
    <div style="background: #2d2d2d; padding: 12px; border-radius: 4px; font-family: monospace; font-size: 12px;">
      ${Object.entries(obj).map(([key, value]) => `
        <div style="margin-bottom: 6px;">
          <span style="color: #9cdcfe;">${escapeHtml(key)}:</span>
          <span style="color: #ce9178; margin-left: 8px;">${escapeHtml(JSON.stringify(value))}</span>
        </div>
      `).join('')}
    </div>
  `;
}
