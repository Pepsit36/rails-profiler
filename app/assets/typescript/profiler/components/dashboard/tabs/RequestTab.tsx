import { Profile } from '../../../dashboard/types'

interface Props {
  profile: Profile
}

export function RequestTab({ profile }: Props) {
  return (
    <>
      <h2 class="profiler-section__header">Request Information</h2>
      <table>
        <tr>
          <th class="profiler-text--sm" style="width: 200px;">Path</th>
          <td>{profile.path}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Method</th>
          <td>{profile.method}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Status</th>
          <td>{profile.status}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Duration</th>
          <td>{profile.duration.toFixed(2)} ms</td>
        </tr>
        {profile.params && Object.keys(profile.params).length > 0 && (
          <tr>
            <th class="profiler-text--sm">Parameters</th>
            <td><pre>{JSON.stringify(profile.params, null, 2)}</pre></td>
          </tr>
        )}
        {profile.headers && Object.keys(profile.headers).length > 0 && (
          <tr>
            <th class="profiler-text--sm">Headers</th>
            <td><pre>{JSON.stringify(profile.headers, null, 2)}</pre></td>
          </tr>
        )}
      </table>
    </>
  )
}
