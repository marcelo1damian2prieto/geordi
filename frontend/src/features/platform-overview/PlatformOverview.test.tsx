import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from '../../App'

const platform = { id: 'geordi', name: 'Geordi', version: '0.1.0-SNAPSHOT' }
const modules = {
  modules: [
    { id: 'core', name: 'Core', enabled: true },
    { id: 'self-observability', name: 'Self Observability', enabled: false },
  ],
}
const health = {
  status: 'UP',
  modules: [
    { ...modules.modules[0], status: 'UP' },
    { ...modules.modules[1], status: 'DISABLED' },
  ],
}

function jsonResponse(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  }))
}

function requestUrl(input: string | URL | Request) {
  if (typeof input === 'string') return input
  return input instanceof URL ? input.toString() : input.url
}

function renderApp() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <App />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => vi.restoreAllMocks())

describe('Platform overview', () => {
  it('shows real platform health and makes disabled modules unmistakable', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = requestUrl(input)
      if (url.endsWith('/api/platform')) return jsonResponse(platform)
      if (url.endsWith('/api/modules')) return jsonResponse(modules)
      return jsonResponse(health)
    })

    renderApp()

    expect(screen.getByText('Loading platform overview…')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: 'Geordi' })).toBeInTheDocument()
    expect(screen.getByText('Version 0.1.0-SNAPSHOT')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Core' })).toBeInTheDocument()

    const disabledModule = screen.getByRole('heading', { name: 'Self Observability' }).closest('article')
    expect(disabledModule).toHaveClass('module-disabled')
    expect(disabledModule).toHaveTextContent('AvailabilityDisabled')
    expect(disabledModule).toHaveTextContent('HealthDisabled')
  })

  it('explains an API failure and can refetch successfully', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => jsonResponse({}, 503))
      .mockImplementationOnce(() => jsonResponse(modules))
      .mockImplementationOnce(() => jsonResponse(health))
      .mockImplementation((input) => {
        const url = requestUrl(input)
        if (url.endsWith('/api/platform')) return jsonResponse(platform)
        if (url.endsWith('/api/modules')) return jsonResponse(modules)
        return jsonResponse(health)
      })

    renderApp()

    expect(await screen.findByRole('alert')).toHaveTextContent('Platform data is unavailable.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))

    expect(await screen.findByRole('heading', { name: 'Geordi' })).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(6)
  })
})
