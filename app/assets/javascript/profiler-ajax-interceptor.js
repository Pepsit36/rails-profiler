// Profiler AJAX Request Interceptor
// This script intercepts fetch() and XMLHttpRequest calls to link AJAX requests to their parent page

(function() {
  'use strict';

  // Get parent token from window variable set by the profiler
  const parentToken = window.__PROFILER_PARENT_TOKEN__;
  if (!parentToken) {
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

  // Helper function to link child profile to parent
  function linkChildProfile(childToken) {
    if (!childToken || !parentToken) return;

    console.debug('[Profiler] Linking AJAX request:', { parent: parentToken, child: childToken });

    // Post to the link API endpoint
    const linkUrl = '/_profiler/api/ajax/link';
    const body = JSON.stringify({
      parent_token: parentToken,
      child_token: childToken
    });

    // Use original fetch to avoid infinite loop
    originalFetch.call(window, linkUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
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
    const url = typeof args[0] === 'string' ? args[0] : args[0].url;

    // Skip profiler paths
    if (shouldSkipPath(url)) {
      return originalFetch.apply(this, args);
    }

    try {
      const response = await originalFetch.apply(this, args);

      // Extract profiler token from response headers
      const profilerToken = response.headers.get('X-Profiler-Token');

      if (profilerToken) {
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

  console.debug('[Profiler] AJAX interceptor initialized with parent token:', parentToken);
})();
