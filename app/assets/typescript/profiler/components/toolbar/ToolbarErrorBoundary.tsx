import { Component, ComponentChildren } from 'preact'

interface Props {
  children: ComponentChildren
}

interface State {
  failed: boolean
}

// An exception thrown while a toolbar component renders would otherwise unmount the whole
// Preact tree and leave a blank bar. This shows a minimal message instead, and a button to try
// again, and never lets the error reach the host page.
export class ToolbarErrorBoundary extends Component<Props, State> {
  state: State = { failed: false }

  static getDerivedStateFromError(): State {
    return { failed: true }
  }

  componentDidCatch(error: unknown): void {
    console.error('[Profiler] The toolbar failed to render:', error)
  }

  render() {
    if (!this.state.failed) return this.props.children

    return (
      <div class="profiler-toolbar-container">
        <span class="profiler-toolbar-error" role="alert">
          <span class="profiler-text--error">Profiler toolbar error.</span>
          <button type="button" class="profiler-toolbar-retry" onClick={() => this.setState({ failed: false })}>
            Retry
          </button>
        </span>
      </div>
    )
  }
}
