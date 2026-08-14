import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { TraceDetailResponse } from '../../api/traces'
import { TraceDetailPage } from './TraceDetailPage'

const traceId = 'a'.repeat(32)
const detail = {
  traceId,
  startTime: '2026-08-13T14:59:00Z',
  durationNanos: 1_000_000_000,
  spanCount: 2,
  error: true,
  spans: [
    {
      traceId, spanId: '1'.repeat(16), parentSpanId: null, name: 'POST /checkout',
      service: { name: 'checkout', namespace: 'store', environment: 'local' }, telemetryOrigin: 'monitored',
      kind: 'SERVER', status: 'ERROR', startTime: '2026-08-13T14:59:00Z', startOffsetNanos: 0,
      durationNanos: 1_000_000_000, error: true, errorType: 'IllegalStateException',
      http: { requestMethod: 'POST', route: '/checkout', path: '/checkout', responseStatusCode: 500, serverAddress: 'localhost', serverPort: 8081 },
    },
    {
      traceId, spanId: '2'.repeat(16), parentSpanId: '1'.repeat(16), name: 'reserve inventory',
      service: { name: 'inventory', namespace: null, environment: null }, telemetryOrigin: 'monitored',
      kind: 'INTERNAL', status: 'UNSET', startTime: '2026-08-13T14:59:00.200Z', startOffsetNanos: 200_000_000,
      durationNanos: 500_000_000, error: false, errorType: null, http: null,
    },
  ],
} satisfies TraceDetailResponse

function renderDetail(entry = `/traces/${traceId}?serviceName=checkout&environment=local&from=2026-08-13T14%3A45%3A00Z&to=2026-08-13T15%3A00%3A00Z`) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}><MemoryRouter initialEntries={[entry]}><Routes><Route path="/traces/:traceId" element={<TraceDetailPage />} /></Routes></MemoryRouter></QueryClientProvider>)
}

afterEach(() => vi.restoreAllMocks())

describe('Trace detail', () => {
  it('renders hierarchy, timing, HTTP metadata, and accessible error text', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify(detail), { status: 200 }))
    renderDetail()

    expect(screen.getByText('Loading trace detail…')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: 'Error trace' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Span waterfall' })).toBeInTheDocument()
    expect(screen.getByText('SERVER · POST /checkout 500')).toBeInTheDocument()
    expect(screen.getByText('IllegalStateException')).toBeInTheDocument()
    expect(screen.getByLabelText(/reserve inventory starts at 200.0 ms and lasts 500.0 ms/)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Back to trace search/ })).toHaveAttribute('href', expect.stringContaining('serviceName=checkout'))
  })

  it('returns an investigation-origin trace to the exact canonical investigation context', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify(detail), { status: 200 }))
    renderDetail(`/traces/${traceId}?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z&origin=investigate`)

    const back = await screen.findByRole('link', { name: /Back to service investigation/ })
    expect(back).toHaveAttribute(
      'href',
      '/investigate?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    )
  })

  it('keeps investigation return copy and context when trace detail fails', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 503 }))
    renderDetail(`/traces/${traceId}?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z&origin=investigate`)

    expect(await screen.findByRole('heading', { name: 'Trace storage is unavailable.' })).toBeInTheDocument()
    expect(screen.getByText('Return to service investigation or retry this request.')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Back to service investigation' })).toHaveAttribute(
      'href',
      '/investigate?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    )
  })

  it('distinguishes trace not found and supports retry', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      title: 'Trace not found', status: 404,
    }), { status: 404, headers: { 'Content-Type': 'application/problem+json' } }))
    renderDetail(`/traces/${traceId}`)

    expect(await screen.findByRole('heading', { name: 'Trace not found.' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('distinguishes a disabled traces route from a missing trace', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      title: 'Not Found', status: 404,
    }), { status: 404, headers: { 'Content-Type': 'application/problem+json' } }))
    renderDetail(`/traces/${traceId}`)

    expect(await screen.findByRole('heading', { name: 'Traces is not enabled for this Geordi deployment.' })).toBeInTheDocument()
  })

  it('distinguishes unavailable trace storage', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 503 }))
    renderDetail(`/traces/${traceId}`)

    expect(await screen.findByRole('heading', { name: 'Trace storage is unavailable.' })).toBeInTheDocument()
  })

  it.each([
    [502, 'Trace storage returned an invalid response.'],
    [504, 'Trace storage timed out.'],
  ])('distinguishes storage failure status %i', async (status, message) => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status }))
    renderDetail(`/traces/${traceId}`)

    expect(await screen.findByRole('heading', { name: message })).toBeInTheDocument()
  })
})
