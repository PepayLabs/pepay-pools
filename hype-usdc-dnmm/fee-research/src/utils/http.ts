import { logger } from './logger.js';
import pRetry from 'p-retry';

export interface HttpRequest {
  url: string;
  method?: 'GET' | 'POST';
  headers?: Record<string, string>;
  body?: any;
  timeoutMs?: number;
}

export async function httpRequest<T>(req: HttpRequest): Promise<T> {
  const { url, method = 'GET', headers = {}, body, timeoutMs = 15000 } = req;

  return pRetry(
    async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetch(url, {
          method,
          headers: {
            'Content-Type': 'application/json',
            ...headers,
          },
          body: body ? JSON.stringify(body) : undefined,
          signal: controller.signal,
        });
        if (!response.ok) {
          const text = await response.text();
          throw new Error(`HTTP ${response.status}: ${text}`);
        }
        const contentType = response.headers.get('content-type');
        if (contentType && contentType.includes('application/json')) {
          return (await response.json()) as T;
        }
        return (await response.text()) as unknown as T;
      } catch (error) {
        logger.warn({ url, method, error: (error as Error).message }, 'HTTP request failed');
        throw error;
      } finally {
        clearTimeout(timer);
      }
    },
    {
      retries: 3,
      minTimeout: 250,
      factor: 2,
    }
  );
}
