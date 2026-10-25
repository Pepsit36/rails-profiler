// Profiler AJAX Request Interceptor
// This script intercepts fetch() and XMLHttpRequest calls to link AJAX requests to their parent page

(function() {
  'use strict';

  // Get parent token from window variable set by the profiler
  if (!window.__PROFILER_PARENT_TOKEN__) {
    console.warn('[Profiler] Parent token not found, AJAX tracking disabled');
    return;
  }

  // Check if already intercepted (by Chrome extension or another script)
  if (window.__PROFILER_INTERCEPTOR_ACTIVE__) {
    console.debug('[Profiler] Interceptor already active, skipping');
    return;
  }
  window.__PROFILER_INTERCEPTOR_ACTIVE__ = true;

  // Save references to originals (they might already be wrapped by extension)
  const originalFetch = window.fetch;
  const originalXHROpen = XMLHttpRequest.prototype.open;
  const originalXHRSend = XMLHttpRequest.prototype.send;
  const pendingXHRRequests = new WeakMap();
  // The fetches Turbo makes, by the AbortSignal it hands to fetch(): { frame: true } when the
  // request loads a <turbo-frame>.
  const turboRequests = new WeakMap();
  const TURBO_STREAM_MIME = 'text/vnd.turbo-stream.html';

  // The page the sub-requests belong to. Read at each link, not once: a Turbo Drive visit
  // renders a new page, whose inline script sets the token again, without reloading this one.
  function currentParentToken() {
    return window.__PROFILER_PARENT_TOKEN__;
  }

  // A Turbo Drive visit to a page the profiler left alone brings no inline script to set a new
  // token, and the window keeps the one of the previous page: forget it, or every request of
  // this page would be linked to a page the user has left.
  document.addEventListener('turbo:load', function() {
    if (!document.getElementById('profiler-toolbar')) {
      delete window.__PROFILER_PARENT_TOKEN__;
    }
  });

  function isRequest(input) {
    return typeof Request !== 'undefined' && input instanceof Request;
  }

  function hasHeader(headers, name) {
    if (!headers) return false;
    if (typeof headers.has === 'function') return headers.has(name);
    const wanted = name.toLowerCase();
    return Object.keys(headers).some(key => key.toLowerCase() === wanted && headers[key] != null && headers[key] !== '');
  }

  // Turbo (7 and 8) announces each of its requests before calling fetch(), with the options it
  // will pass to it, signal included.
  document.addEventListener('turbo:before-fetch-request', function(event) {
    const options = event.detail && event.detail.fetchOptions;
    if (!options || !options.signal) return;
    turboRequests.set(options.signal, { frame: hasHeader(options.headers, 'Turbo-Frame') });
  });

  // A Turbo Drive visit, a prefetch on hover, or a form submission answered with a page is the
  // next page, which carries its own toolbar: not a sub-request of this one. A <turbo-frame>
  // load, and any request answered with Turbo Stream actions, update this page: they are.
  function isNavigation(args, response) {
    const init = args[1];
    const signal = (init && init.signal) || (isRequest(args[0]) ? args[0].signal : null);
    const turbo = signal && turboRequests.get(signal);
    if (!turbo || turbo.frame) return false;

    const contentType = response.headers.get('Content-Type') || '';
    return !contentType.startsWith(TURBO_STREAM_MIME);
  }

  // Helper function to check if path should be skipped
  function shouldSkipPath(url) {
    try {
      const urlObj = new URL(url, window.location.origin);
      const path = urlObj.pathname;

      // Skip profiler's own requests
      if (path.startsWith('/_profiler')) {
        return true;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  // Helper function to link child profile to parent, with retry on 404
  function linkChildProfile(childToken, attempt = 1) {
    const parentToken = currentParentToken();
    if (!childToken || !parentToken) return;

    const maxAttempts = 3;
    const linkUrl = '/_profiler/api/ajax/link';
    const body = JSON.stringify({
      parent_token: parentToken,
      child_token: childToken
    });

    console.debug('[Profiler] Linking AJAX request:', { parent: parentToken, child: childToken, attempt });

    // Use original fetch to avoid infinite loop
    originalFetch.call(window, linkUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Profiler-Request': '1'
      },
      body: body
    }).then(response => {
      if (response.ok) {
        // Refresh toolbar after successful link (with small delay to let backend process)
        setTimeout(() => {
          if (typeof window.__PROFILER_REFRESH_TOOLBAR__ === 'function') {
            window.__PROFILER_REFRESH_TOOLBAR__();
          }
        }, 100);
      } else if (response.status === 404 && attempt < maxAttempts) {
        // Profile not yet persisted (streaming response case): retry with exponential backoff
        const backoffMs = 100 * Math.pow(2, attempt - 1); // 100ms, 200ms, 400ms
        console.debug('[Profiler] Profile not found (404), retrying in', backoffMs, 'ms');
        setTimeout(() => {
          linkChildProfile(childToken, attempt + 1);
        }, backoffMs);
      } else if (response.status === 404) {
        // Exhausted retries
        console.debug('[Profiler] Profile not found after', maxAttempts, 'retries, giving up');
      }
    }).catch(err => {
      // Fail silently - don't break the page if profiler API fails
      console.debug('[Profiler] Failed to link AJAX request:', err);
    });
  }

  // Listen for events from Chrome extension (if installed)
  window.addEventListener('__profilerRequest', function(event) {
    const { token } = event.detail;
    if (token) {
      console.debug('[Profiler] Received profiler event from extension:', token);
      linkChildProfile(token);
    }
  });

  // Override fetch()
  window.fetch = async function(...args) {
    const url = isRequest(args[0]) ? args[0].url : String(args[0]);

    // Skip profiler paths
    if (shouldSkipPath(url)) {
      return originalFetch.apply(this, args);
    }

    try {
      const response = await originalFetch.apply(this, args);

      // Extract profiler token from response headers
      const profilerToken = response.headers.get('X-Profiler-Token');

      if (profilerToken && !isNavigation(args, response)) {
        linkChildProfile(profilerToken);
      }

      return response;
    } catch (error) {
      throw error;
    }
  };

  // Override XMLHttpRequest.open()
  XMLHttpRequest.prototype.open = function(method, url, ...args) {
    const urlString = typeof url === 'string' ? url : url.toString();

    // Store request metadata
    pendingXHRRequests.set(this, {
      url: urlString,
      method: method,
      timestamp: Date.now()
    });

    return originalXHROpen.apply(this, [method, url, ...args]);
  };

  // Override XMLHttpRequest.send()
  XMLHttpRequest.prototype.send = function(...args) {
    const requestData = pendingXHRRequests.get(this);

    // Skip profiler paths
    if (requestData && shouldSkipPath(requestData.url)) {
      return originalXHRSend.apply(this, args);
    }

    // Add load event listener to capture response
    this.addEventListener('load', function() {
      const profilerToken = this.getResponseHeader('X-Profiler-Token');

      if (profilerToken && requestData) {
        linkChildProfile(profilerToken);
      }
    });

    return originalXHRSend.apply(this, args);
  };

  console.debug('[Profiler] AJAX interceptor initialized with parent token:', currentParentToken());
})();
