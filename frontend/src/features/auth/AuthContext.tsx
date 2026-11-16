import { useContext } from 'react'
import type { GeordiPermission } from '../../api/auth'
import { authContext } from './authContextInternals'

export function useGeordiPermissions(): ReadonlySet<GeordiPermission> {
  return useContext(authContext)
}
