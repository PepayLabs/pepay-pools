import { z } from 'zod';

export interface ChainConfig {
  chain_id: number;
  name: string;
  rpc_url_env: string;
  native_symbol: string;
  block_explorer_api_env: string | null;
  block_explorer_kind: 'blockscout' | 'etherscan-like' | 'custom';
}

export interface TokenConfig {
  symbol: string;
  name: string;
  address: string;
  decimals: number;
  chain_id: number;
  verified_source: string;
  last_verified_at: string;
}

export interface DexDocsEntry {
  name: string;
  official_docs_url: string | null;
  sdk_package_name: string | null;
  sdk_repo_url: string | null;
  http_quote_base_url: string | null;
  last_checked_at: string;
  notes: string | null;
}

export interface TokenPair {
  in: TokenConfig;
  out: TokenConfig;
}

export type QuoteDirection = 'USDC->HYPE' | 'HYPE->USDC';

export interface QuoteParams {
  direction: QuoteDirection;
  amount_in_tokens: string; // decimal string in token units
  amount_in_wei: bigint;
  chain_id: number;
  slippage_tolerance_bps: number;
}

export interface QuoteComputationContext {
  mid_price_out_per_in: number | null;
  gas_price_wei: bigint | null;
  native_token_usd: number | null;
}

export interface QuoteResult {
  amount_out_tokens: string;
  amount_out_wei: bigint;
  route_summary: string | null;
  fee_bps: number | null;
  gas_estimate: bigint | null;
  sdk_or_api_version: string | null;
  latency_ms: number;
  docs_url: string | null;
  success: boolean;
  failure_reason?: string;
  mid_price_out_per_in?: number | null;
}

export interface AdapterDocsMeta {
  official_docs_url: string | null;
  sdk_package_name: string | null;
  sdk_repo_url: string | null;
  http_quote_base_url: string | null;
}

export interface DexAdapter {
  name(): string;
  supports(chain_id: number): Promise<boolean>;
  resolveTokens(direction: QuoteDirection): Promise<TokenPair>;
  quote(params: QuoteParams): Promise<QuoteResult>;
  docs(): Promise<AdapterDocsMeta>;
  midPrice?(direction: QuoteDirection): Promise<number | null>;
}

export interface QuotePlan {
  amounts_usd: number[];
  directions: QuoteDirection[];
  slippage_tolerance_bps: number;
}

export interface RunConfig {
  run_id: string;
  timestamp_iso: string;
  chain: ChainConfig;
  tokens: TokenPair;
  directions: QuoteDirection[];
  amounts_usd: number[];
}

export const DexDocsSchema = z.array(
  z.object({
    name: z.string(),
    official_docs_url: z.string().url().nullable(),
    sdk_package_name: z.string().nullable(),
    sdk_repo_url: z.string().url().nullable(),
    http_quote_base_url: z.string().url().nullable(),
    last_checked_at: z.string(),
    notes: z.string().nullable(),
  })
);

export const TokenConfigSchema = z.array(
  z.object({
    symbol: z.string(),
    name: z.string(),
    address: z.string(),
    decimals: z.number(),
    chain_id: z.number(),
    verified_source: z.string(),
    last_verified_at: z.string(),
  })
);

export const ChainConfigSchema = z.array(
  z.object({
    chain_id: z.number(),
    name: z.string(),
    rpc_url_env: z.string(),
    native_symbol: z.string(),
    block_explorer_api_env: z.string().nullable(),
    block_explorer_kind: z.enum(['blockscout', 'etherscan-like', 'custom']),
  })
);
