// Toolbar interactions and functionality - Performance Dashboard Luxe

interface ToolbarItem {
  element: HTMLElement;
  panel?: HTMLElement;
}

export function initToolbar(toolbar: HTMLElement): void {
  console.log('🎨 Initializing Performance Dashboard toolbar');

  // Add toggle functionality
  const toggle = createToggleButton();
  toolbar.appendChild(toggle);

  // Add keyboard shortcuts
  setupKeyboardShortcuts(toolbar);

  // Initialize panel interactions with smooth animations
  initPanelInteractions(toolbar);

  // Add metric animations
  animateMetrics(toolbar);

  // Load toolbar data if token is present
  const token = toolbar.dataset.token;
  if (token) {
    loadToolbarData(token, toolbar);
  }

  // Add resize observer for responsive behavior
  observeToolbarResize(toolbar);
}

function createToggleButton(): HTMLElement {
  const button = document.createElement('button');
  button.innerHTML = `
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 4L4 12M4 4L12 12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
    </svg>
  `;
  button.className = 'profiler-toolbar-close';
  button.style.cssText = `
    position: absolute;
    right: 12px;
    top: 50%;
    transform: translateY(-50%);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(230, 237, 243, 0.08);
    color: var(--profiler-text-muted, #8b949e);
    font-size: 16px;
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    padding: 0;
    border-radius: 6px;
    transition: all 250ms cubic-bezier(0.4, 0, 0.2, 1);
  `;
  button.title = 'Hide profiler (Alt+P to toggle)';

  // Enhanced hover effect
  button.addEventListener('mouseenter', () => {
    button.style.background = 'rgba(255, 107, 107, 0.15)';
    button.style.borderColor = 'rgba(255, 107, 107, 0.3)';
    button.style.color = '#ff6b6b';
    button.style.transform = 'translateY(-50%) scale(1.1)';
  });

  button.addEventListener('mouseleave', () => {
    button.style.background = 'rgba(255, 255, 255, 0.04)';
    button.style.borderColor = 'rgba(230, 237, 243, 0.08)';
    button.style.color = '#8b949e';
    button.style.transform = 'translateY(-50%) scale(1)';
  });

  button.addEventListener('click', (e) => {
    const toolbar = (e.target as HTMLElement).closest('#profiler-toolbar');
    if (toolbar) {
      toggleToolbar(toolbar as HTMLElement);
    }
  });

  return button;
}

function setupKeyboardShortcuts(toolbar: HTMLElement): void {
  document.addEventListener('keydown', (e: KeyboardEvent) => {
    // Alt+P: Toggle toolbar
    if (e.altKey && e.key === 'p') {
      e.preventDefault();
      toggleToolbar(toolbar);
    }

    // Alt+D: Toggle first panel (debug)
    if (e.altKey && e.key === 'd') {
      e.preventDefault();
      const firstItem = toolbar.querySelector('.profiler-toolbar-hoverable');
      if (firstItem) {
        triggerPanelToggle(firstItem as HTMLElement);
      }
    }

    // Escape: Close all panels
    if (e.key === 'Escape') {
      closeAllPanels(toolbar);
    }
  });
}

function initPanelInteractions(toolbar: HTMLElement): void {
  const hoverableItems = toolbar.querySelectorAll('.profiler-toolbar-hoverable');
  let activePanel: HTMLElement | null = null;

  // Close active panel when clicking outside the toolbar
  document.addEventListener('click', (e) => {
    if (activePanel && !toolbar.contains(e.target as Node)) {
      activePanel.style.display = 'none';
      activePanel.classList.remove('visible');
      activePanel = null;
    }
  });

  hoverableItems.forEach((item) => {
    const panel = item.querySelector('.profiler-toolbar-panel');
    if (!panel) return;

    let showTimeout: number | null = null;
    let hideTimeout: number | null = null;

    const clampPanelToViewport = (el: HTMLElement) => {
      // Reset to default centered position, then measure
      el.style.left      = '50%';
      el.style.right     = 'auto';
      el.style.transform = 'translateX(-50%)';

      const rect = el.getBoundingClientRect();
      if (rect.left < 8) {
        el.style.left      = '0';
        el.style.transform = 'none';
      } else if (rect.right > window.innerWidth - 8) {
        el.style.left      = 'auto';
        el.style.right     = '0';
        el.style.transform = 'none';
      }
    };

    const showPanel = () => {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }

      showTimeout = window.setTimeout(() => {
        // Close any other open panel first
        if (activePanel && activePanel !== (panel as HTMLElement)) {
          activePanel.style.display = 'none';
          activePanel.classList.remove('visible');
        }
        (panel as HTMLElement).style.display = 'block';
        clampPanelToViewport(panel as HTMLElement);
        void (panel as HTMLElement).offsetHeight;
        (panel as HTMLElement).classList.add('visible');
        addPanelAccessibility(panel as HTMLElement);
        activePanel = panel as HTMLElement;
      }, 100);
    };

    const hidePanel = () => {
      if (showTimeout) {
        clearTimeout(showTimeout);
        showTimeout = null;
      }

      hideTimeout = window.setTimeout(() => {
        (panel as HTMLElement).classList.remove('visible');
        setTimeout(() => {
          if (!(panel as HTMLElement).classList.contains('visible')) {
            (panel as HTMLElement).style.display = 'none';
          }
        }, 250);
      }, 150);
    };

    item.addEventListener('mouseenter', showPanel);
    item.addEventListener('mouseleave', hidePanel);
    panel.addEventListener('mouseenter', showPanel);
    panel.addEventListener('mouseleave', hidePanel);

    // Click to pin panel
    item.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      (panel as HTMLElement).classList.toggle('pinned');
    });
  });
}

function triggerPanelToggle(item: HTMLElement): void {
  const panel = item.querySelector('.profiler-toolbar-panel');
  if (panel) {
    const isVisible = (panel as HTMLElement).style.display === 'block';
    (panel as HTMLElement).style.display = isVisible ? 'none' : 'block';
    if (!isVisible) {
      (panel as HTMLElement).classList.add('visible');
    } else {
      (panel as HTMLElement).classList.remove('visible');
    }
  }
}

function closeAllPanels(toolbar: HTMLElement): void {
  const panels = toolbar.querySelectorAll('.profiler-toolbar-panel');
  panels.forEach((panel) => {
    if (!(panel as HTMLElement).classList.contains('pinned')) {
      (panel as HTMLElement).classList.remove('visible');
      setTimeout(() => {
        if (!(panel as HTMLElement).classList.contains('visible')) {
          (panel as HTMLElement).style.display = 'none';
        }
      }, 250);
    }
  });
}

function addPanelAccessibility(panel: HTMLElement): void {
  panel.setAttribute('role', 'tooltip');
  panel.setAttribute('aria-live', 'polite');
}

function animateMetrics(toolbar: HTMLElement): void {
  const items = toolbar.querySelectorAll('.profiler-toolbar-item');

  items.forEach((item, index) => {
    (item as HTMLElement).style.opacity = '0';
    (item as HTMLElement).style.transform = 'translateY(10px)';

    setTimeout(() => {
      (item as HTMLElement).style.transition = 'opacity 400ms cubic-bezier(0.4, 0, 0.2, 1), transform 400ms cubic-bezier(0.4, 0, 0.2, 1)';
      (item as HTMLElement).style.opacity = '1';
      (item as HTMLElement).style.transform = 'translateY(0)';
    }, 50 + (index * 40));
  });

  // Animate metric values with counting effect
  const metricValues = toolbar.querySelectorAll('[data-metric-value]');
  metricValues.forEach((element) => {
    const target = parseFloat((element as HTMLElement).dataset.metricValue || '0');
    animateCountUp(element as HTMLElement, target);
  });
}

function animateCountUp(element: HTMLElement, target: number, duration: number = 1000): void {
  const start = 0;
  const startTime = performance.now();

  function update(currentTime: number): void {
    const elapsed = currentTime - startTime;
    const progress = Math.min(elapsed / duration, 1);

    // Easing function for smooth animation
    const easeOutCubic = 1 - Math.pow(1 - progress, 3);
    const current = start + (target - start) * easeOutCubic;

    // Format number based on magnitude
    if (target < 1) {
      element.textContent = current.toFixed(2);
    } else if (target < 100) {
      element.textContent = current.toFixed(1);
    } else {
      element.textContent = Math.round(current).toString();
    }

    if (progress < 1) {
      requestAnimationFrame(update);
    } else {
      element.textContent = target.toString();
    }
  }

  requestAnimationFrame(update);
}

function toggleToolbar(toolbar: HTMLElement): void {
  const container = toolbar.querySelector('.profiler-toolbar-container') as HTMLElement;
  const isHidden = toolbar.dataset.hidden === 'true';

  if (isHidden) {
    // Show with animation
    toolbar.dataset.hidden = 'false';
    toolbar.style.transform = 'translateY(0)';
    toolbar.style.opacity = '1';
    localStorage.setItem('profiler-toolbar-hidden', 'false');

    // Animate items back in
    setTimeout(() => animateMetrics(toolbar), 100);
  } else {
    // Hide with animation
    toolbar.dataset.hidden = 'true';
    toolbar.style.transform = 'translateY(100%)';
    toolbar.style.opacity = '0';
    localStorage.setItem('profiler-toolbar-hidden', 'true');
  }
}

async function loadToolbarData(token: string, toolbar: HTMLElement): Promise<void> {
  try {
    const response = await fetch(`/_profiler/api/toolbar/${token}`);
    const data = await response.json();

    if (data.html) {
      const container = toolbar.querySelector('.profiler-toolbar-container');
      if (container) {
        // SECURITY NOTE: HTML content comes from our own API endpoint (server-controlled)
        // not from user input, so this is safe in this context. For production use
        // with untrusted content, consider using DOMPurify or similar sanitization.
        container.innerHTML = data.html;

        // Re-initialize interactions after loading new content
        initPanelInteractions(toolbar);
        animateMetrics(toolbar);
      }
    }
  } catch (error) {
    console.error('❌ Failed to load toolbar data:', error);
    showErrorState(toolbar);
  }
}

function showErrorState(toolbar: HTMLElement): void {
  const container = toolbar.querySelector('.profiler-toolbar-container');
  if (container) {
    // Using textContent for error message to avoid any XSS concerns
    const errorDiv = document.createElement('div');
    errorDiv.className = 'profiler-toolbar-item';
    errorDiv.style.color = 'var(--profiler-error, #ff6b6b)';
    errorDiv.textContent = '⚠️ Failed to load profiler data';
    container.textContent = '';
    container.appendChild(errorDiv);
  }
}

function observeToolbarResize(toolbar: HTMLElement): void {
  if (!('ResizeObserver' in window)) return;

  const observer = new ResizeObserver((entries) => {
    for (const entry of entries) {
      const width = entry.contentRect.width;

      // Adjust toolbar layout based on width
      if (width < 800) {
        toolbar.classList.add('compact');
      } else {
        toolbar.classList.remove('compact');
      }
    }
  });

  observer.observe(toolbar);
}

// Restore toolbar state from localStorage
document.addEventListener('DOMContentLoaded', () => {
  const toolbar = document.getElementById('profiler-toolbar');
  if (toolbar) {
    const hidden = localStorage.getItem('profiler-toolbar-hidden') === 'true';

    if (hidden) {
      toolbar.dataset.hidden = 'true';
      toolbar.style.transform = 'translateY(100%)';
      toolbar.style.opacity = '0';
    } else {
      // Ensure toolbar is visible and animated
      toolbar.dataset.hidden = 'false';
      setTimeout(() => {
        if (toolbar.style.opacity !== '1') {
          toolbar.style.transition = 'all 400ms cubic-bezier(0.4, 0, 0.2, 1)';
          toolbar.style.transform = 'translateY(0)';
          toolbar.style.opacity = '1';
        }
      }, 100);
    }
  }
});
