# frozen_string_literal: true

require "json"
require "active_support/core_ext/string/output_safety"

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
        # The last </body>: an earlier one can sit in a script string of the page.
        position = content.rindex(CLOSING_BODY_TAG)
        return @body unless position

        injected_content = content.dup.insert(position, toolbar_html)

        # Return as array for Rack compatibility
        [injected_content]
      end

      private

      def ajax_interceptor_script
        return "" unless Profiler.configuration.track_ajax

        <<~HTML
          <script#{nonce_attr}>
            window.__PROFILER_PARENT_TOKEN__ = #{js_token};
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
          <style>#{toolbar_styles}</style>
          <div id="profiler-toolbar" class="profiler-root" data-token="#{ERB::Util.html_escape(@token)}"></div>
          <button id="profiler-toolbar-toggle" class="profiler-root" title="Toggle profiler (Alt+P)"><span class="profiler-toggle-icon">&#9654;</span></button>
          <script#{nonce_attr}>(function(){var c=localStorage.getItem('profiler-toolbar-collapsed')==='true',t=localStorage.getItem('profiler-theme'),theme=t==='light'?'light':t==='dark'?'dark':(window.matchMedia('(prefers-color-scheme:light)').matches?'light':'dark'),el=document.getElementById('profiler-toolbar'),tog=document.getElementById('profiler-toolbar-toggle');if(c){el.style.cssText='animation:none!important;transform:translateX(calc(100% + 44px))';tog.dataset.collapsed='true';}el.setAttribute('data-theme',theme);tog.setAttribute('data-theme',theme);})();</script>
          <script src="/_profiler/assets/profiler-toolbar.js" defer#{nonce_attr}></script>
        HTML
      end

      # The token as a JavaScript string literal that cannot close the <script> element.
      def js_token
        ERB::Util.json_escape(@token.to_s.to_json)
      end

      def nonce_attr
        @nonce ? " nonce=\"#{ERB::Util.html_escape(@nonce)}\"" : ""
      end

      # Thermal design system — self-contained CSS for the injected toolbar.
      # Variables are defined on #profiler-toolbar to avoid polluting the host app.
      def toolbar_styles
        <<~'CSS'
          .profiler-root {
            --pf-bg:         #080b10;
            --pf-surface:    #0d1117;
            --pf-raised:     #131920;
            --pf-text:       #eef2f7;
            --pf-muted:      #4d6170;
            --pf-amber:      #f59e0b;
            --pf-amber-h:    #fbbf24;
            --pf-amber-bg:   rgba(245,158,11,.08);
            --pf-amber-glow: rgba(245,158,11,.2);
            --pf-success:    #22c55e;
            --pf-warning:    #fb923c;
            --pf-error:      #f87171;
            --pf-info:       #60a5fa;
            --pf-border:     rgba(255,255,255,.06);
            --pf-border-s:   rgba(255,255,255,.11);
            --pf-mono:       'JetBrains Mono','SF Mono','Fira Code',monospace;
            --pf-tf:         140ms cubic-bezier(.4,0,.2,1);
            --pf-tb:         240ms cubic-bezier(.4,0,.2,1);
          }
          /* ── Light theme ─────────────────────────────────────────────────── */
          .profiler-root[data-theme="light"] {
            --pf-bg:         #f5f3ef;
            --pf-surface:    #edeae3;
            --pf-raised:     #e3ded5;
            --pf-text:       #1c1410;
            --pf-muted:      #8a7a6e;
            --pf-amber:      #b45309;
            --pf-amber-h:    #92400e;
            --pf-amber-bg:   rgba(180,83,9,.07);
            --pf-amber-glow: rgba(180,83,9,.18);
            --pf-success:    #15803d;
            --pf-warning:    #c2410c;
            --pf-error:      #dc2626;
            --pf-info:       #1d4ed8;
            --pf-border:     rgba(28,20,16,.08);
            --pf-border-s:   rgba(28,20,16,.18);
          }
          #profiler-toolbar {
            position: fixed;
            bottom: 0; left: 0; right: 44px;
            height: 44px;
            background: linear-gradient(180deg, var(--pf-surface) 0%, var(--pf-bg) 100%);
            border-top: 1px solid var(--pf-border-s);
            z-index: 999999;
            font-family: var(--pf-mono);
            font-size: 11px;
            color: var(--pf-muted);
            animation: pfIn 320ms cubic-bezier(.4,0,.2,1) both;
          }
          /* ── Slide-in animation ──────────────────────────────────────────── */
          @keyframes pfIn {
            from { transform: translateY(100%); opacity: 0; }
            to   { transform: translateY(0);    opacity: 1; }
          }
          @keyframes pfPop {
            0%   { transform: scaleX(1);    }
            15%  { transform: scaleX(1.18); }
            40%  { transform: scaleX(0.87); }
            65%  { transform: scaleX(1.08); }
            85%  { transform: scaleX(0.97); }
            100% { transform: scaleX(1);    }
          }
          /* ── Amber accent line ───────────────────────────────────────────── */
          #profiler-toolbar::before {
            content: '';
            position: absolute;
            top: -1px; left: 0; right: 0;
            height: 1px;
            background: linear-gradient(90deg, transparent 0%, #f59e0b 25%, #fbbf24 50%, #f59e0b 75%, transparent 100%);
            opacity: .55;
            transition: opacity 280ms;
          }
          /* ── Container ───────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-container {
            display: flex;
            align-items: stretch;
            height: 100%;
          }
          /* ── Items ───────────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-item {
            position: relative;
            display: inline-flex;
            align-items: center;
            gap: 5px;
            padding: 0 13px;
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
            cursor: default;
          }
          /* Amber bottom indicator — springy easing */
          #profiler-toolbar .profiler-toolbar-item::after {
            content: '';
            position: absolute;
            bottom: 0; left: 0; right: 0;
            height: 2px;
            background: var(--pf-amber);
            transform: scaleX(0);
            transform-origin: left;
            transition: transform 280ms cubic-bezier(.34,1.4,.64,1);
          }
          /* Hover: all interactive items */
          #profiler-toolbar a.profiler-toolbar-item,
          #profiler-toolbar .profiler-toolbar-hoverable { cursor: pointer; }

          #profiler-toolbar a.profiler-toolbar-item:hover,
          #profiler-toolbar .profiler-toolbar-hoverable:hover {
            color: var(--pf-text);
            background: var(--pf-amber-bg);
          }
          #profiler-toolbar a.profiler-toolbar-item:hover::after,
          #profiler-toolbar .profiler-toolbar-hoverable:hover::after { transform: scaleX(1); }

          /* Severity underline colors */
          #profiler-toolbar .profiler-text--error::after   { background: var(--pf-error); }
          #profiler-toolbar .profiler-text--warning::after { background: var(--pf-warning); }
          #profiler-toolbar .profiler-text--success::after { background: var(--pf-success); }

          /* Semantic colors */
          #profiler-toolbar .profiler-text--success { color: var(--pf-success) !important; }
          #profiler-toolbar .profiler-text--warning { color: var(--pf-warning) !important; }
          #profiler-toolbar .profiler-text--error   { color: var(--pf-error)   !important; }
          #profiler-toolbar .profiler-text--accent  { color: var(--pf-amber)   !important; }
          #profiler-toolbar .profiler-text--muted   { color: var(--pf-muted)   !important; }

          /* Logo link */
          #profiler-toolbar .profiler-toolbar-logo {
            border-right: 1px solid var(--pf-border) !important;
            color: var(--pf-amber);
            font-weight: 600;
            letter-spacing: .02em;
          }
          #profiler-toolbar .profiler-toolbar-logo:hover { color: var(--pf-amber-h); }

          /* ── Toggle button (fixed, always visible) ───────────────────────── */
          #profiler-toolbar-toggle {
            position: fixed;
            bottom: 0; right: 0;
            width: 44px; height: 44px;
            display: flex; align-items: center; justify-content: center;
            cursor: pointer;
            background: linear-gradient(180deg, var(--pf-surface) 0%, var(--pf-bg) 100%);
            border: none;
            border-top: 1px solid var(--pf-border-s);
            border-left: 1px solid var(--pf-border);
            color: var(--pf-muted);
            font-family: var(--pf-mono);
            font-size: 13px;
            z-index: 1000000;
            border-radius: 0;
            transition: color var(--pf-tf), background var(--pf-tf);
          }
          #profiler-toolbar-toggle:hover {
            color: var(--pf-amber);
            animation: pfPop 380ms ease-out both;
            transform: none;
          }
          .profiler-toggle-icon {
            display: inline-block;
            transition: transform 280ms cubic-bezier(.4,0,.2,1);
          }
          #profiler-toolbar-toggle[data-collapsed="true"] .profiler-toggle-icon {
            transform: scaleX(-1);
          }

          /* ── Hoverable wrapper ───────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-hoverable { position: relative; }

          /* ── Panel (CSS-driven visibility) ───────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-panel {
            position: absolute;
            bottom: calc(100% + 12px);
            left: 50%;
            transform: translateX(-50%);
            min-width: 300px;
            max-width: 420px;
            background: var(--pf-surface);
            border: 1px solid var(--pf-border-s);
            border-radius: 10px;
            box-shadow: 0 12px 40px rgba(0,0,0,.7), 0 0 0 1px var(--pf-amber-glow);
            z-index: 1000000;
            overflow: hidden;
            /* Hidden state */
            opacity: 0;
            visibility: hidden;
            pointer-events: none;
            transition:
              opacity    160ms cubic-bezier(.4,0,.2,1),
              visibility 0s   linear 160ms;
          }
          #profiler-toolbar .profiler-toolbar-panel.is-visible {
            opacity: 1;
            visibility: visible;
            pointer-events: auto;
            transition:
              opacity    160ms cubic-bezier(.4,0,.2,1),
              visibility 0s;
          }
          /* Amber top bar on panel */
          #profiler-toolbar .profiler-toolbar-panel::before {
            content: '';
            position: absolute;
            top: 0; left: 0; right: 0;
            height: 2px;
            background: linear-gradient(90deg, #f59e0b, #fbbf24);
          }
          /* Arrow */
          #profiler-toolbar .profiler-toolbar-panel::after {
            content: '';
            position: absolute;
            top: 100%; left: 50%;
            transform: translateX(-50%);
            border: 6px solid transparent;
            border-top-color: var(--pf-border-s);
          }
          #profiler-toolbar .profiler-toolbar-panel-large { min-width: 420px; max-width: 560px; }

          /* ── Panel header ────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-panel-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 10px 14px 9px;
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

          /* ── Panel content ───────────────────────────────────────────────── */
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

          /* ── Panel rows ──────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-panel-row {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            padding: 6px 0;
            border-bottom: 1px solid var(--pf-border);
            gap: 12px;
          }
          #profiler-toolbar .profiler-toolbar-panel-row:last-child { border-bottom: none; }
          #profiler-toolbar .profiler-toolbar-panel-row span {
            color: var(--pf-muted);
            font-size: 10px;
            flex-shrink: 0;
          }
          #profiler-toolbar .profiler-toolbar-panel-row strong {
            color: var(--pf-text);
            font-weight: 600;
            text-align: right;
            font-variant-numeric: tabular-nums;
            word-break: break-all;
          }

          /* ── Section header ──────────────────────────────────────────────── */
          #profiler-toolbar .profiler-section__header {
            font-size: 9px;
            font-weight: 700;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: var(--pf-amber);
            padding: 10px 0 4px;
            border-bottom: 1px solid rgba(245,158,11,.18);
            margin-bottom: 6px;
            font-family: var(--pf-mono);
          }
          #profiler-toolbar .profiler-section__header:first-child { padding-top: 4px; }

          /* ── Query cards ─────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-toolbar-panel-query {
            padding: 7px 10px;
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 5px;
            margin-bottom: 5px;
            transition: border-color var(--pf-tf);
          }
          #profiler-toolbar .profiler-toolbar-panel-query:last-child { margin-bottom: 0; }
          #profiler-toolbar .profiler-toolbar-panel-query:hover { border-color: var(--pf-border-s); }
          #profiler-toolbar .profiler-toolbar-panel-query-slow {
            border-left: 2px solid var(--pf-error);
            background: rgba(248,113,113,.05);
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

          /* ── More hint ───────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-more {
            text-align: center;
            padding: 7px;
            color: var(--pf-muted);
            font-size: 10px;
            letter-spacing: .05em;
            border-top: 1px dashed var(--pf-border);
            margin-top: 6px;
          }

          /* ── Ajax cards ──────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-ajax-card {
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 5px;
            padding: 6px 8px;
            margin-bottom: 4px;
            transition: border-color var(--pf-tf);
          }
          #profiler-toolbar .profiler-ajax-card:hover { border-color: var(--pf-border-s); }
          #profiler-toolbar .profiler-ajax-card--success { border-left: 2px solid var(--pf-success); }
          #profiler-toolbar .profiler-ajax-card--error   { border-left: 2px solid var(--pf-error); }
          #profiler-toolbar .profiler-ajax-card__row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 8px;
          }

          /* ── Dump cards ──────────────────────────────────────────────────── */
          #profiler-toolbar .profiler-dump-card {
            background: var(--pf-raised);
            border: 1px solid var(--pf-border);
            border-radius: 5px;
            padding: 6px 8px;
            margin-bottom: 4px;
          }
          #profiler-toolbar .profiler-dump-card__header {
            display: flex;
            justify-content: space-between;
            margin-bottom: 4px;
          }

          /* ── Badges ──────────────────────────────────────────────────────── */
          #profiler-toolbar .badge {
            display: inline-flex;
            align-items: center;
            padding: 1px 6px;
            border-radius: 4px;
            font-size: 9px;
            font-weight: 700;
            letter-spacing: .05em;
            font-family: var(--pf-mono);
            background: var(--pf-raised);
            color: var(--pf-muted);
          }
          #profiler-toolbar .badge-info    { background: rgba(96,165,250,.1);   color: var(--pf-info); }
          #profiler-toolbar .badge-success { background: rgba(34,197,94,.1);    color: var(--pf-success); }
          #profiler-toolbar .badge-warning { background: rgba(251,146,60,.1);   color: var(--pf-warning); }
          #profiler-toolbar .badge-error   { background: rgba(248,113,113,.1);  color: var(--pf-error); }

          /* ── Utilities ───────────────────────────────────────────────────── */
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
