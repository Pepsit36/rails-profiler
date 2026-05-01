export interface ChildJobSummary {
  token: string;
  job_class: string;
  job_id?: string;
  queue?: string;
  status: string;
  duration: number;
  started_at: string;
}

export interface ParentProfileSummary {
  token: string;
  profile_type: 'http' | 'job';
  path: string;
  method?: string;
  http_status?: number;
  status?: string;
  duration: number;
  started_at: string;
}

export interface Profile {
  token: string;
  method: string;
  path: string;
  status: number;
  duration: number;
  memory?: number;
  started_at: string;
  profile_type?: 'http' | 'job';
  gem_version?: string;
  parent_token?: string;
  child_jobs?: ChildJobSummary[];
  parent_profile?: ParentProfileSummary;
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
    function_profile?: FunctionProfileData;
    logs?: LogData;
    exception?: ExceptionData;
    routes?: RoutesData;
    i18n?: I18nData;
    env?: EnvData;
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
  transaction?: boolean;
  name?: string;
  binds?: any[];
  backtrace?: string[];
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
  route_name?: string;
  route_pattern?: string;
  route_params?: Record<string, any>;
  controller_action?: string;
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
  started_at?: string;
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

export interface RouteEntry {
  name?: string;
  pattern: string;
  verb: string;
  controller_action?: string;
  matched: boolean;
}

export interface RoutesData {
  total: number;
  matched?: RouteEntry;
  routes: RouteEntry[];
}

export interface I18nData {
  locale: string;
  total: number;
  missing_count: number;
  lookups: I18nLookup[];
}

export interface I18nLookup {
  key: string;
  locale: string;
  value: string;
  missing: boolean;
}

export interface EnvOverride {
  value: string;
  original: string | null;
}

export interface EnvData {
  variables: Record<string, string>;
  total: number;
  overrides?: Record<string, EnvOverride>;
}

export interface ProfilesResponse {
  profiles: Profile[]
  limit: number
  offset: number
  has_more: boolean
}

export type FlameGraphCategory = 'controller' | 'view' | 'partial' | 'sql' | 'cache' | 'http' | 'custom' | 'method'

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

export interface FunctionStat {
  name: string
  file: string
  line: number
  calls: number
  recursive_calls: number
  total_duration: number
  self_duration: number
  allocated_objects: number
  memory_bytes: number
  self_memory_bytes: number
}

export interface FunctionProfileData {
  enabled: boolean
  mode?: 'full' | 'lite'
  clock?: 'wall' | 'cpu' | 'object'
  elapsed_wall_ms?: number
  elapsed_cpu_ms?: number
  gc_samples?: number
  gc_overhead_pct?: number
  max_frames?: number
  frame_cap_reached?: boolean
  total_calls?: number
  total_duration?: number
  total_allocated_objects?: number
  total_memory_bytes?: number
  functions?: FunctionStat[]
  root_calls?: FlameGraphNode[]
}
