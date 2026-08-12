import type { ModuleStatus } from '../../api/types'
import { usePlatformOverview } from './usePlatformOverview'

function statusLabel(status: ModuleStatus) {
  return status === 'DISABLED' ? 'Disabled' : status
}

export function PlatformOverview() {
  const overview = usePlatformOverview()

  if (overview.isPending) {
    return <main className="state-panel" aria-busy="true">Loading platform overview…</main>
  }

  if (overview.isError) {
    return (
      <main className="state-panel" role="alert">
        <p>Platform data is unavailable.</p>
        <p className="state-detail">Check that the Geordi backend is running and try again.</p>
        <button type="button" onClick={() => void overview.refetch()} disabled={overview.isFetching}>
          {overview.isFetching ? 'Retrying…' : 'Retry'}
        </button>
      </main>
    )
  }

  const { platform, modules, health } = overview.data

  return (
    <main>
      <header className="hero">
        <div>
          <p className="eyebrow">Platform overview</p>
          <h1>{platform.name}</h1>
          <p className="version">Version {platform.version}</p>
        </div>
        <div className={`platform-status status-${health.status.toLowerCase()}`}>
          <span>Platform status</span>
          <strong>{statusLabel(health.status)}</strong>
        </div>
      </header>

      <section aria-labelledby="modules-heading">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Capabilities</p>
            <h2 id="modules-heading">Installed modules</h2>
          </div>
          <span>{modules.length} total</span>
        </div>

        <div className="module-grid">
          {modules.map((module) => {
            const healthModule = health.modules.find((candidate) => candidate.id === module.id)
            const status = healthModule?.status ?? 'UNKNOWN'

            return (
              <article className={`module-card ${module.enabled ? '' : 'module-disabled'}`} key={module.id}>
                <div>
                  <h3>{module.name}</h3>
                  <code>{module.id}</code>
                </div>
                <dl>
                  <div>
                    <dt>Availability</dt>
                    <dd>{module.enabled ? 'Enabled' : 'Disabled'}</dd>
                  </div>
                  <div>
                    <dt>Health</dt>
                    <dd><span className={`status-pill status-${status.toLowerCase()}`}>{statusLabel(status)}</span></dd>
                  </div>
                </dl>
              </article>
            )
          })}
        </div>
      </section>
    </main>
  )
}
