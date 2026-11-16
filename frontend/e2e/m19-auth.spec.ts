import { expect, test } from '@playwright/test'
import { appendFileSync } from 'node:fs'
import { resolve } from 'node:path'

interface BrowserIdentity {
  issuer: string
  subject: string
  permissions: string[]
  authMode: string
}

interface BrowserCsrf {
  headerName: string
  token: string
}

function recordPrivateSentinel(value: string) {
  const path = process.env.GEORDI_M19_BROWSER_SENTINEL_FILE
  if (!path) throw new Error('M19 private sentinel capture is unavailable')
  appendFileSync(resolve(path), `${value}\n`, { encoding: 'utf8', mode: 0o600 })
}

function safeBrowserLocation(value: string) {
  const url = new URL(value)
  return {
    origin: url.origin,
    pathname: url.pathname,
    hasSearch: url.search.length > 0,
    hasHash: url.hash.length > 0,
  }
}

test('M19 browser OIDC, session, CSRF and logout flow', async ({ page }) => {
  let browserConsoleMarkerObserved = false
  page.on('console', message => {
    console.log(`BROWSER_CONSOLE type=${message.type()} text=${message.text()}`)
    console.log(`BROWSER_CONSOLE type=${message.type()} text=${message.text()}`)
    if (message.text() === 'M19_BROWSER_RUNTIME_CAPTURE') {
      browserConsoleMarkerObserved = true
      console.log('M19_BROWSER_RUNTIME_CAPTURE')
    }
  })
  const diagnosticProbe = 'https://geordi.localhost:8443/login/oauth2/code/geordi?code=private-code-sentinel&state=private-state-sentinel'
  let sanitizedFailure = ''
  try { expect(safeBrowserLocation(diagnosticProbe)).toEqual({ origin: 'https://geordi.localhost:8443', pathname: '/', hasSearch: false, hasHash: false }) }
  catch (failure) { sanitizedFailure = failure instanceof Error ? failure.message : String(failure) }
  expect(!sanitizedFailure.includes('private-code-sentinel') && !sanitizedFailure.includes('private-state-sentinel')).toBe(true)
  const cookieFacts: Array<{ host: string; path: string; maxAge?: string; name: string; secure: boolean; httpOnly: boolean; sameSiteLax: boolean; hasDomain: boolean }> = []
  const requestCookieNames: string[] = []
  page.on('request', async request => {
    const url = new URL(request.url())
    console.log(`BROWSER_REQUEST method=${request.method()} host=${url.host} path=${url.pathname}`)
    if (url.pathname === '/login/oauth2/code/geordi') {
      for (const key of ['code', 'state']) {
        const value = url.searchParams.get(key)
        if (value) recordPrivateSentinel(value)
      }
      const cookieHeader = (await request.allHeaders()).cookie ?? ''
      for (const part of cookieHeader.split(';')) {
        const [name, ...value] = part.trim().split('=')
        if (name === '__Host-Geordi-OIDC' && value.length) recordPrivateSentinel(value.join('='))
      }
      requestCookieNames.push(...cookieHeader.split(';').map(part => part.trim().split('=')[0]).filter(Boolean))
    }
  })
  page.on('response', async response => {
    const url = new URL(response.url())
    const headers = await response.headersArray()
    const locationValue = headers.find(header => header.name.toLowerCase() === 'location')?.value
    const location = locationValue ? new URL(locationValue) : undefined
    const cookies = headers.filter(header => header.name.toLowerCase() === 'set-cookie').map(({ value: cookie }) => {
        const parts = cookie.split(';').map(part => part.trim())
        const attributes = parts.slice(1)
        cookieFacts.push({
          host: url.hostname,
          path: attributes.find(value => value.toLowerCase().startsWith('path='))?.slice(5) ?? '',
          maxAge: attributes.find(value => value.toLowerCase().startsWith('max-age='))?.slice(8),
          name: parts[0].split('=')[0],
          secure: attributes.some(value => value.toLowerCase() === 'secure'),
          httpOnly: attributes.some(value => value.toLowerCase() === 'httponly'),
          sameSiteLax: attributes.some(value => value.toLowerCase() === 'samesite=lax'),
          hasDomain: attributes.some(value => value.toLowerCase().startsWith('domain=')),
        })
        return `cookie=${parts[0].split('=')[0]} attrs=${parts.slice(1).map(part => part.split('=')[0].toLowerCase()).join(',')}`
      })
    console.log(`BROWSER_RESPONSE status=${response.status()} host=${url.host} path=${url.pathname} location=${location ? location.origin + location.pathname : '-'} ${cookies.join(' ')}`)
  })
  page.on('requestfailed', request => {
    const url = new URL(request.url())
    const error = request.failure()?.errorText ?? ''
    const category = error.includes('ERR_CERT') ? 'tls' : error.includes('TIMED_OUT') ? 'timeout' : 'request-failed'
    console.log(`BROWSER_FAILURE host=${url.host} path=${url.pathname} category=${category}`)
  })
  await page.goto('/')
  await page.evaluate(() => console.log('M19_BROWSER_RUNTIME_CAPTURE'))
  await expect.poll(() => browserConsoleMarkerObserved).toBe(true)
  const callbackProbe = await page.evaluate(async () => {
    const url = new URL('/login/oauth2/code/geordi', location.origin)
    url.searchParams.set('code', 'private-code-sentinel')
    url.searchParams.set('state', 'private-state-sentinel')
    const response = await fetch(url, { redirect: 'manual' })
    return { status: response.status, location: response.headers.get('location') }
  })
  expect(callbackProbe.status).toBe(401)
  expect(callbackProbe.location).toBeNull()
  const pageErrors: string[] = []
  page.on('pageerror', error => {
    pageErrors.push(error.name)
    console.log(`BROWSER_PAGE_ERROR name=${error.name} message=${error.message}`)
  })

  const anonymous = await page.evaluate(async () => {
    const base = location.origin
    const statuses = await Promise.all([
      fetch(`${base}/actuator/health/liveness`).then(response => response.status),
      fetch(`${base}/actuator/health/readiness`).then(response => response.status),
      fetch(`${base}/api/platform`).then(response => response.status),
    ])
    return statuses
  })
  expect(anonymous).toEqual([200, 200, 401])

  await expect(page.getByRole('heading', { name: 'Sign in to Geordi' })).toBeVisible()
  await page.getByRole('link', { name: 'Sign in' }).click()
  await expect.poll(() => safeBrowserLocation(page.url())).toEqual({
    origin: 'https://geordi.localhost:8443', pathname: '/', hasSearch: false, hasHash: false,
  })
  await expect(page.getByText('Platform overview', { exact: true })).toBeVisible({ timeout: 20_000 })

  const identity = await page.evaluate(async () => {
    const response = await fetch(`${location.origin}/api/me`)
    return { status: response.status, body: await response.json() as BrowserIdentity }
  })
  expect(identity.status).toBe(200)
  const me = identity.body
  expect(me.issuer).toBe('https://auth.localhost')
  expect(me.subject).toBe('m19-operator')
  expect(me.permissions).toContain('alerts:acknowledge')
  expect(me.authMode).toBe('SESSION')
  const mixedCredentials = await page.evaluate(async () => {
    const response = await fetch(`${location.origin}/api/me`, {
      headers: { Authorization: 'Bearer invalid-m19-ambiguity-probe' },
    })
    return response.status
  })
  expect(mixedCredentials).toBe(400)
  const forwardedSpoof = await page.evaluate(async () => {
    const response = await fetch(`${location.origin}/api/me`, {
      headers: {
        Forwarded: 'host=attacker.invalid;proto=http',
        'X-Forwarded-Host': 'attacker.invalid',
        'X-Forwarded-Proto': 'http',
        'X-Forwarded-Port': '80',
      },
    })
    return { status: response.status, body: await response.json() as BrowserIdentity }
  })
  expect(forwardedSpoof.status).toBe(200)
  expect(forwardedSpoof.body.issuer).toBe('https://auth.localhost')
  expect(forwardedSpoof.body.subject).toBe('m19-operator')
  expect(forwardedSpoof.body.authMode).toBe('SESSION')
  expect(requestCookieNames).toContain('__Host-Geordi-OIDC')
  const sessionCookie = (await page.context().cookies()).find(cookie => cookie.name === '__Host-GEORDISESSION')
  if (sessionCookie) recordPrivateSentinel(sessionCookie.value)
  expect(sessionCookie).toMatchObject({ domain: 'geordi.localhost', path: '/', secure: true, httpOnly: true, sameSite: 'Lax' })
  expect((await page.context().cookies()).some(cookie => cookie.name === '__Host-Geordi-OIDC')).toBe(false)
  const sessionSetCookie = cookieFacts.find(cookie => cookie.name === '__Host-GEORDISESSION')
  const bindingDeletion = cookieFacts.find(cookie => cookie.name === '__Host-Geordi-OIDC' && cookie.path === '/' && cookie.maxAge === '0')
  expect(sessionSetCookie).toMatchObject({ host: 'geordi.localhost', path: '/', secure: true, httpOnly: true, sameSiteLax: true, hasDomain: false })
  expect(bindingDeletion).toMatchObject({ host: 'geordi.localhost', path: '/', secure: true, httpOnly: true, sameSiteLax: true, hasDomain: false })
  expect(safeBrowserLocation(page.url())).toEqual({
    origin: 'https://geordi.localhost:8443', pathname: '/', hasSearch: false, hasHash: false,
  })

  const csrf = await page.evaluate(async () => {
    const response = await fetch(`${location.origin}/api/auth/csrf`)
    return { status: response.status, body: await response.json() as BrowserCsrf }
  })
  expect(csrf.status).toBe(200)
  const csrfValue = csrf.body
  recordPrivateSentinel(csrfValue.token)
  expect(csrfValue.headerName).toBe('X-CSRF-TOKEN')

  const noCsrf = await page.evaluate(async () => {
    const response = await fetch(`${location.origin}/api/auth/logout`, { method: 'POST' })
    return response.status
  })
  expect(noCsrf).toBe(403)
  expect(pageErrors).toEqual([])

  const browserStorage = await page.evaluate(() => ({
    localStorage: Object.keys(localStorage),
    sessionStorage: Object.keys(sessionStorage),
  }))
  for (const key of [...browserStorage.localStorage, ...browserStorage.sessionStorage]) {
    expect(key).not.toMatch(/token|oauth|code|csrf|session|state/i)
  }

  await page.getByRole('button', { name: 'Sign out' }).click()
  await expect(page.getByRole('heading', { name: 'Signed out' })).toBeVisible()
  expect(await page.evaluate(async () => (await fetch(`${location.origin}/api/auth/logout`, { method: 'POST' })).status)).toBe(401)
  expect(await page.evaluate(async () => (await fetch(`${location.origin}/api/platform`)).status)).toBe(401)
})
