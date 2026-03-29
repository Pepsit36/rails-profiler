export interface Profile {
  token: string;
  method: string;
  path: string;
  status: number;
  duration: number;
  memory?: number;
  started_at: string;
  profile_type?: 'http' | 'job';
  params?: Record<string, any>;
  headers?: Record<string, any>;
  response_headers?: Record<string, any>;
  request_body?: string;
  request_body_encoding?: 'text' | 'base64';
  response_body?: string;
  response_body_encoding?: 'text' | 'base64';
  collectors_data?: {
    database?: DatabaseData;
    cache?: CacheData;
    dump?: DumpData;
    request?: RequestData;
    performance?: PerformanceData;
    view?: ViewData;
    ajax?: AjaxData;
    http?: HttpData;
    job?: JobData;
    flamegraph?: FlameGraphData;
    logs?: LogData;
    exception?: ExceptionData;
    [key: string]: any;  // Allow custom collector data
  };
  tabs?: TabConfig[];  // Tab configurations from collectors
}

export interface TabConfig {
  key: string;
  label: string;
  icon?: string;
  priority: number;
  enabled: boolean;
  default_active?: boolean;
  render_mode: 'auto' | 'custom' | 'client';
  html?: string;
  has_data: boolean;
}

export interface DatabaseData {
  total_queries: number;
  total_duration: number;
  slow_queries: number;
  cached_queries: number;
  queries: DatabaseQuery[];
}

export interface DatabaseQuery {
  sql: string;
  duration: number;
  slow: boolean;
  cached: boolean;
  name?: string;
}

export interface CacheData {
  total_reads: number;
  total_writes: number;
  total_deletes: number;
  hit_rate: number;
  hits: number;
  misses: number;
  reads?: CacheOperation[];
  writes?: CacheOperation[];
  deletes?: CacheOperation[];
}

export interface CacheOperation {
  key: string;
  duration: number;
  hit?: boolean;
}

export interface DumpData {
  count: number;
  dumps: Dump[];
}

export interface Dump {
  label?: string;
  file: string;
  line: number;
  timestamp: string;
  formatted: string;
}

export interface RequestData {
  headers: Record<string, any>;
  params: Record<string, any>;
  response_headers?: Record<string, any>;
  request_body?: string;
  request_body_encoding?: 'text' | 'base64';
  response_body?: string;
  response_body_encoding?: 'text' | 'base64';
}

export interface PerformanceData {
  total_events: number;
  total_duration: number;
  events: PerformanceEvent[];
}

export interface PerformanceEvent {
  name: string;
  duration: number;
  payload?: Record<string, any>;
}

export interface ViewData {
  total_views: number;
  total_partials: number;
  total_duration: number;
  views?: ViewRender[];
  partials?: ViewRender[];
}

export interface ViewRender {
  identifier: string;
  duration: number;
}

export interface AjaxData {
  total_requests: number;
  total_duration: number;
  by_method: Record<string, number>;
  by_status: Record<string, number>;
  requests: AjaxRequest[];
}

export interface AjaxRequest {
  token: string;
  path: string;
  method: string;
  status: number;
  duration: number;
  started_at: string;
}

export interface HttpData {
  total_requests: number;
  total_duration: number;
  slow_requests: number;
  error_requests: number;
  by_host: Record<string, number>;
  by_status: Record<string, number>;
  requests: HttpRequest[];
}

export interface HttpRequest {
  url: string;
  method: string;
  status: number;
  duration: number;
  request_headers: Record<string, string>;
  request_body?: string;
  request_body_encoding?: 'text' | 'base64';
  request_size: number;
  response_headers: Record<string, string>;
  response_body?: string;
  response_body_encoding?: 'text' | 'base64';
  response_size: number;
  backtrace: string[];
  error?: string;
}

export interface JobData {
  job_class: string;
  job_id: string;
  queue: string;
  arguments: any[];
  executions: number;
  status: 'running' | 'completed' | 'failed';
  error?: string;
}

export interface LogData {
  count: number;
  errors: number;
  warnings: number;
  logs: LogEntry[];
}

export interface LogEntry {
  level: 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'FATAL' | 'UNKNOWN';
  message: string;
  timestamp: string;
}

export interface ExceptionData {
  exception_class: string;
  message: string;
  backtrace: BacktraceFrame[];
}

export interface BacktraceFrame {
  location: string;
  app_frame: boolean;
}

export type FlameGraphCategory = 'controller' | 'view' | 'partial' | 'sql' | 'cache' | 'http'

export interface FlameGraphNode {
  name: string
  started_at: number
  finished_at: number
  duration: number
  category: FlameGraphCategory
  payload?: Record<string, any>
  children: FlameGraphNode[]
}

export interface FlameGraphData {
  total_events: number
  total_duration: number
  root_events: FlameGraphNode[]
}
