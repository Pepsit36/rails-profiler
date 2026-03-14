// API client for fetching profiler data

export interface Profile {
  token: string;
  path: string;
  method: string;
  status: number;
  duration: number;
  memory: number;
  started_at: string;
  finished_at: string;
  collectors_data: Record<string, any>;
}

export class ProfilerAPI {
  private baseURL: string;

  constructor(baseURL: string = '/_profiler') {
    this.baseURL = baseURL;
  }

  async getProfiles(params?: {
    limit?: number;
    offset?: number;
    filter?: {
      path?: string;
      method?: string;
      min_duration?: number;
    };
  }): Promise<Profile[]> {
    const queryParams = new URLSearchParams();

    if (params?.limit) queryParams.set('limit', params.limit.toString());
    if (params?.offset) queryParams.set('offset', params.offset.toString());

    const url = `${this.baseURL}/api/profiles?${queryParams}`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`Failed to fetch profiles: ${response.statusText}`);
    }

    return response.json();
  }

  async getProfile(token: string): Promise<Profile> {
    const url = `${this.baseURL}/api/profiles/${token}`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`Failed to fetch profile: ${response.statusText}`);
    }

    return response.json();
  }

  async getToolbarData(token: string): Promise<{ profile: Profile }> {
    const url = `${this.baseURL}/api/toolbar/${token}`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`Failed to fetch toolbar data: ${response.statusText}`);
    }

    return response.json();
  }

  async getTimelineData(token: string): Promise<any> {
    const url = `${this.baseURL}/profiles/${token}/timeline`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`Failed to fetch timeline data: ${response.statusText}`);
    }

    return response.json();
  }

  async getDatabaseData(token: string): Promise<any> {
    const url = `${this.baseURL}/profiles/${token}/database`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`Failed to fetch database data: ${response.statusText}`);
    }

    return response.json();
  }
}

export const api = new ProfilerAPI();
