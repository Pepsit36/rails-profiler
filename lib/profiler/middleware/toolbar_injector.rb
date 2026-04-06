# frozen_string_literal: true

module Profiler
  module Middleware
    class ToolbarInjector
      CLOSING_BODY_TAG = "</body>"

      def initialize(body, token, nonce = nil)
        @body = body
        @token = token
        @nonce = nonce
      end

      def inject
        content = extract_content(@body)
        return @body unless content.include?(CLOSING_BODY_TAG)

        injected_content = content.sub(CLOSING_BODY_TAG, toolbar_html + CLOSING_BODY_TAG)

        # Return as array for Rack compatibility
        [injected_content]
      end

      private

      def ajax_interceptor_script
        return "" unless Profiler.configuration.track_ajax

        <<~HTML
          <script#{nonce_attr}>
            window.__PROFILER_PARENT_TOKEN__ = '#{@token}';
          </script>
          <script#{nonce_attr}>
            #{ajax_interceptor_code}
          </script>
        HTML
      end

      def ajax_interceptor_code
        @ajax_interceptor_code ||= begin
          path = File.join(__dir__, "..", "..", "..", "app", "assets", "javascript", "profiler-ajax-interceptor.js")
          File.read(path)
        rescue => e
          warn "Failed to load AJAX interceptor script: #{e.message}"
          ""
        end
      end

      def extract_content(body)
        if body.respond_to?(:body)
          body.body
        elsif body.respond_to?(:each)
          parts = []
          body.each { |part| parts << part }
          body.close if body.respond_to?(:close)
          parts.join
        else
          body.to_s
        end
      end

      def toolbar_html
        <<~HTML
          #{ajax_interceptor_script}
          <div id="profiler-toolbar" data-token="#{@token}"></div>
          <script src="/_profiler/assets/profiler-toolbar.js" defer#{nonce_attr}></script>
          <style>#{toolbar_styles}</style>
        HTML
      end

      def nonce_attr
        @nonce ? " nonce=\"#{@nonce}\"" : ""
      end

      # Thermal design system — self-contained CSS for the injected toolbar.
      # Variables are defined on #profiler-toolbar to avoid polluting the host app.
      def toolbar_styles
        <<~'CSS'
          #profiler-toolbar {
            --pf-bg:         #080b10;
            --pf-surface:    #0d1117;
            --pf-raised:     #131920;
            --pf-text:       #eef2f7;
            --pf-muted:      #5e7080;
            --pf-amber:      #f59e0b;
            --pf-amber-h:    #fbbf24;
            --pf-amber-bg:   rgba(245,158,11,.1);
            --pf-amber-glow: rgba(245,158,11,.25);
            --pf-success:    #22c55e;
            --pf-warning:    #fb923c;
            --pf-error:      #f87171;
            --pf-info:       #60a5fa;
            --pf-border:     rgba(255,255,255,.07);
            --pf-border-s:   rgba(255,255,255,.13);
            --pf-mono:       'JetBrains Mono','SF Mono','Fira Code',monospace;
            --pf-tf:         120ms cubic-bezier(.4,0,.2,1);
            --pf-tb:         220ms cubic-bezier(.4,0,.2,1);

            position: fixed;
            bottom: 0; left: 0; right: 0;
            height: 44px;
            background: var(--pf-bg);
            border-top: 1px solid var(--pf-border-s);
            z-index: 999999;
            font-family: var(--pf-mono);
            font-size: 11px;
            color: var(--pf-muted);
            animation: pfIn 300ms cubic-bezier(.4,0,.2,1) both;
          }
          /* ── Light theme overrides ───────────────────────────────────────── */
          #profiler-toolbar[data-theme="light"] {
            --pf-bg:         #f5f3ef;
            --pf-surface:    #edeae3;
            --pf-raised:     #e3ded5;
            --pf-text:       #1c1410;
            --pf-muted:      #8a7a6e;
            --pf-amber:      #b45309;
            --pf-amber-h:    #92400e;
            --pf-amber-bg:   rgba(180,83,9,.08);
            --pf-amber-glow: rgba(180,83,9,.2);
            --pf-success:    #15803d;
            --pf-warning:    #c2410c;
            --pf-error:      #dc2626;
            --pf-info:       #1d4ed8;
            --pf-border:     rgba(28,20,16,.1);
            --pf-border-s:   rgba(28,20,16,.2);
          }

          @keyframes pfIn {
            from { transform: translateY(100%); opacity: 0; }
            to   { transform: translateY(0); opacity: 1; }
          }
          #profiler-toolbar::before {
            content: '';
            position: absolute;
            top: -1px; left: 0; right: 0;
            height: 1px;
            background: linear-gradient(90deg,transparent 0%,#f59e0b 20%,#fbbf24 50%,#f59e0b 80%,transparent 100%);
            opacity: .6;
          }
          #profiler-toolbar .profiler-toolbar-container {
            display: flex;
            align-items: stretch;
            height: 100%;
          }
          #profiler-toolbar .profiler-toolbar-item {
            position: relative;
            display: inline-flex;
            align-items: center;
            gap: 5px;
            padding: 0 14px;
            color: var(--pf-muted);
            text-decoration: none;
            white-space: nowrap;
            font-weight: 500;
            background: transparent;
            border: none;
            border-right: 1px solid var(--pf-border);
            font-family: var(--pf-mono);
            font-size: 11px;
            transition: color var(--pf-tf), background var(--pf-tf);
          }
          #profiler-toolbar .profiler-toolbar-item::after {
            content: '';
            position: absolute;
            bottom: 0; left: 0; right: 0;
            height: 2px;
            background: var(--pf-amber);
            transform: scaleX(0);
            transform-origin: left;
            transition: transform var(--pf-tb);
          }
          #profiler-toolbar a.profiler-toolbar-item { cursor: pointer; }
          #profiler-toolbar a.profiler-toolbar-item:hover {
            color: var(--pf-text);
            background: var(--pf-amber-bg);
          }
          #profiler-toolbar a.profiler-toolbar-item:hover::after { transform: scaleX(1); }
          #profiler-toolbar .profiler-text--success { color: var(--pf-success) !important; }
          #profiler-toolbar .profiler-text--warning { color: var(--pf-warning) !important; }
          #profiler-toolbar .profiler-text--error   { color: var(--pf-error)   !important; }
          #profiler-toolbar .profiler-text--accent  { color: var(--pf-amber)   !important; }
          #profiler-toolbar .profiler-text--muted   { color: var(--pf-muted)   !important; }
          #profiler-toolbar a.profiler-toolbar-item.profiler-text--error::after   { background: var(--pf-error); }
          #profiler-toolbar a.profiler-toolbar-item.profiler-text--warning::after { background: var(--pf-warning); }
          #profiler-toolbar .profiler-toolbar-item:last-child {
            border-right: none;
            margin-left: auto;
            color: var(--pf-amber);
            padding-left: 20px;
            font-weight: 600;
          }
          #profiler-toolbar a.profiler-toolbar-item:last-child:hover { color: var(--pf-amber-h); }
          #profiler-toolbar .profiler-toolbar-hoverable { position: relative; }
          #profiler-toolbar .profiler-toolbar-panel {
            display: none;
            position: absolute;
            bottom: calc(100% + 10px);
            left: 50%;
            transform: translateX(-50%);
            min-width: 300px;
            max-width: 420px;
            background: var(--pf-surface);
            border: 1px solid var(--pf-border-s);
            border-radius: 8px;
            box-shadow: 0 8px 32px rgba(0,0,0,.65), 0 0 0 1px var(--pf-amber-glow);
            z-index: 1000000;
            overflow: hidden;
          }
          #profiler-toolbar .profiler-toolbar-panel::before {
            content: '';
            position: absolute;
            top: 0; left: 0; right: 0;
            height: 2px;
            background: linear-gradient(90deg,#f59e0b,#fbbf24);
          }
          #profiler-toolbar .profiler-toolbar-panel::after {
            content: '';
            position: absolute;
            top: 100%; left: 50%;
            transform: translateX(-50%);
            border: 6px solid transparent;
            border-top-color: var(--pf-border-s);
          }
          #profiler-toolbar .profiler-toolbar-panel-large { min-width: 420px; max-width: 560px; }
          #profiler-toolbar .profiler-toolbar-panel-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 10px 14px 8px;
            font-size: 10px;
            font-weight: 700;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: var(--pf-amber);
            background: var(--pf-amber-bg);
            border-bottom: 1px solid var(--pf-border);
            font-family: var(--pf-mono);
          }
          #profiler-toolbar .profiler-float-right {
            color: var(--pf-muted);
            font-weight: 400;
            text-transform: none;
            letter-spacing: 0;
            font-size: 10px;
          }
          #profiler-toolbar .profiler-toolbar-panel-content {
            padding: 8px 14px 12px;
            max-height: 380px;
            overflow-y: auto;
            font-size: 11px;
            font-family: var(--pf-mono);
            scrollbar-width: thin;
            scrollbar-color: var(--pf-border-s) transparent;
          }
          #profiler-toolbar .profiler-toolbar-panel-content::-webkit-scrollbar { width: 4px; }
          #profiler-toolbar .profiler-toolbar-panel-content::-webkit-scrollbar-thumb {
            background: var(--pf-border-s);
            border-radius: 99px;
          }
          #profiler-toolbar .profiler-toolbar-panel-row {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            padding: 5px 0;
            border-bottom: 1px solid var(--pf-border);
            gap: 12px;
          }
          #profiler-toolbar .profiler-toolbar-panel-row:last-child { border-bottom: none; }
          #profiler-toolbar .profiler-toolbar-panel-row span { color: var(--pf-muted); font-size: 10px; flex-shrink: 0; }
          #profiler-toolbar .profiler-toolbar-panel-row strong {
            color: var(--pf-text);
            font-weight: 600;
            text-align: right;
            font-variant-numeric: tabular-nums;
            word-break: break-all;
          }
          #profiler-toolbar .profiler-section__header {
            font-size: 9px;
            font-weight: 700;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: var(--pf-amber);
            padding: 10px 0 4px;
            border-bottom: 1px solid rgba(245,158,11,.2);
            margin-bottom: 6px;
            font-family: var(--pf-mono);
          }
          #profiler-toolbar .profiler-section__header:first-child { padding-top: 4px; }
          #profiler-toolbar .profiler-toolbar-panel-query {
            padding: 7px 10px;
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 4px;
            margin-bottom: 5px;
          }
          #profiler-toolbar .profiler-toolbar-panel-query:last-child { margin-bottom: 0; }
          #profiler-toolbar .profiler-toolbar-panel-query-slow {
            border-left: 2px solid var(--pf-error);
            background: rgba(248,113,113,.06);
          }
          #profiler-toolbar .profiler-toolbar-panel-query code {
            display: block;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            color: var(--pf-info);
            font-size: 10px;
            line-height: 1.5;
            margin-top: 4px;
            font-family: var(--pf-mono);
            background: none;
            padding: 0;
            border: none;
          }
          #profiler-toolbar .profiler-more {
            text-align: center;
            padding: 7px;
            color: var(--pf-muted);
            font-size: 10px;
            letter-spacing: .05em;
            border-top: 1px dashed var(--pf-border);
            margin-top: 6px;
          }
          #profiler-toolbar .profiler-ajax-card {
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 4px;
            padding: 6px 8px;
            margin-bottom: 4px;
          }
          #profiler-toolbar .profiler-ajax-card--success { border-left: 2px solid var(--pf-success); }
          #profiler-toolbar .profiler-ajax-card--error   { border-left: 2px solid var(--pf-error); }
          #profiler-toolbar .profiler-ajax-card__row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 8px;
          }
          #profiler-toolbar .profiler-dump-card {
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 4px;
            padding: 6px 8px;
            margin-bottom: 4px;
          }
          #profiler-toolbar .profiler-dump-card__header {
            display: flex;
            justify-content: space-between;
            margin-bottom: 4px;
          }
          #profiler-toolbar .badge {
            display: inline-flex;
            align-items: center;
            padding: 1px 5px;
            border-radius: 3px;
            font-size: 9px;
            font-weight: 700;
            letter-spacing: .05em;
            font-family: var(--pf-mono);
            background: var(--pf-raised);
            color: var(--pf-muted);
          }
          #profiler-toolbar .badge-info    { background: rgba(96,165,250,.12);  color: var(--pf-info); }
          #profiler-toolbar .badge-success { background: rgba(34,197,94,.12);   color: var(--pf-success); }
          #profiler-toolbar .badge-warning { background: rgba(251,146,60,.12);  color: var(--pf-warning); }
          #profiler-toolbar .badge-error   { background: rgba(248,113,113,.12); color: var(--pf-error); }
          #profiler-toolbar .profiler-flex           { display: flex; }
          #profiler-toolbar .profiler-flex--between  { justify-content: space-between; }
          #profiler-toolbar .profiler-flex--gap-2    { gap: 8px; }
          #profiler-toolbar .profiler-mb-1           { margin-bottom: 4px; }
          #profiler-toolbar .profiler-mb-2           { margin-bottom: 8px; }
          #profiler-toolbar .profiler-mt-3           { margin-top: 12px; }
          #profiler-toolbar .profiler-text--xs       { font-size: 10px !important; }
          #profiler-toolbar .profiler-text--sm       { font-size: 11px !important; }
          #profiler-toolbar .profiler-text--mono     { font-family: var(--pf-mono) !important; }
          #profiler-toolbar .profiler-text--uppercase { text-transform: uppercase; letter-spacing: .08em; }
          #profiler-toolbar .profiler-text--truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        CSS
      end
    end
  end
end
