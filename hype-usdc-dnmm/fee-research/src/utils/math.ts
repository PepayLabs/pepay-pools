import { ethers } from 'ethers';

export interface PriceImpactInput {
  amountInTokens: number;
  amountOutTokens: number;
  idealOutTokens: number;
}

export function computePriceImpactBps({ amountInTokens, amountOutTokens, idealOutTokens }: PriceImpactInput): number | null {
  if (idealOutTokens <= 0 || amountOutTokens <= 0 || amountInTokens <= 0) {
    return null;
  }
  const impact = ((idealOutTokens - amountOutTokens) / idealOutTokens) * 10000;
  return Number.isFinite(impact) ? Math.max(0, impact) : null;
}

export function computeEffectivePriceInPerOut(amountInTokens: number, amountOutTokens: number): number | null {
  if (amountOutTokens <= 0) {
    return null;
  }
  const price = amountInTokens / amountOutTokens;
  return Number.isFinite(price) ? price : null;
}

export function computeEffectivePriceUsdPerOut(amountInUsd: number, gasCostUsd: number, amountOutTokens: number): number | null {
  if (amountOutTokens <= 0) {
    return null;
  }
  const totalUsd = amountInUsd + (gasCostUsd ?? 0);
  const price = totalUsd / amountOutTokens;
  return Number.isFinite(price) ? price : null;
}

export function toDecimalString(value: bigint, decimals: number): string {
  return ethers.formatUnits(value, decimals);
}

export function fromDecimalString(value: string, decimals: number): bigint {
  return ethers.parseUnits(value, decimals);
}

export function usdToTokenAmount(usd: number, midPriceOutPerIn: number, decimals: number): bigint {
  if (midPriceOutPerIn <= 0) {
    throw new Error('Mid price must be positive');
  }
  const tokens = usd / midPriceOutPerIn;
  return ethers.parseUnits(tokens.toFixed(decimals), decimals);
}

export function roundDownToUnit(amount: bigint, unit: bigint): bigint {
  return (amount / unit) * unit;
}

export function computeLogBuckets(min: number, max: number, perDecade: number): number[] {
  const buckets: number[] = [];
  const logMin = Math.log10(min);
  const logMax = Math.log10(max);
  const step = 1 / (perDecade - 1);
  for (let decade = Math.floor(logMin); decade <= Math.ceil(logMax); decade++) {
    for (let i = 0; i < perDecade; i++) {
      const value = 10 ** (decade + i * step);
      if (value >= min && value <= max) {
        buckets.push(Number(value.toFixed(2)));
      }
    }
  }
  return Array.from(new Set(buckets)).sort((a, b) => a - b);
}
