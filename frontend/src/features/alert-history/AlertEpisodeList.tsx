import { Link } from 'react-router-dom'
import type { AlertEpisode } from '../../api/alertHistory'
import { alertHistorySearchParams, type AlertHistorySelection } from './alertHistorySearchParams'
import { episodeDuration, episodeStatus } from './alertHistoryPresentation'

export function AlertEpisodeList({ episodes, query, onSelect }: {
  episodes: AlertEpisode[]; query: AlertHistorySelection; onSelect: (id: string, link: HTMLAnchorElement) => void
}) {
  return <table>
    <caption>Alert episodes in API order</caption>
    <thead><tr>{['Episode', 'Policy', 'Status / origin', 'Opened (UTC)', 'Resolved (UTC)', 'Duration'].map((label) => <th scope="col" key={label}>{label}</th>)}</tr></thead>
    <tbody>{episodes.map((episode) => <tr key={episode.id}>
      <td><Link to={`/alert-history?${alertHistorySearchParams({ ...query, episodeId: episode.id })}`} aria-current={query.episodeId === episode.id ? 'true' : undefined}
        onClick={(event) => { if (event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) onSelect(episode.id, event.currentTarget) }}
      >Open episode {episode.id}</Link></td>
      <td>{episode.policyId}</td><td>{episodeStatus(episode)} <small>({episode.origin})</small></td>
      <td>{episode.openedAt === null ? 'Start unavailable' : <time dateTime={episode.openedAt}>{episode.openedAt}</time>}</td>
      <td>{episode.closedAt === null ? 'Not resolved' : <time dateTime={episode.closedAt}>{episode.closedAt}</time>}</td>
      <td>{episodeDuration(episode)}</td>
    </tr>)}</tbody>
  </table>
}
