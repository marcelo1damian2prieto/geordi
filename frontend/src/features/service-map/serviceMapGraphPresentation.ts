import type { ObservedDependency } from '../../api/serviceMap'
import { serviceKey, type ServiceIdentity } from '../../api/telemetryContext'
import { serviceMapNodeLabel } from './serviceMapContext'

interface TooltipItem {
  dataType?: string
  data?: { label?: string; evidenceCount?: number }
}

export function serviceMapGraphOption(
  nodes: readonly ServiceIdentity[],
  edges: readonly ObservedDependency[],
  nodeCount: number,
  edgeCount: number,
) {
  return {
    aria: {
      enabled: true,
      description: `Observed dependency graph with ${nodeCount} services and ${edgeCount} directed dependencies.`,
    },
    tooltip: {
      trigger: 'item' as const,
      renderMode: 'richText' as const,
      formatter: (item: TooltipItem) => item.dataType === 'edge'
        ? `${item.data?.label ?? 'Observed dependency'}\n${item.data?.evidenceCount ?? 0} distinct trace(s)`
        : item.data?.label ?? '',
    },
    series: [{
      type: 'graph' as const,
      layout: 'force' as const,
      roam: true,
      draggable: false,
      animation: false,
      force: { repulsion: 360, edgeLength: [130, 210], gravity: 0.08 },
      label: { show: true, color: '#e7edf7', position: 'right' as const },
      edgeLabel: { show: true, color: '#91a0b5', formatter: ({ data }: { data: { evidenceCount: number } }) => `${data.evidenceCount} trace${data.evidenceCount === 1 ? '' : 's'}` },
      edgeSymbol: ['none', 'arrow'],
      edgeSymbolSize: 9,
      lineStyle: { color: '#76a9e8', width: 2, curveness: 0.08, opacity: 0.8 },
      data: nodes.map((node) => ({
        id: serviceKey(node),
        name: serviceMapNodeLabel(node),
        label: serviceMapNodeLabel(node),
        symbolSize: 42,
        itemStyle: { color: '#1f5b91', borderColor: '#76a9e8', borderWidth: 2 },
      })),
      links: edges.map((edge) => ({
        source: serviceKey(edge.caller),
        target: serviceKey(edge.callee),
        evidenceCount: edge.evidenceCount,
        label: `${serviceMapNodeLabel(edge.caller)} → ${serviceMapNodeLabel(edge.callee)}`,
      })),
    }],
  }
}
