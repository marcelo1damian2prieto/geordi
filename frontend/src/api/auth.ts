import { getJson, postJson, clearCsrfToken } from './client'

export type GeordiPermission = 'observability:read' | 'alerts:acknowledge' | 'alerts:evaluate'
export interface CurrentIdentity {
  issuer: string
  subject: string
  displayName: string | null
  permissions: GeordiPermission[]
  authMode: 'SESSION' | 'BEARER'
}

export function getCurrentIdentity(signal?: AbortSignal) {
  return getJson<CurrentIdentity>('/api/me', signal)
}

export async function logout(signal?: AbortSignal): Promise<void> {
  await postJson<void>('/api/auth/logout', undefined, signal)
  clearCsrfToken()
}
