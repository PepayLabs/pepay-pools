import pLimit from 'p-limit';

export function createRateLimitedQueue(maxParallel: number) {
  return pLimit(maxParallel);
}
