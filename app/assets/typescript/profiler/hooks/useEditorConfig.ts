import { useGetEditorConfig, getGetEditorConfigQueryKey } from '../generated/api'
import type { EditorSettings } from '../source-links'

// The gem's editor_url_scheme and editor_path_map. Read once per page. While loading no scheme
// is known, so no link is built; if the endpoint cannot be read (an older gem), the gem's own
// default applies.
export function useEditorConfig(): EditorSettings {
  const { data, isError } = useGetEditorConfig({ query: { queryKey: getGetEditorConfigQueryKey(), staleTime: Infinity, retry: false } })
  if (data) return { scheme: data.editor_url_scheme, pathMap: data.editor_path_map }
  if (isError) return { scheme: 'vscode', pathMap: {} }
  return { scheme: null, pathMap: {} }
}
