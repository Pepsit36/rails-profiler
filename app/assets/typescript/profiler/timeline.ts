// Timeline visualization for performance events

interface TimelineEvent {
  name: string;
  started_at: number;
  finished_at: number;
  duration: number;
  payload: Record<string, any>;
  children: TimelineEvent[];
}

export function initTimeline(container: HTMLElement): void {
  console.log('Initializing profiler timeline');

  const token = container.dataset.token;
  if (!token) {
    console.error('No profile token found');
    return;
  }

  loadTimelineData(token).then((events) => {
    renderTimeline(container, events);
  });
}

async function loadTimelineData(token: string): Promise<TimelineEvent[]> {
  const response = await fetch(`/_profiler/profiles/${token}/timeline`);
  const data = await response.json();
  return data.events || [];
}

function renderTimeline(container: HTMLElement, events: TimelineEvent[]): void {
  if (!events.length) {
    container.innerHTML = '<p>No timeline events recorded</p>';
    return;
  }

  const svg = createTimelineSVG(events);
  container.appendChild(svg);
}

function createTimelineSVG(events: TimelineEvent[]): SVGSVGElement {
  const width = 1200;
  const height = events.length * 40 + 40;

  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', width.toString());
  svg.setAttribute('height', height.toString());
  svg.style.cssText = 'background: #1e1e1e; border-radius: 4px;';

  // Calculate time scale
  const minTime = Math.min(...events.map(e => e.started_at));
  const maxTime = Math.max(...events.map(e => e.finished_at));
  const timeRange = maxTime - minTime;
  const scale = (width - 100) / timeRange;

  // Render each event
  events.forEach((event, index) => {
    const y = index * 40 + 20;
    const x = ((event.started_at - minTime) * scale) + 50;
    const eventWidth = event.duration * scale;

    // Event bar
    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    rect.setAttribute('x', x.toString());
    rect.setAttribute('y', y.toString());
    rect.setAttribute('width', Math.max(eventWidth, 2).toString());
    rect.setAttribute('height', '20');
    rect.setAttribute('fill', getEventColor(event.name));
    rect.setAttribute('rx', '2');

    // Add tooltip
    const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
    title.textContent = `${event.name}\nDuration: ${event.duration.toFixed(2)}ms`;
    rect.appendChild(title);

    svg.appendChild(rect);

    // Event label
    const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    text.setAttribute('x', '5');
    text.setAttribute('y', (y + 15).toString());
    text.setAttribute('fill', '#d4d4d4');
    text.setAttribute('font-size', '11');
    text.textContent = event.name.substring(0, 40);
    svg.appendChild(text);
  });

  return svg;
}

function getEventColor(eventName: string): string {
  if (eventName.includes('Controller')) return '#569cd6';
  if (eventName.includes('Render')) return '#4ec9b0';
  if (eventName.includes('Partial')) return '#ce9178';
  return '#dcdcaa';
}
