export class MockClock {
  private currentMs: number;
  private blockNumber: number;

  constructor(startTimeMs = Date.UTC(2025, 0, 1), startBlockNumber = 1) {
    this.currentMs = startTimeMs;
    this.blockNumber = startBlockNumber;
  }

  now(): number {
    return this.currentMs;
  }

  nowSeconds(): number {
    return Math.floor(this.currentMs / 1000);
  }

  getBlockNumber(): number {
    return this.blockNumber;
  }

  advance(ms: number): void {
    if (ms < 0) return;
    this.currentMs += ms;
    this.blockNumber += Math.max(1, Math.round(ms / 1000) || 1);
  }

  async sleep(ms: number): Promise<void> {
    this.advance(ms);
  }

  tickBlock(): void {
    this.blockNumber += 1;
  }
}

export function createMockClock(startTimeMs?: number, startBlockNumber?: number): MockClock {
  return new MockClock(startTimeMs, startBlockNumber);
}
