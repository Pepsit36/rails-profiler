// Theme management - Light/Dark mode toggle

export type Theme = 'light' | 'dark' | 'auto';

const STORAGE_KEY = 'profiler-theme';
const THEME_ATTRIBUTE = 'data-theme';

export class ThemeManager {
  private currentTheme: Theme;
  private systemPreference: MediaQueryList;

  constructor() {
    this.systemPreference = window.matchMedia('(prefers-color-scheme: dark)');
    this.currentTheme = this.loadTheme();
    this.init();
  }

  private init(): void {
    // Apply initial theme
    this.applyTheme(this.currentTheme);

    // Listen for system preference changes
    this.systemPreference.addEventListener('change', (e) => {
      if (this.currentTheme === 'auto') {
        this.applyTheme('auto');
      }
    });

    // Listen for storage changes (sync across tabs)
    window.addEventListener('storage', (e) => {
      if (e.key === STORAGE_KEY && e.newValue) {
        this.currentTheme = e.newValue as Theme;
        this.applyTheme(this.currentTheme);
      }
    });
  }

  private loadTheme(): Theme {
    const stored = localStorage.getItem(STORAGE_KEY) as Theme;
    return stored || 'auto';
  }

  private saveTheme(theme: Theme): void {
    localStorage.setItem(STORAGE_KEY, theme);
  }

  private applyTheme(theme: Theme): void {
    const resolvedTheme = this.resolveTheme(theme);
    document.documentElement.setAttribute(THEME_ATTRIBUTE, resolvedTheme);

    // Dispatch event for other components
    window.dispatchEvent(new CustomEvent('profiler:theme-change', {
      detail: { theme: resolvedTheme }
    }));
  }

  private resolveTheme(theme: Theme): 'light' | 'dark' {
    if (theme === 'auto') {
      return this.systemPreference.matches ? 'dark' : 'light';
    }
    return theme;
  }

  public getTheme(): Theme {
    return this.currentTheme;
  }

  public getResolvedTheme(): 'light' | 'dark' {
    return this.resolveTheme(this.currentTheme);
  }

  public setTheme(theme: Theme): void {
    this.currentTheme = theme;
    this.saveTheme(theme);
    this.applyTheme(theme);
  }

  public toggle(): void {
    const resolved = this.getResolvedTheme();
    const newTheme: Theme = resolved === 'dark' ? 'light' : 'dark';
    this.setTheme(newTheme);
  }
}

// Create singleton instance
export const themeManager = new ThemeManager();

// Export helper functions
export function toggleTheme(): void {
  themeManager.toggle();
}

export function setTheme(theme: Theme): void {
  themeManager.setTheme(theme);
}

export function getTheme(): Theme {
  return themeManager.getTheme();
}

export function getResolvedTheme(): 'light' | 'dark' {
  return themeManager.getResolvedTheme();
}

// Helper to create SVG icons safely
function createSunIcon(): SVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');

  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', 'M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z');
  path.setAttribute('stroke', 'currentColor');
  path.setAttribute('stroke-width', '2');
  path.setAttribute('stroke-linecap', 'round');
  path.setAttribute('stroke-linejoin', 'round');

  svg.appendChild(path);
  return svg;
}

function createMoonIcon(): SVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');

  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', 'M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z');
  path.setAttribute('stroke', 'currentColor');
  path.setAttribute('stroke-width', '2');
  path.setAttribute('stroke-linecap', 'round');
  path.setAttribute('stroke-linejoin', 'round');

  svg.appendChild(path);
  return svg;
}

// Create and inject theme toggle button
export function createThemeToggle(): HTMLButtonElement {
  const button = document.createElement('button');
  button.className = 'profiler-theme-toggle';
  button.setAttribute('aria-label', 'Toggle theme');
  button.title = 'Toggle light/dark mode';

  const updateIcon = () => {
    const theme = getResolvedTheme();
    // Clear existing icon
    while (button.firstChild) {
      button.removeChild(button.firstChild);
    }
    // Add new icon
    const icon = theme === 'dark' ? createSunIcon() : createMoonIcon();
    button.appendChild(icon);
  };

  // Initial icon
  updateIcon();

  // Update icon when theme changes
  window.addEventListener('profiler:theme-change', updateIcon);

  // Toggle on click
  button.addEventListener('click', () => {
    toggleTheme();
  });

  return button;
}

// Auto-initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    console.log('🎨 Theme system initialized:', getResolvedTheme());
  });
} else {
  console.log('🎨 Theme system initialized:', getResolvedTheme());
}
