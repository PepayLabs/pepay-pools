import { httpRequest } from '../utils/http.js';
import { logger } from '../utils/logger.js';

interface SpotMetaToken {
  name: string;
  index: number;
}

interface SpotMetaUniverseEntry {
  tokens: [number, number];
  name: string;
  index: number;
}

interface SpotMetaResponse {
  universe: SpotMetaUniverseEntry[];
  tokens: Array<SpotMetaToken & { [key: string]: unknown }>;
}

interface OrderBookLevel {
  px: string;
  sz: string;
  n: number;
}

interface L2BookResponse {
  coin: string;
  time: number;
  levels: [OrderBookLevel[], OrderBookLevel[]];
}

export interface HyperliquidOrderBook {
  pair: string;
  timestamp: number;
  bids: OrderBookLevel[];
  asks: OrderBookLevel[];
}

const INFO_URL = 'https://api.hyperliquid.xyz/info';

export class HyperliquidClient {
  private static instance: HyperliquidClient | null = null;

  static getInstance(): HyperliquidClient {
    if (!HyperliquidClient.instance) {
      HyperliquidClient.instance = new HyperliquidClient();
    }
    return HyperliquidClient.instance;
  }

  private readonly metaTtlMs = 60_000;
  private readonly bookTtlMs = 1_000;

  private cachedMeta: SpotMetaResponse | null = null;
  private cachedMetaFetchedAt = 0;

  private readonly bookCache = new Map<string, { fetchedAt: number; book: HyperliquidOrderBook }>();

  private constructor(private readonly baseUrl: string = INFO_URL) {}

  async resolvePairSymbol(base: string, quote: string): Promise<string> {
    const meta = await this.fetchMeta();
    const baseToken = meta.tokens.find((token) => token.name === base);
    const quoteToken = meta.tokens.find((token) => token.name === quote);

    if (!baseToken || !quoteToken) {
      throw new Error(`Hyperliquid meta missing token mapping for ${base}/${quote}`);
    }

    const pair = meta.universe.find((entry) => {
      return (
        (entry.tokens[0] === baseToken.index && entry.tokens[1] === quoteToken.index) ||
        (entry.tokens[0] === quoteToken.index && entry.tokens[1] === baseToken.index)
      );
    });

    if (!pair) {
      throw new Error(`Hyperliquid meta missing pair entry for ${base}/${quote}`);
    }

    return pair.name;
  }

  async fetchOrderBook(pair: string): Promise<HyperliquidOrderBook> {
    const cached = this.bookCache.get(pair);
    const now = Date.now();
    if (cached && now - cached.fetchedAt < this.bookTtlMs) {
      return cached.book;
    }

    const response = await httpRequest<L2BookResponse>({
      url: this.baseUrl,
      method: 'POST',
      body: {
        type: 'l2Book',
        coin: pair,
      },
    });

    const bids = response.levels?.[0] ?? [];
    const asks = response.levels?.[1] ?? [];
    const book: HyperliquidOrderBook = {
      pair,
      timestamp: response.time ?? Date.now(),
      bids,
      asks,
    };

    this.bookCache.set(pair, { fetchedAt: now, book });
    return book;
  }

  private async fetchMeta(): Promise<SpotMetaResponse> {
    const now = Date.now();
    if (this.cachedMeta && now - this.cachedMetaFetchedAt < this.metaTtlMs) {
      return this.cachedMeta;
    }

    const meta = await httpRequest<SpotMetaResponse>({
      url: this.baseUrl,
      method: 'POST',
      body: {
        type: 'spotMeta',
      },
    });

    if (!meta.universe || !meta.tokens) {
      logger.warn({ meta }, 'Hyperliquid meta missing universe or tokens');
      throw new Error('Hyperliquid meta malformed');
    }

    this.cachedMeta = meta;
    this.cachedMetaFetchedAt = now;
    return meta;
  }
}
