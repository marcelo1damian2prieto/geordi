import type { ReactNode } from 'react'
import type { GeordiPermission } from '../../api/auth'
import { authContext } from './authContextInternals'

const AuthContext = authContext

export function AuthProvider({ permissions, children }: {
  permissions: ReadonlySet<GeordiPermission>
  children: ReactNode
}) {
  return <AuthContext.Provider value={permissions}>{children}</AuthContext.Provider>
}
