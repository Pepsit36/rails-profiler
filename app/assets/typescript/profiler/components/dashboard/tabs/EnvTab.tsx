import { useState, useMemo, useEffect, useRef } from 'preact/hooks'
import { EnvData } from '../../../dashboard/types'

interface Props {
  envData: EnvData | undefined
}

interface Flash {
  type: 'success' | 'error'
  message: string
}

interface TypeBadge {
  label: string
  color: string
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function detectType(value: string): TypeBadge | null {
  if (value === '') return { label: 'empty', color: 'var(--profiler-text-muted)' }
  if (/^(true|false|yes|no)$/i.test(value)) return { label: 'bool', color: '#a78bfa' }
  if (/^\d+$/.test(value)) return { label: 'int', color: 'var(--profiler-success,#22c55e)' }
  if (/^\d+\.\d+$/.test(value)) return { label: 'float', color: 'var(--profiler-success,#22c55e)' }
  return { label: 'string', color: 'var(--profiler-text-muted)' }
}

function getPrefix(key: string): string {
  const idx = key.indexOf('_')
  return idx > 0 ? key.slice(0, idx) : 'OTHER'
}

function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {}
  for (const raw of content.split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const key = line.slice(0, eq).trim()
    let value = line.slice(eq + 1)
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    result[key] = value
  }
  return result
}

function loadUnmasked(): Set<string> {
  try {
    const raw = localStorage.getItem('profiler_unmasked_env_keys')
    return raw ? new Set(JSON.parse(raw)) : new Set()
  } catch {
    return new Set()
  }
}

function saveUnmasked(keys: Set<string>) {
  try {
    localStorage.setItem('profiler_unmasked_env_keys', JSON.stringify([...keys]))
  } catch {}
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function TypeBadgeComp({ value }: { value: string }) {
  const badge = detectType(value)
  if (!badge) return null
  return (
    <span style={{
      display: 'inline-block',
      padding: '0 5px',
      borderRadius: '3px',
      fontSize: '10px',
      fontWeight: 600,
      fontFamily: 'monospace',
      border: `1px solid ${badge.color}`,
      color: badge.color,
      marginRight: '6px',
      verticalAlign: 'middle',
      lineHeight: '16px',
      flexShrink: 0,
    }}>
      {badge.label}
    </span>
  )
}

function isBool(value: string): boolean {
  return /^(true|false|yes|no)$/i.test(value)
}

function isQuoted(value: string): boolean {
  if (value === '') return false
  if (isBool(value)) return false
  if (/^\d+(\.\d+)?$/.test(value)) return false  // int or float
  return true
}

async function patchEnvVar(key: string, value: string | null): Promise<void> {
  const res = await fetch('/_profiler/api/env_vars', {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key, value }),
  })
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    throw new Error(body.error ?? `Request failed (${res.status})`)
  }
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export function EnvTab({ envData }: Props) {
  const initial = useMemo(() => ({ ...(envData?.variables ?? {}) }), [])

  const [variables, setVariables] = useState<Record<string, string>>(initial)
  const [total, setTotal] = useState(envData?.total ?? 0)
  const [search, setSearch] = useState('')
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(new Set())
  const [editingKey, setEditingKey] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')
  const [newKey, setNewKey] = useState('')
  const [newValue, setNewValue] = useState('')
  const [flash, setFlash] = useState<Flash | null>(null)
  const [saving, setSaving] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [unmaskedKeys, setUnmaskedKeys] = useState<Set<string>>(loadUnmasked)
  const [copiedId, setCopiedId] = useState<string | null>(null)
  const [readOnly, setReadOnly] = useState(false)
  const [showImport, setShowImport] = useState(false)
  const [importContent, setImportContent] = useState('')
  const editInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (editingKey !== null) editInputRef.current?.focus()
  }, [editingKey])

  useEffect(() => {
    refresh()
  }, [])

  const showFlash = (type: Flash['type'], message: string) => {
    setFlash({ type, message })
    setTimeout(() => setFlash(null), 3000)
  }

  // --- Masking ---

  const toggleUnmask = (key: string) => {
    setUnmaskedKeys(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key); else next.add(key)
      saveUnmasked(next)
      return next
    })
  }

  // --- Clipboard ---

  const copy = async (text: string, id: string) => {
    try {
      await navigator.clipboard.writeText(text)
      setCopiedId(id)
      setTimeout(() => setCopiedId(null), 1500)
    } catch {
      showFlash('error', 'Clipboard access denied')
    }
  }

  // --- Grouping ---

  const toggleGroup = (prefix: string) => {
    setCollapsedGroups(prev => {
      const next = new Set(prev)
      if (next.has(prefix)) next.delete(prefix); else next.add(prefix)
      return next
    })
  }

  // --- Refresh ---

  const refresh = async () => {
    setRefreshing(true)
    try {
      const res = await fetch('/_profiler/api/env_vars')
      if (!res.ok) throw new Error(`Request failed (${res.status})`)
      const data = await res.json()
      setVariables(data.variables)
      setTotal(data.total)
      showFlash('success', `Refreshed — ${data.total} variables`)
    } catch (e: any) {
      showFlash('error', e.message ?? 'Failed to refresh')
    } finally {
      setRefreshing(false)
    }
  }

  // --- Export ---

  const exportEnv = () => {
    const entries = filteredEntries
    const content = entries.map(([k, v]) => `${k}=${v}`).join('\n') + '\n'
    const blob = new Blob([content], { type: 'text/plain' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = '.env'
    a.click()
    URL.revokeObjectURL(url)
    showFlash('success', `Exported ${entries.length} variables`)
  }

  // --- Import ---

  const importPreview = useMemo(() => parseEnvFile(importContent), [importContent])
  const importCount = Object.keys(importPreview).length

  const importEnv = async () => {
    const entries = Object.entries(importPreview)
    if (!entries.length) return
    setSaving(true)
    try {
      await Promise.all(entries.map(([k, v]) => patchEnvVar(k, v)))
      setVariables(prev => ({ ...prev, ...importPreview }))
      setImportContent('')
      setShowImport(false)
      showFlash('success', `Imported ${entries.length} variables`)
    } catch (e: any) {
      showFlash('error', e.message ?? 'Import failed')
    } finally {
      setSaving(false)
    }
  }

  // --- Edit ---

  const startEdit = (key: string) => { setEditingKey(key); setEditValue(variables[key] ?? '') }
  const cancelEdit = () => { setEditingKey(null); setEditValue('') }

  const saveEdit = async () => {
    if (!editingKey) return
    setSaving(true)
    try {
      await patchEnvVar(editingKey, editValue)
      setVariables(prev => ({ ...prev, [editingKey]: editValue }))
      showFlash('success', `${editingKey} updated`)
      setEditingKey(null)
    } catch (e: any) {
      showFlash('error', e.message ?? 'Failed to update')
    } finally {
      setSaving(false)
    }
  }

  const deleteVar = async (key: string) => {
    setSaving(true)
    try {
      await patchEnvVar(key, null)
      setVariables(prev => { const n = { ...prev }; delete n[key]; return n })
      setUnmaskedKeys(prev => { const n = new Set(prev); n.delete(key); saveUnmasked(n); return n })
      showFlash('success', `${key} deleted`)
    } catch (e: any) {
      showFlash('error', e.message ?? 'Failed to delete')
    } finally {
      setSaving(false)
    }
  }

  const toggleBool = async (key: string, current: string) => {
    const next = /^(true|yes)$/i.test(current) ? 'false' : 'true'
    setSaving(true)
    try {
      await patchEnvVar(key, next)
      setVariables(prev => ({ ...prev, [key]: next }))
    } catch (e: any) {
      showFlash('error', e.message ?? 'Failed to update')
    } finally {
      setSaving(false)
    }
  }

  const addVar = async () => {
    const key = newKey.trim()
    if (!key) return
    setSaving(true)
    try {
      await patchEnvVar(key, newValue)
      setVariables(prev => ({ ...prev, [key]: newValue }))
      setNewKey(''); setNewValue('')
      showFlash('success', `${key} added`)
    } catch (e: any) {
      showFlash('error', e.message ?? 'Failed to add')
    } finally {
      setSaving(false)
    }
  }

  const handleEditKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') saveEdit()
    if (e.key === 'Escape') cancelEdit()
  }

  // --- Filtered + grouped entries ---

  const allEntries = Object.entries(variables)

  const filteredEntries = useMemo(() => {
    const q = search.toLowerCase().trim()
    if (!q) return allEntries
    return allEntries.filter(([k, v]) =>
      k.toLowerCase().includes(q) || v.toLowerCase().includes(q)
    )
  }, [variables, search])

  const groups = useMemo(() => {
    const map: Record<string, [string, string][]> = {}
    for (const entry of filteredEntries) {
      const p = getPrefix(entry[0])
      ;(map[p] ??= []).push(entry)
    }
    return Object.entries(map).sort(([a], [b]) =>
      a === 'OTHER' ? 1 : b === 'OTHER' ? -1 : a.localeCompare(b)
    )
  }, [filteredEntries])

  // --- Global mask toggle ---

  const allRevealed = filteredEntries.every(([k]) => unmaskedKeys.has(k))

  const toggleAllMasks = () => {
    const keys = filteredEntries.map(([k]) => k)
    setUnmaskedKeys(prev => {
      const next = new Set(prev)
      if (allRevealed) {
        keys.forEach(k => next.delete(k))
      } else {
        keys.forEach(k => next.add(k))
      }
      saveUnmasked(next)
      return next
    })
  }

  // --- Styles ---

  const inputStyle = "width:100%;font-family:monospace;font-size:12px;padding:2px 6px;border:1px solid var(--profiler-border);border-radius:4px;background:var(--profiler-bg);color:var(--profiler-text);"
  const iconBtn = "background:none;border:none;cursor:pointer;font-size:12px;padding:0 3px;color:var(--profiler-text-muted);opacity:0.7;flex-shrink:0;"
  const headerBtn = "background:none;border:1px solid var(--profiler-border);border-radius:4px;cursor:pointer;color:var(--profiler-text-muted);font-size:11px;padding:3px 8px;"

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  return (
    <>
      {/* Header */}
      <div class="profiler-flex profiler-mb-4" style="align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;">
        <h2 class="profiler-section__header" style="margin:0;">Environment Variables</h2>
        <div class="profiler-flex profiler-flex--gap-2">
          <button onClick={refresh} disabled={refreshing} style={headerBtn}>
            {refreshing ? '…' : '↺ Refresh'}
          </button>
          <button onClick={() => setShowImport(v => !v)} style={`${headerBtn}${showImport ? 'border-color:var(--profiler-accent);color:var(--profiler-accent);' : ''}`}>
            ⬆ Import
          </button>
          <button onClick={exportEnv} style={headerBtn}>
            ⬇ Export
          </button>
          <button onClick={toggleAllMasks} style={headerBtn}>
            {allRevealed ? '🙈 Mask all' : '👁 Reveal all'}
          </button>
          <button
            onClick={() => setReadOnly(v => !v)}
            title={readOnly ? 'Unlock editing' : 'Lock editing'}
            style={`${headerBtn}${readOnly ? 'border-color:var(--profiler-error,#ef4444);color:var(--profiler-error,#ef4444);' : ''}`}
          >
            {readOnly ? '🔒 Locked' : '🔓 Edit'}
          </button>
        </div>
      </div>

      {/* Warning */}
      <div style="background:var(--profiler-warning-bg,rgba(245,158,11,0.1));border:1px solid var(--profiler-warning,#f59e0b);border-radius:6px;padding:8px 12px;margin-bottom:16px;font-size:12px;color:var(--profiler-warning,#f59e0b);">
        ⚠ Changes affect the current process only — for development use.
      </div>

      {/* Flash */}
      {flash && (
        <div style={`background:${flash.type === 'success' ? 'var(--profiler-success-bg,rgba(34,197,94,0.1))' : 'var(--profiler-error-bg,rgba(239,68,68,0.08))'};border:1px solid ${flash.type === 'success' ? 'var(--profiler-success,#22c55e)' : 'var(--profiler-error,#ef4444)'};border-radius:6px;padding:6px 12px;margin-bottom:12px;font-size:12px;color:${flash.type === 'success' ? 'var(--profiler-success,#22c55e)' : 'var(--profiler-error,#ef4444)'};`}>
          {flash.type === 'success' ? '✓' : '✗'} {flash.message}
        </div>
      )}

      {/* Import panel */}
      {showImport && (
        <div style="border:1px solid var(--profiler-border);border-radius:6px;padding:12px;margin-bottom:16px;">
          <p class="profiler-text--xs profiler-text--muted" style="margin:0 0 8px;">
            Paste the contents of a <code>.env</code> file. Comments and blank lines are ignored.
          </p>
          <textarea
            value={importContent}
            onInput={(e) => setImportContent((e.target as HTMLTextAreaElement).value)}
            placeholder={'APP_NAME=MyApp\nFEATURE_BETA=true\n# comment'}
            rows={6}
            style="width:100%;font-family:monospace;font-size:12px;padding:6px 8px;border:1px solid var(--profiler-border);border-radius:4px;background:var(--profiler-bg);color:var(--profiler-text);resize:vertical;box-sizing:border-box;"
          />
          <div class="profiler-flex profiler-flex--gap-2 profiler-mt-2" style="align-items:center;">
            {importCount > 0 && (
              <span class="profiler-text--xs profiler-text--muted">
                {importCount} variable{importCount !== 1 ? 's' : ''} to import
              </span>
            )}
            <button
              onClick={importEnv}
              disabled={saving || importCount === 0}
              style="background:var(--profiler-accent);border:none;cursor:pointer;color:#fff;font-size:11px;padding:4px 12px;border-radius:4px;margin-left:auto;"
            >
              Apply
            </button>
          </div>
        </div>
      )}

      {/* Stats */}
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4">
        <div class="profiler-stat-card">
          <div class="profiler-stat-card__value">{total}</div>
          <div class="profiler-stat-card__label">Total vars</div>
        </div>
        {search && (
          <div class="profiler-stat-card">
            <div class="profiler-stat-card__value">{filteredEntries.length}</div>
            <div class="profiler-stat-card__label">Matching</div>
          </div>
        )}
      </div>

      {/* Search */}
      <div class="profiler-flex profiler-flex--gap-2 profiler-mb-3">
        <input
          type="text"
          class="profiler-filter-input"
          placeholder="Filter by key or value…"
          value={search}
          onInput={(e) => setSearch((e.target as HTMLInputElement).value)}
          style="flex:1;"
        />
      </div>

      {/* Table */}
      <table class="profiler-table">
        <thead>
          <tr>
            <th style="width:32%">Key</th>
            <th>Value</th>
            {!readOnly && <th style="width:120px;text-align:right;"></th>}
          </tr>
        </thead>
        <tbody>
          {groups.map(([prefix, entries]) => {
            const collapsed = collapsedGroups.has(prefix)
            return (
              <>
                {/* Group header */}
                <tr
                  key={`group-${prefix}`}
                  onClick={() => toggleGroup(prefix)}
                  style="cursor:pointer;background:var(--profiler-bg-subtle,rgba(0,0,0,0.03));"
                >
                  <td colspan={readOnly ? 2 : 3} style="padding:4px 8px;">
                    <span style="font-size:11px;font-weight:600;color:var(--profiler-text-muted);letter-spacing:0.05em;font-family:monospace;">
                      {collapsed ? '▶' : '▼'} {prefix}_
                    </span>
                    <span style="font-size:10px;color:var(--profiler-text-muted);margin-left:6px;">
                      {entries.length}
                    </span>
                  </td>
                </tr>

                {/* Group rows */}
                {!collapsed && entries.map(([key, value]) => {
                  const unmasked = unmaskedKeys.has(key)
                  const isEditing = editingKey === key
                  const isCopiedVal = copiedId === key
                  const isCopiedKey = copiedId === `__key__${key}`
                  const wasModified = initial[key] !== undefined && initial[key] !== value
                  const wasAdded = initial[key] === undefined
                  const diffStyle = wasModified
                    ? 'border-left:3px solid #f59e0b;'
                    : wasAdded
                    ? 'border-left:3px solid var(--profiler-success,#22c55e);'
                    : ''

                  return (
                    <tr key={key} style={diffStyle}>
                      <td>
                        <div class="profiler-flex" style="align-items:center;gap:4px;">
                          <code class="profiler-text--xs profiler-text--mono">{key}</code>
                          <button
                            onClick={() => copy(key, `__key__${key}`)}
                            title="Copy key"
                            style={`${iconBtn}${isCopiedKey ? 'color:var(--profiler-success,#22c55e);opacity:1;' : ''}`}
                          >
                            {isCopiedKey ? '✓' : '⎘'}
                          </button>
                        </div>
                      </td>
                      <td>
                        {isEditing ? (
                          <div class="profiler-flex" style="align-items:center;gap:2px;">
                            {isQuoted(editValue) && <span style="font-family:monospace;font-size:12px;color:var(--profiler-text-muted);opacity:0.5;flex-shrink:0;">"</span>}
                            <input
                              ref={editInputRef}
                              type="text"
                              value={editValue}
                              onInput={(e) => setEditValue((e.target as HTMLInputElement).value)}
                              onKeyDown={handleEditKeyDown}
                              disabled={saving}
                              style="flex:1;font-family:monospace;font-size:12px;padding:2px 6px;border:1px solid var(--profiler-accent);border-radius:4px;background:var(--profiler-bg);color:var(--profiler-text);"
                            />
                            {isQuoted(editValue) && <span style="font-family:monospace;font-size:12px;color:var(--profiler-text-muted);opacity:0.5;flex-shrink:0;">"</span>}
                          </div>
                        ) : isBool(value) ? (
                          <>
                            <div class="profiler-flex" style="align-items:center;gap:8px;">
                              <TypeBadgeComp value={value} />
                              <button
                                onClick={() => !readOnly && !saving && toggleBool(key, value)}
                                disabled={saving || readOnly}
                                title={`Click to set ${/^(true|yes)$/i.test(value) ? 'false' : 'true'}`}
                                style={`position:relative;display:inline-block;width:36px;height:20px;border-radius:10px;border:none;cursor:${readOnly || saving ? 'default' : 'pointer'};padding:0;transition:background 0.2s;background:${/^(true|yes)$/i.test(value) ? 'var(--profiler-accent)' : 'var(--profiler-border,#d1d5db)'};flex-shrink:0;`}
                              >
                                <span style={`position:absolute;top:3px;width:14px;height:14px;border-radius:50%;background:#fff;transition:left 0.2s;left:${/^(true|yes)$/i.test(value) ? '19px' : '3px'};`} />
                              </button>
                              <span class="profiler-text--xs profiler-text--mono" style="color:var(--profiler-text-muted);">
                                {value}
                              </span>
                              <button
                                onClick={() => copy(value, key)}
                                title="Copy value"
                                style={`${iconBtn}${isCopiedVal ? 'color:var(--profiler-success,#22c55e);opacity:1;' : ''}`}
                              >
                                {isCopiedVal ? '✓' : '⎘'}
                              </button>
                            </div>
                            {wasModified && (
                              <div style="font-size:10px;color:#f59e0b;margin-top:2px;font-family:monospace;">
                                was: {initial[key]}
                              </div>
                            )}
                          </>
                        ) : (
                          <>
                            <div class="profiler-flex" style="align-items:center;gap:4px;">
                              <TypeBadgeComp value={value} />
                              <span
                                class="profiler-text--xs profiler-text--mono"
                                style="word-break:break-all;flex:1;"
                              >
                                {unmasked
                                  ? isQuoted(value)
                                    ? <><span style="color:var(--profiler-text-muted);opacity:0.5;">"</span>{value}<span style="color:var(--profiler-text-muted);opacity:0.5;">"</span></>
                                    : value
                                  : '•'.repeat(Math.min(value.length, 20))
                                }
                              </span>
                              <button
                                onClick={() => toggleUnmask(key)}
                                title={unmasked ? 'Hide value' : 'Show value'}
                                style={`${iconBtn}${unmasked ? 'opacity:1;color:var(--profiler-accent);' : ''}`}
                              >
                                {unmasked ? '👁' : '🙈'}
                              </button>
                              <button
                                onClick={() => copy(value, key)}
                                title="Copy value"
                                style={`${iconBtn}${isCopiedVal ? 'color:var(--profiler-success,#22c55e);opacity:1;' : ''}`}
                              >
                                {isCopiedVal ? '✓' : '⎘'}
                              </button>
                            </div>
                            {wasModified && (
                              <div style="font-size:10px;color:#f59e0b;margin-top:2px;font-family:monospace;">
                                was: {unmasked
                                  ? isQuoted(initial[key])
                                    ? `"${initial[key]}"`
                                    : initial[key]
                                  : '•'.repeat(Math.min(initial[key].length, 20))
                                }
                              </div>
                            )}
                          </>
                        )}
                      </td>
                      {!readOnly && (
                        <td style="text-align:right;white-space:nowrap;">
                          {isEditing ? (
                            <>
                              <button onClick={saveEdit} disabled={saving} title="Save" style="background:none;border:none;cursor:pointer;color:var(--profiler-success,#22c55e);font-size:14px;padding:0 4px;">✓</button>
                              <button onClick={cancelEdit} disabled={saving} title="Cancel" style="background:none;border:none;cursor:pointer;color:var(--profiler-text-muted);font-size:14px;padding:0 4px;">✗</button>
                            </>
                          ) : isBool(value) ? (
                            <>
                              <button onClick={() => startEdit(key)} disabled={saving} style="background:none;border:none;cursor:pointer;color:var(--profiler-accent);font-size:11px;padding:0 4px;">Edit</button>
                              <button onClick={() => deleteVar(key)} disabled={saving} style="background:none;border:none;cursor:pointer;color:var(--profiler-error,#ef4444);font-size:11px;padding:0 4px;">Delete</button>
                            </>
                          ) : (
                            <>
                              <button onClick={() => startEdit(key)} disabled={saving} style="background:none;border:none;cursor:pointer;color:var(--profiler-accent);font-size:11px;padding:0 4px;">Edit</button>
                              <button onClick={() => deleteVar(key)} disabled={saving} style="background:none;border:none;cursor:pointer;color:var(--profiler-error,#ef4444);font-size:11px;padding:0 4px;">Delete</button>
                            </>
                          )}
                        </td>
                      )}
                    </tr>
                  )
                })}
              </>
            )
          })}

          {/* Add row */}
          {!readOnly && (
            <tr>
              <td>
                <input
                  type="text"
                  value={newKey}
                  onInput={(e) => setNewKey((e.target as HTMLInputElement).value)}
                  onKeyDown={(e) => e.key === 'Enter' && addVar()}
                  placeholder="NEW_KEY"
                  disabled={saving}
                  style={inputStyle}
                />
              </td>
              <td>
                <input
                  type="text"
                  value={newValue}
                  onInput={(e) => setNewValue((e.target as HTMLInputElement).value)}
                  onKeyDown={(e) => e.key === 'Enter' && addVar()}
                  placeholder="value"
                  disabled={saving}
                  style={inputStyle}
                />
              </td>
              <td style="text-align:right;">
                <button
                  onClick={addVar}
                  disabled={saving || !newKey.trim()}
                  style="background:var(--profiler-accent);border:none;cursor:pointer;color:#fff;font-size:11px;padding:3px 8px;border-radius:4px;"
                >Add</button>
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </>
  )
}
