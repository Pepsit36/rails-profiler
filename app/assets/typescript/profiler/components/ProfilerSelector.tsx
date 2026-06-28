import { useState, useEffect } from 'preact/hooks'
import { setActiveSlave, getActiveSlaveName } from '../cluster-context'

interface SlaveEntry {
  name: string
  url: string
  status: 'online' | 'offline'
  registered_at: string
  last_heartbeat_at: string
}

export function ProfilerSelector() {
  const [slaves, setSlaves] = useState<SlaveEntry[]>([])
  const [loading, setLoading] = useState(true)

  const activeSlave = getActiveSlaveName()

  useEffect(() => {
    fetch('/_profiler/api/cluster/slaves')
      .then(r => r.json())
      .then(data => {
        setSlaves(data.slaves ?? [])
        setLoading(false)
      })
      .catch(() => setLoading(false))
  }, [])

  if (loading || slaves.length === 0) return null

  const handleChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value
    setActiveSlave(value === '__local__' ? null : value)
  }

  const currentValue = activeSlave ?? '__local__'

  return (
    <div class="profiler-selector" style={{ display: 'flex', alignItems: 'center', gap: '8px', padding: '4px 12px', background: 'var(--profiler-bg-secondary, #f5f5f5)', borderBottom: '1px solid var(--profiler-border, #e0e0e0)' }}>
      <span style={{ fontSize: '12px', fontWeight: 600, color: 'var(--profiler-text-secondary, #666)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        Profiler
      </span>
      <select
        value={currentValue}
        onChange={handleChange}
        style={{ fontSize: '13px', padding: '2px 6px', borderRadius: '4px', border: '1px solid var(--profiler-border, #ccc)', background: 'var(--profiler-bg, #fff)', color: 'var(--profiler-text, #333)', cursor: 'pointer' }}
      >
        <option value="__local__">Local (master)</option>
        {slaves.map(slave => (
          <option
            key={slave.name}
            value={slave.name}
            disabled={slave.status === 'offline'}
          >
            {slave.name} {slave.status === 'offline' ? '(offline)' : ''}
          </option>
        ))}
      </select>
      {activeSlave && (
        <span style={{ fontSize: '11px', color: 'var(--profiler-text-secondary, #888)', fontStyle: 'italic' }}>
          Viewing slave data via proxy
        </span>
      )}
    </div>
  )
}
